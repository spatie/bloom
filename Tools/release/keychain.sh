#!/bin/zsh
# Puts a Developer ID certificate into a keychain that exists only for the
# length of one CI job, and takes it out again.
#
#   Tools/release/keychain.sh import     create it, import the .p12, print the identity
#   Tools/release/keychain.sh cleanup    delete it and put the search list back
#
# A runner has no keychain worth speaking of and no one to click "allow", so
# the certificate has to arrive as a base64 .p12 in the environment and be
# imported with the partition list set, or codesign will sit waiting for a
# confirmation dialog that nobody will ever see.
#
#   BLOOM_CERT_P12_BASE64     base64 of the exported .p12
#   BLOOM_CERT_P12_PASSWORD   the password it was exported with
#
# The keychain is made in RUNNER_TEMP with a random password, added to the
# search list rather than replacing it, and deleted by a cleanup step that runs
# even when the build failed. Nothing about it survives the job.
#
# It refuses to run outside CI. Importing a certificate and rearranging the
# keychain search list on somebody's own machine is not a thing a release
# script should ever do by accident.

set -euo pipefail

ACTION=${1:-}

if [ -z "${CI:-}" ] && [ -z "${BLOOM_ALLOW_KEYCHAIN_OUTSIDE_CI:-}" ]; then
  echo "keychain.sh only runs in CI. On your own machine the certificate is" >&2
  echo "already in your login keychain and nothing here is needed." >&2
  exit 1
fi

KEYCHAIN="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bloom-signing.keychain-db"
SEARCH_LIST_BACKUP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bloom-keychain-search-list"

import_certificate() {
  : "${BLOOM_CERT_P12_BASE64:?keychain.sh: BLOOM_CERT_P12_BASE64 is not set}"
  : "${BLOOM_CERT_P12_PASSWORD:?keychain.sh: BLOOM_CERT_P12_PASSWORD is not set}"

  local password certificate
  password="$(/usr/bin/openssl rand -base64 24)"

  # Written with the umask already tight, so there is never a moment where the
  # .p12 is on disk and readable by anything else on the machine.
  umask 077
  certificate="$(mktemp -t bloom-cert)"
  printf '%s' "$BLOOM_CERT_P12_BASE64" | base64 --decode > "$certificate"

  security create-keychain -p "$password" "$KEYCHAIN"
  # No auto lock and no timeout: notarisation takes minutes and the default
  # five minute lock would put codesign back behind a password prompt halfway
  # through a job.
  security set-keychain-settings "$KEYCHAIN"
  security unlock-keychain -p "$password" "$KEYCHAIN"

  security import "$certificate" -k "$KEYCHAIN" -P "$BLOOM_CERT_P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security -f pkcs12

  rm -f "$certificate"

  # Without this codesign is allowed to read the key only after a UI prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$KEYCHAIN" >/dev/null

  # Appended, not substituted, so anything already on the list keeps working.
  security list-keychains -d user | tr -d '"' | xargs > "$SEARCH_LIST_BACKUP"
  security list-keychains -d user -s $(cat "$SEARCH_LIST_BACKUP") "$KEYCHAIN"

  local identity
  identity="$(security find-identity -v -p codesigning "$KEYCHAIN" \
    | grep 'Developer ID Application' \
    | head -1 \
    | sed -E 's/^[^"]*"([^"]*)".*$/\1/')"

  if [ -z "$identity" ]; then
    echo "keychain.sh: the imported certificate is not a Developer ID Application one." >&2
    echo "What did arrive:" >&2
    security find-identity -v -p codesigning "$KEYCHAIN" | sed 's/^/  /' >&2
    exit 1
  fi

  echo "==> imported $identity" >&2

  # The identity name is not a secret: it is the team name and the team id,
  # both of which are on every signed binary the team has ever shipped.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "identity=$identity" >> "$GITHUB_OUTPUT"
  fi
  echo "$identity"
}

cleanup_keychain() {
  if [ -f "$SEARCH_LIST_BACKUP" ]; then
    security list-keychains -d user -s $(cat "$SEARCH_LIST_BACKUP") || true
    rm -f "$SEARCH_LIST_BACKUP"
  fi
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -f "$KEYCHAIN"
  echo "==> signing keychain removed" >&2
}

case "$ACTION" in
  import) import_certificate ;;
  cleanup) cleanup_keychain ;;
  *) echo "usage: keychain.sh import|cleanup" >&2; exit 1 ;;
esac
