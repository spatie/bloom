# Bloom in Amp orbs

The Debian 12 x86_64 orb supports the Linux checks from `.github/workflows/test.yml`.
`.agents/setup` installs zsh, ShellCheck and the pinned standalone SwiftLint 0.65.1,
actionlint 1.7.7 and gitleaks 8.30.1 binaries. Release archives are checked with SHA-256.
The binaries live in `/usr/local/bin`, available to non-interactive login shells without
profile changes. Setup needs root or passwordless sudo, and internet access on a cold run.
Warm runs skip installed packages and matching binary versions. Resume only checks tools.

Run from the repository root:

```bash
make lint
make swiftlint
actionlint -no-color -ignore 'SC2153' .github/workflows/*.yml
zsh Tools/release/tests/licences.sh
node Tools/check-local-web-client.mjs
bash -n .agents/setup .agents/resume
shellcheck .agents/setup .agents/resume
git ls-files '*.sh' | while IFS= read -r script; do
  case "$(head -1 "$script")" in
    *zsh*) zsh -n "$script" ;;
    *) shellcheck "$script" ;;
  esac || exit
done
gitleaks git . --config .gitleaks.toml --log-opts=HEAD --redact --no-banner --exit-code 1
```

For the same secrets coverage as CI, first check `git rev-parse --is-shallow-repository`.
If it says `true`, run `git fetch --quiet --unshallow origin`. The history scan does not
include uncommitted edits; use `gitleaks dir . --config .gitleaks.toml --redact --no-banner`
when those also need checking.

This is not a native development Mac. Bloom needs macOS 26 and Xcode 26, and BloomCore
also imports Darwin. Installing Linux Swift would not support `make build`, `make test`,
the dev app, UI probes or releases. Setup deliberately does not install Swift or resolve
the macOS dependencies. Use a Mac or the manually dispatched macOS CI jobs for those checks.
No server, portal, credentials or project settings are required for these Linux checks.
