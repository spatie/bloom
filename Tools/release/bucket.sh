#!/bin/zsh
# Reads and writes objects in the UpCloud bucket the releases live in.
#
#   Tools/release/bucket.sh get <remote-name> <local-path>    (missing is not an error)
#   Tools/release/bucket.sh put <local-path> <remote-name> [<cache-control>]
#   Tools/release/bucket.sh url <remote-name>
#
# UpCloud Object Storage speaks S3, so this is the aws CLI pointed at a
# different endpoint. It is a script rather than four lines of YAML because the
# endpoint, the region and the prefix have to be identical on every call, and a
# feed uploaded to a slightly different key than the one the app is configured
# to read is a silent failure: nobody gets an update and nothing logs an error.
#
# From the environment, all of them required except the last two:
#
#   BLOOM_BUCKET            bucket name
#   BLOOM_S3_ENDPOINT       https endpoint of the region the bucket is in
#   BLOOM_S3_REGION         region name used to sign the request
#   BLOOM_PUBLIC_BASE_URL   what a browser uses to reach the same objects
#   AWS_ACCESS_KEY_ID       from the environment, never on the command line
#   AWS_SECRET_ACCESS_KEY
#   BLOOM_BUCKET_PREFIX     optional key prefix, no leading or trailing slash
#   BLOOM_S3_ACL            optional canned ACL. Leave it unset and make the
#                           bucket public with a bucket policy instead: object
#                           ACLs are the older mechanism and not every S3
#                           compatible provider still honours them.

set -euo pipefail

ACTION=${1:-}

: "${BLOOM_BUCKET:?bucket.sh: BLOOM_BUCKET is not set}"
: "${BLOOM_S3_ENDPOINT:?bucket.sh: BLOOM_S3_ENDPOINT is not set}"
: "${BLOOM_S3_REGION:?bucket.sh: BLOOM_S3_REGION is not set}"
: "${BLOOM_PUBLIC_BASE_URL:?bucket.sh: BLOOM_PUBLIC_BASE_URL is not set}"

PREFIX=${BLOOM_BUCKET_PREFIX:-}
PREFIX=${PREFIX#/}
PREFIX=${PREFIX%/}

remote_key() {
  if [ -n "$PREFIX" ]; then
    echo "$PREFIX/$1"
  else
    echo "$1"
  fi
}

public_url() {
  echo "${BLOOM_PUBLIC_BASE_URL%/}/$(remote_key "$1")"
}

# Newer AWS CLI versions send an additional checksum in an aws-chunked body by
# default, and UpCloud's S3 rejects it with XAmzContentSHA256Mismatch. Measured
# against the real bucket: the same PutObject fails with the default and
# succeeds with these two set, so they are not belt and braces, they are what
# makes an upload work at all. Set here rather than in the workflow so a local
# release through Tools/release.sh behaves the same way.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

s3() {
  aws s3api "$@" \
    --bucket "$BLOOM_BUCKET" \
    --endpoint-url "$BLOOM_S3_ENDPOINT" \
    --region "$BLOOM_S3_REGION"
}

case "$ACTION" in
  get)
    KEY="$(remote_key "${2:?bucket.sh get: needs a remote name}")"
    DEST=${3:?bucket.sh get: needs a local path}
    # A missing object is the normal case for the very first release, so it is
    # reported and not treated as a failure. Any other error still stops here.
    if s3 get-object --key "$KEY" "$DEST" >/dev/null 2>&1; then
      echo "==> got $KEY" >&2
    else
      echo "==> $KEY is not in the bucket yet" >&2
      : > "$DEST"
    fi
    ;;
  put)
    SRC=${2:?bucket.sh put: needs a local path}
    KEY="$(remote_key "${3:?bucket.sh put: needs a remote name}")"
    CACHE=${4:-}
    [ -f "$SRC" ] || { echo "bucket.sh put: no file at $SRC" >&2; exit 1; }

    ARGS=(put-object --key "$KEY" --body "$SRC")
    case "$KEY" in
      *.xml) ARGS+=(--content-type application/xml) ;;
      *.zip) ARGS+=(--content-type application/zip) ;;
      # Without this the bucket serves a .dmg as application/octet-stream, and
      # Safari treats that as something it might be able to show rather than
      # something to save.
      *.dmg) ARGS+=(--content-type application/x-apple-diskimage) ;;
    esac
    [ -n "$CACHE" ] && ARGS+=(--cache-control "$CACHE")
    [ -n "${BLOOM_S3_ACL:-}" ] && ARGS+=(--acl "$BLOOM_S3_ACL")

    s3 "${ARGS[@]}" >/dev/null
    echo "==> put $(public_url "${3}")" >&2
    ;;
  url)
    public_url "${2:?bucket.sh url: needs a remote name}"
    ;;
  *)
    echo "usage: bucket.sh get|put|url ..." >&2
    exit 1
    ;;
esac
