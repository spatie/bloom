# Releasing Bloom

Publish a release on GitHub and `.github/workflows/release.yml` does the rest:
it builds the tag, signs it with the Developer ID certificate, has Apple
notarise it, staples the ticket, wraps the same bundle in the beach disk image
and has that notarised and stapled too, uploads both files to the UpCloud
bucket, and adds the release to the Sparkle appcast that lives beside it.

## Two artefacts, and who each one is for

A release produces `Bloom-1.4.0.zip` and `Bloom-1.4.0.dmg`. They hold the same
signed, notarised and stapled `Bloom.app`, and they exist for two different
readers.

- **The .dmg is for people.** It is what `runbloom.app/download` redirects to
  and what every download button on the site leads to. It is the one with the
  window: the beach, the ribbon out of the app icon, and the drag onto the
  Applications alias. `Tools/dmg/` draws it.
- **The .zip is for Sparkle.** It is the appcast enclosure, and it is what every
  installed copy of Bloom downloads when it updates itself. Sparkle can install
  from a disk image, but the enclosure is the contract with every copy already
  out there, so it stays a zip. Do not point the enclosure at the .dmg to save
  a file.

The site is told where the image is through the appcast, on a
`bloom:diskImage` element beside the enclosure, in a namespace of our own.
Sparkle keeps an item's unrecognised children and reads the ones it knows, so
that element costs it nothing. Items written before disk images existed do not
have it, and everything reading the feed treats it as optional: `/download`
falls back to the zip for a release that has no image, which is every release
up to and including 0.6.0.

Each file needs a notarisation ticket of its own. Stapling the app inside the
image does not staple the image, and Gatekeeper assesses the file that was
downloaded, so an unstapled image asks Apple about itself the first time it is
opened: a wait on a slow connection and a refusal on none. That is why the
workflow makes two round trips to the notary service, and why it is the long
step.

The check that catches a missed image ticket is

```sh
spctl --assess --type open --context context:primary-signature --verbose=2 Bloom-1.4.0.dmg
```

against the image, not against the app. Assessing the app passes happily on an
image that was never notarised at all, which is the exact mistake worth having
a command for. `Tools/release/package-app.sh` runs it, and it is a hard failure.

The disk image window is a scene rendered by headless Chrome, matched against
the app icon as Chrome rasterises it, so the release runner needs Chrome. The
workflow checks for it before the build and installs it if the runner image
ever stops shipping it.

The parts of that which are not YAML live in `Tools/release/`, and `Tools/release.sh`
calls the same scripts. A local release and a CI release sign and notarise
through one piece of code on purpose.

## Cutting a release

1. Push a tag, or let GitHub create one when you publish.
   Tags look like `v1.4.0`, or `v1.4.0-beta.1` for a prerelease.
2. Write the release notes. They become the description Sparkle shows.
3. Publish. Tick "set as a pre-release" for anything you do not want everyone
   offered.

A prerelease is anything whose tag has a semver prerelease part, or anything
you ticked the box on. Either one puts the item on Sparkle's `beta` channel,
which nobody sees unless the app asks for that channel.

The version in the bundle comes from the tag, not from `Resources/Info.plist`.
The build number is the number of commits reachable from the tag, which is what
Sparkle compares, and is why the workflow checks out with full history.

To rebuild a tag that already exists, run the workflow by hand from the Actions
tab and give it the tag. Re-running is safe: the appcast entry for a version is
replaced rather than added again.

## Releasing from this machine

`./Tools/release.sh` builds, signs, notarises and staples, and leaves both the
zip and the disk image in `dist/`. It does not upload anything and does not
touch the appcast. `--no-dmg` skips the image and its notarisation round trip
when you only want something to send someone. It needs:

```sh
export BLOOM_CODESIGN_IDENTITY="Developer ID Application: Spatie (97KRXCRMAY)"

xcrun notarytool store-credentials bloom \
  --apple-id you@example.com --team-id 97KRXCRMAY --password <app-specific-password>
```

`./Tools/release.sh --tag v1.4.0` stamps that version instead of the plist's.

## What you have to set up, once

Five things. Nothing here can be scripted: every one of them is a person
proving who they are to somebody.

### 1. The Developer ID certificate, as a .p12

You already have `Developer ID Application: Spatie (97KRXCRMAY)` in your login
keychain. The runner needs the same certificate and its private key as one
password protected file.

1. Keychain Access, login keychain, My Certificates.
2. Find `Developer ID Application: Spatie (97KRXCRMAY)`. Expand the triangle:
   if there is no private key under it, this Mac cannot export it and you need
   the Mac that made it.
3. Right click the certificate, Export. Format: Personal Information Exchange
   (.p12). Save it somewhere temporary.
4. It asks for a password. Make one up, keep it, this becomes a secret.
5. Turn it into one line of base64:

   ```sh
   base64 -i ~/Desktop/bloom-signing.p12 | pbcopy
   ```

6. Paste that as the secret `APPLE_CERTIFICATE_P12`, and the password you chose
   as `APPLE_CERTIFICATE_PASSWORD`.
7. Delete the .p12. It is the private key of everything Spatie ships for macOS.

### 2. The notarisation credential

Use an App Store Connect API key, not an app specific password. The key is
scoped to what it needs, can be revoked on its own without changing anybody's
Apple ID password, and is the only one of the two that never has a second
factor to get past on a machine with no screen.

There is one catch worth knowing before you start. Notarisation only accepts a
**Team Key**. An Individual Key, the kind any team member can make for
themselves, is explicitly not accepted by the Notary service, so it has to be a
team one.

Team Keys can be generated by anyone with the Admin role, which you have. What
Admin does not cover is the one time step of turning the API on for the team at
all: the Account Holder has to do that once, and until they have, the Team Keys
tab is not there to click. If you open the page and find nothing to generate,
that is what is missing, and it is a request the Account Holder submits rather
than something you can do yourself.

1. appstoreconnect.apple.com, Users and Access, Integrations, App Store Connect
   API, Team Keys.
2. If the page offers "Request Access" rather than a list of keys, stop: the
   Account Holder has to do that first.
3. Generate API Key. Name it something like `bloom-notarisation`. Access:
   **Developer**. That is enough for notarisation and nothing else.
4. Download the `.p8`. **You get one chance.** Apple will not show it again.
5. Copy the Key ID from the row, and the Issuer ID from the top of the page.
6. Turn the key into base64:

   ```sh
   base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```

7. Set `APPLE_API_KEY_P8` to that, `APPLE_API_KEY_ID` to the key id, and
   `APPLE_API_ISSUER_ID` to the issuer id.
8. Delete the `.p8`.

If the Account Holder step turns out to be a wall, the fallback is an app
specific password from appleid.apple.com. `Tools/release/package-app.sh`
accepts it through `BLOOM_NOTARY_APPLE_ID`, `BLOOM_NOTARY_TEAM_ID` and
`BLOOM_NOTARY_PASSWORD`, but the workflow does not wire those up, so taking
that route means editing the workflow as well. Prefer the key.

### 3. The bucket

An UpCloud Managed Object Storage instance with a bucket in it. Everything in
the bucket is world readable: it is a download and an update feed, and Sparkle
fetches both with no credentials.

1. UpCloud Hub, Managed Object Storage, create an instance, pick a zone.
2. Create a bucket. `bloom-releases` is a reasonable name.
3. Make it publicly readable. UpCloud supports both bucket policies and ACLs.
   Prefer a bucket policy granting `s3:GetObject` on `<bucket>/*` to everyone:
   it is one setting rather than one per object, and it keeps working if a
   future upload forgets the ACL. If you go the ACL route instead, set the
   repository variable `BLOOM_S3_ACL` to `public-read` and the workflow will
   put that on each object.
4. Create an access key scoped to that bucket. Write both halves down: the
   secret is shown once.
5. Note the endpoint. It looks like `https://xxxxx.upcloudobjects.com`.
6. Work out the public URL prefix by uploading any file and opening it in a
   browser. Depending on how the instance is set up this is either
   `https://<bucket>.<instance>.upcloudobjects.com` or
   `https://<instance>.upcloudobjects.com/<bucket>`. Do not guess: the appcast
   the app polls is built from this, and a wrong prefix means every update
   check 404s silently.

Then:

- secret `UPCLOUD_ACCESS_KEY_ID`, secret `UPCLOUD_SECRET_ACCESS_KEY`
- variable `UPCLOUD_BUCKET`, the bucket name
- variable `UPCLOUD_S3_ENDPOINT`, the `https://...upcloudobjects.com` endpoint
- variable `UPCLOUD_S3_REGION`, the region the instance reports, for example
  `europe-1`. It only has to match what the endpoint expects for signing.
- variable `BLOOM_PUBLIC_BASE_URL`, the prefix you checked in a browser, with
  no trailing slash

If uploads fail with a DNS or signature error, the addressing style is the
usual cause. Setting the repository variable `AWS_S3_ADDRESSING_STYLE` to
`path` is not wired up; add `AWS_S3_ADDRESSING_STYLE: path` to the two upload
steps' `env` if you need it.

### 4. The Sparkle signing key

Sparkle will not install an update whose signature it cannot check against the
public key compiled into the app. The private half signs each zip in CI. The
public half is a repository variable, and `Tools/build.sh` writes it into the bundle.

```sh
# Makes the key pair and puts the private half in your login keychain.
# It prints the public key. That is the one that goes in the variable.
Tools/release/sparkle-tools.sh                       # prints where the tools are
"$(Tools/release/sparkle-tools.sh)"/generate_keys --account bloom

# Export the private half for GitHub. This file is the whole secret.
"$(Tools/release/sparkle-tools.sh)"/generate_keys --account bloom -x bloom-sparkle.key
cat bloom-sparkle.key | pbcopy
rm bloom-sparkle.key
```

- secret `SPARKLE_PRIVATE_KEY`, the exported key
- variable `SPARKLE_PUBLIC_KEY`, the public key `generate_keys` printed

To read the public key again later, without exporting anything:

```sh
"$(Tools/release/sparkle-tools.sh)"/generate_keys --account bloom -p
```

Keep the key in your keychain as well as in GitHub. It cannot be regenerated:
lose it and every installed copy of Bloom stops accepting updates and has to be
reinstalled by hand.

The workflow checks the two halves are a pair before it builds anything, and
tells you the right public key if they are not. That check exists because a
mismatch is otherwise completely silent: green build, valid feed, and not one
user ever updated.

### 5. Put them into the repository

Settings, Secrets and variables, Actions.

**Secrets**

| Name | Where it comes from |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | base64 of the .p12 exported from Keychain Access |
| `APPLE_CERTIFICATE_PASSWORD` | the password you gave that export |
| `APPLE_API_KEY_P8` | base64 of the .p8 from App Store Connect |
| `APPLE_API_KEY_ID` | the Key ID next to the key in App Store Connect |
| `APPLE_API_ISSUER_ID` | the Issuer ID at the top of the same page |
| `SPARKLE_PRIVATE_KEY` | `generate_keys --account bloom -x` |
| `UPCLOUD_ACCESS_KEY_ID` | UpCloud access key, first half |
| `UPCLOUD_SECRET_ACCESS_KEY` | UpCloud access key, second half |

**Variables**

| Name | Where it comes from |
| --- | --- |
| `UPCLOUD_BUCKET` | the bucket name |
| `UPCLOUD_S3_ENDPOINT` | `https://<instance>.upcloudobjects.com` |
| `UPCLOUD_S3_REGION` | the instance's region, for example `europe-1` |
| `BLOOM_PUBLIC_BASE_URL` | the public prefix you opened in a browser, no trailing slash |
| `SPARKLE_PUBLIC_KEY` | printed by `generate_keys` |
| `BLOOM_BUCKET_PREFIX` | optional, a key prefix if the bucket holds other things |
| `BLOOM_S3_ACL` | optional, `public-read` if you used ACLs instead of a bucket policy |

The workflow checks all of these are set before it builds, and fails naming the
missing ones. Nothing prints a value.

## What the bucket ends up holding

```
appcast.xml           the feed every copy of Bloom polls, five minute cache
Bloom-1.4.0.zip       what Sparkle downloads, one per release, cached forever
Bloom-1.4.0.dmg       what runbloom.app/download hands a person, likewise
Bloom-1.4.0-beta.1.zip
Bloom-1.4.0-beta.1.dmg
```

The feed URL is `<BLOOM_PUBLIC_BASE_URL>/appcast.xml`, and it is computed from
the same variables the upload uses rather than written down twice, so the
address the app polls cannot drift from the address the feed is written to.

## What has never run

The workflow itself has run, and worked: v0.0.1-test and then 0.1.0 through
0.6.0 each went through it, so importing the .p12, notarising the zip with an
App Store Connect API key, stapling, the uploads and the appcast are all things
that have happened for real. This section used to say the opposite, from before
the first release, and was left saying it for six of them.

What has not run is the disk image half, added after 0.6.0:

- notarising a .dmg with the API key, and stapling the ticket to it
- `spctl --assess --type open` against a notarised image
- uploading a .dmg to the bucket, and the `bloom:diskImage` element reaching
  the website through the appcast
- `brew install --cask google-chrome`, which is only reached if a runner image
  stops shipping Chrome

There is no notarisation credential on any machine here, only the Developer ID
certificate, so none of that could be tried locally either. What was checked
locally, against the file rather than against an exit status:

- `Tools/dmg/build.sh` produces the image from an app that has already been
  signed with the hardened runtime, and the app inside the mounted image still
  passes `codesign --verify --strict --deep`, so the layout step preserves the
  signature and would preserve a stapled ticket with it
- the image itself takes a Developer ID signature and passes
  `codesign --verify --strict`
- `spctl --assess --type open --context context:primary-signature` on that
  image is rejected for want of a ticket, which is the check doing its job and
  the reason it is a hard failure in `package-app.sh`

The zip path is unchanged, so what it does is what it did for 0.6.0.

Expect the first release with an image to need a fix or two anyway.

## Testing the parts that need no secrets

```sh
Tools/release/tests/run.sh
```

Version derivation, appcast generation, and the Sparkle key derivation, checked
by signing with Sparkle's own tool and verifying with openssl.
