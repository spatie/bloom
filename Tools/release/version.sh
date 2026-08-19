#!/bin/zsh
# Turns a release tag into the two version numbers a bundle has to carry.
#
#   Tools/release/version.sh v1.4.0            derive from the tag, count commits on HEAD
#   Tools/release/version.sh v1.4.0 <ref>      count commits on that ref instead
#
# It prints shell assignable lines, so a caller can do:
#
#   eval "$(Tools/release/version.sh v1.4.0)"
#
# and then have $version, $build, $channel and $prerelease.
#
# Two numbers, because macOS wants two and they answer different questions.
#
#   version  CFBundleShortVersionString, the one a person reads. It is the tag
#            with its leading v removed, so the thing in the bundle and the
#            thing on the release page can never disagree.
#
#   build    CFBundleVersion, the one Sparkle compares. It is the number of
#            commits reachable from the ref, which is monotonic along a branch
#            and needs no state kept anywhere. It requires unshallow history:
#            a shallow clone counts wrong, so this refuses to guess and fails.
#
# A tag carrying a semver prerelease part (v1.4.0-beta.1) is a prerelease. That
# is decided here rather than in the workflow so a local build and a CI build
# reach the same answer from the same input.

set -euo pipefail

TAG=${1:-}
REF=${2:-HEAD}

if [ -z "$TAG" ]; then
  echo "version.sh: needs a tag, for example v1.4.0" >&2
  exit 1
fi

VERSION=${TAG#v}

# Anchored on both ends, because a tag that is nearly a version is worse than
# one that is obviously not: it would ship a bundle whose version string macOS
# and Sparkle both read as garbage.
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){0,3}(-[0-9A-Za-z.-]+)?$'; then
  echo "version.sh: '$TAG' is not a version tag." >&2
  echo "Expected something like v1.4.0 or v1.4.0-beta.1." >&2
  exit 1
fi

case "$VERSION" in
  *-*) PRERELEASE=1; CHANNEL=beta ;;
  *)   PRERELEASE=0; CHANNEL=stable ;;
esac

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "version.sh: not a git repository, cannot derive a build number." >&2
  exit 1
fi

if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  echo "version.sh: this clone is shallow, so the commit count is wrong." >&2
  echo "Check out with fetch-depth: 0 before releasing." >&2
  exit 1
fi

BUILD="$(git rev-list --count "$REF")"

if [ -z "$BUILD" ] || [ "$BUILD" = "0" ]; then
  echo "version.sh: could not count commits on '$REF'." >&2
  exit 1
fi

echo "version=$VERSION"
echo "build=$BUILD"
echo "channel=$CHANNEL"
echo "prerelease=$PRERELEASE"
