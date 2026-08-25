#!/bin/zsh
# Runs SwiftLint over Sources and Tests, against the `.swiftlint.yml` at the root.
#
#   ./Tools/swiftlint.sh              lint everything, which is also `make swiftlint`
#   ./Tools/swiftlint.sh --fix        apply the corrections SwiftLint can make itself
#   ./Tools/swiftlint.sh Sources/Bloom/Views   lint one path
#
# `make lint` is the other linter and they are not the same thing. `Tools/house-rules.sh` holds
# the conventions no off the shelf tool knows about: no em dashes, British spelling, typed ids, a
# view that does not run a subprocess. SwiftLint holds the ones every Swift codebase shares. Both
# run in the `lint` job of .github/workflows/test.yml, on the Linux runner, side by side.
#
# --strict, always, and that is the whole point of the tuned configuration. SwiftLint's own exit
# status only fails on an error-severity violation, and every rule in `.swiftlint.yml` is at the
# default warning severity, so without this flag a run that reported fifty things would still
# exit 0 and CI would go green over them. The configuration is at zero violations, so there is
# nothing to lose by treating every one of them as fatal, and that is what keeps it at zero.
#
# THIS SCRIPT DOES NOT INSTALL ANYTHING.
#
# SwiftLint is a 37MB binary from the internet and this is somebody's Mac. If it is not on the
# PATH the script says how to get it and stops, rather than deciding for you. CI pins a version
# and downloads it into the runner, which is a machine that is thrown away afterwards; see the
# `Lint the Swift` step in .github/workflows/test.yml. Locally, `brew install swiftlint` is the
# short answer, and the release page linked below is the one CI uses.
#
# A version skew between here and CI is worth knowing about and is not worth failing over: a
# newer SwiftLint can add a rule that fires on code this configuration was green on. The version
# is printed on every run so that "it passed locally" has something to compare against.

set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swiftlint >/dev/null 2>&1; then
  cat <<'MISSING'
SwiftLint is not on the PATH.

  brew install swiftlint

or take the binary from https://github.com/realm/SwiftLint/releases and put it somewhere on the
PATH. The version CI pins is in the `Lint the Swift` step of .github/workflows/test.yml.
MISSING
  exit 1
fi

echo "==> $(swiftlint version)"

# --fix first, because it is a different subcommand's worth of behaviour rather than a flag on
# this one, and because a run that rewrites files should not also be the run that decides whether
# the tree is clean. Read the diff afterwards. SwiftLint's autocorrection has already turned a
# `let _ = ` inside a `@ViewBuilder` into code that does not compile; the head of `.swiftlint.yml`
# has the details.
if [ "${1:-}" = "--fix" ]; then
  shift
  swiftlint lint --fix --progress "$@"
  echo
  echo "Files were rewritten. Read the diff before committing, and run this again without --fix."
  exit 0
fi

swiftlint lint --strict --quiet "$@"
echo
echo "SwiftLint passes."
