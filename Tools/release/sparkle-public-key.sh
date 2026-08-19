#!/bin/zsh
# Prints the Sparkle public key that belongs to a private key read on stdin.
#
#   printf '%s' "$SPARKLE_PRIVATE_KEY" | Tools/release/sparkle-public-key.sh
#
# The point is to catch the one Sparkle mistake nothing else catches. If the
# SUPublicEDKey compiled into the app is not the partner of the key the feed is
# signed with, everything looks right: the build passes, the appcast is valid,
# the zip downloads, and then every user's updater rejects the signature. The
# feed cannot tell you, the release cannot tell you, and the only symptom is
# that nobody ever updates.
#
# Sparkle stores the private key as base64 of a 32 byte ed25519 seed, or, for
# keys made before 2023, base64 of the 64 byte private key with the 32 byte
# public key after it. Both are handled.
#
# The seed is wrapped in the PKCS8 header ed25519 keys use so that openssl can
# do the derivation. That is standard RFC 8032 ed25519, the same thing Sparkle
# does internally, which is checked in Tools/release/tests/run.sh by signing
# with Sparkle and verifying with openssl.

set -euo pipefail

SECRET="$(cat)"
SECRET="${SECRET//[[:space:]]/}"

[ -n "$SECRET" ] || { echo "sparkle-public-key.sh: nothing on stdin" >&2; exit 1; }

WORK="$(mktemp -d -t bloom-sparkle-key)"
trap 'rm -rf "$WORK"' EXIT

printf '%s' "$SECRET" | /usr/bin/python3 -c '
import base64, sys, subprocess, os

work = sys.argv[1]
raw = base64.b64decode(sys.stdin.read())

if len(raw) == 96:
    # Old format: private key then public key.
    print(base64.b64encode(raw[64:]).decode())
    sys.exit(0)

if len(raw) != 32:
    sys.stderr.write(f"sparkle-public-key.sh: a Sparkle key is 32 or 96 bytes, this one is {len(raw)}\n")
    sys.exit(1)

pkcs8 = bytes.fromhex("302e020100300506032b657004220420") + raw
private = os.path.join(work, "private.der")
with open(private, "wb") as handle:
    handle.write(pkcs8)

public = subprocess.run(
    ["openssl", "pkey", "-inform", "DER", "-in", private, "-pubout", "-outform", "DER"],
    capture_output=True, check=True,
).stdout

print(base64.b64encode(public[-32:]).decode())
' "$WORK"
