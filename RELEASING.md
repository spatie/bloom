# Releasing Bloom

Publish a release on GitHub and `.github/workflows/release.yml` does the rest:
it builds the tag, signs it with the Developer ID certificate, has Apple
notarise it, staples the ticket, wraps the same bundle in the beach disk image
and has that notarised and stapled too, uploads both files to the UpCloud
bucket, and adds the release to the Sparkle appcast that lives beside it. It also
builds the Linux server, bundles it into the app, and attaches it to the GitHub
release, where every server's maintenance supervisor finds its next update; see
[Bloom Server](#bloom-server).

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
2. Generate release notes from the commits and merged PRs since the preceding release, checking
   them against the selected commit. Describe user-visible changes in concise British English.
   Publish them on GitHub; they become the description Sparkle shows.
3. Publish. Tick "set as a pre-release" for anything you do not want everyone
   offered.
4. After the release workflow succeeds, [publish the website release notes](#publish-the-website-release-notes)
   and verify the release assets, the [server assets](#checking-a-releases-server-assets), appcast,
   changelog and website download flow.

A prerelease is anything whose tag has a semver prerelease part, or anything
you ticked the box on. Either one puts the item on Sparkle's `beta` channel,
which nobody sees unless the app asks for that channel.

The version in the bundle comes from the tag, not from `Resources/Info.plist`.
The build number is the number of commits reachable from the tag, which is what
Sparkle compares, and is why the workflow checks out with full history.

To retry a release, prefer rerunning its original release-event workflow with
`gh run rerun <run-id>`. This preserves the GitHub prerelease flag and asset attachment step.
The appcast entry for a version is replaced rather than duplicated.

A manual workflow dispatch can rebuild an existing tag, but it does not receive the GitHub
prerelease flag and does not attach assets to the GitHub release. Only use it when the tag itself
preserves the intended channel: a stable version or a semver prerelease suffix. Dispatching a
plain tag that was marked prerelease on GitHub would incorrectly publish it as stable in the
appcast. Verify GitHub assets separately after a dispatch, and attach the server assets from that
run as described under [When the server asset is broken](#when-the-server-asset-is-broken).

## Publish the website release notes

A release is not complete until its generated notes are published on
[runbloom.app/changelog](https://runbloom.app/changelog), as well as on GitHub. The website is a
separate Laravel application in [spatie/runbloom.app](https://github.com/spatie/runbloom.app).
The app's release workflow does not publish the website entry.

1. After the new release reaches the appcast, ensure the production website has imported it.
   The website schedules `php artisan bloom:sync-releases` hourly. That command refreshes the
   appcast, records releases and generates summaries for entries that have none. It leaves new
   entries unpublished. `--draft-only` skips importing the appcast, so it cannot discover a new
   release. Use the site's established production access if an immediate sync is needed, and
   inspect the current command before running it: it can draft multiple missing summaries,
   incur AI costs and send draft-ready Slack alerts. These are not commands to run in the app repo.
2. In the production website's `/admin` panel, open **Releases** and edit the matching version.
   Review or write its **Headline** and Markdown **Summary** using the verified release notes.
   Keep the headline within 120 characters. **Draft again** replaces the existing summary, so
   use it only when regeneration is intended. Prereleases may be excluded from automatic drafting;
   write their notes explicitly and identify them as prereleases without changing the stable download.
3. Enable **On the changelog page** and save. Draft generation and appcast import do not set this
   flag. Publishing also triggers the website's configured Slack notification; use this workflow
   within the user's release authorisation and any applicable messaging permissions.
4. Fetch the public changelog and verify the version, headline and summary at `#v<version>`.
   An admin save or a green app workflow alone does not prove the notes are public.

Use the same release facts on GitHub and the website; the website may use a shorter editorial
summary. If production access is missing, leave the prepared text and report website publication
as outstanding. Do not mark the release complete.

The current procedure is implemented by the website's `SyncReleasesCommand`,
`DraftReleaseSummary`, `ReleaseForm` and `Release` model. Check those files when the admin labels
or automation differ, rather than guessing a production command or connection.

## Bloom Server

The same release publishes the Linux server. There is no separate server tag and no separate
server version: the tag is both. Three files are attached to the GitHub release beside the zip and
the disk image, and nothing server related goes to the bucket, because the only thing that
downloads it reads GitHub.

| Asset | Who reads it |
| --- | --- |
| `bloom-server-linux-x86_64.tar.gz` | The maintenance supervisor on every server, which updates to it. The Mac app bundles the same bytes for the setup assistant. |
| `bloom-server-linux-x86_64.tar.gz.sha256` | People, and `install-bloom-server.py --sha256`. The format `sha256sum -c` reads. |
| `bloom-server-linux-x86_64.json` | People and scripts: `tag`, `version`, `protocolVersion`, `maintenanceProtocolVersion`, `architecture`, `glibc`, `sha256` and `size`. |

The supervisor reads neither sidecar. It trusts the SHA-256 digest GitHub computes for the uploaded
tarball, and reads the version and protocol from the `manifest.json` inside it. The sidecars are
there so a release can be checked by a person without the API.

### How it is built

The `server-package` job runs in `swift:6.3.3-noble`, which is Ubuntu 24.04: the package keeps the
host's glibc, so the oldest supported Ubuntu sets the minimum, and `Tools/package-linux-server.py`
refuses any other build environment. It builds `bloom-server` and `bloom-bridge` in release
configuration with `-warnings-as-errors`, and packages with the tag in `BLOOM_SERVER_VERSION`, which
is written into `manifest.json`.

`Tools/server-release-assets.py describe` then puts the tarball through the supervisor's own
extraction and manifest checks, imported from `Tools/bloom-maintenance.py` rather than restated,
with the tag as the expected version and the wire protocol from `RemoteCommand.swift`. Only then
does it write the two sidecars. A package this accepts is one every current supervisor would accept.

The macOS job needs that one, so a server that fails to build or package stops the release before
anything is signed. It checks the artefact's checksum, builds the app with the tarball embedded,
and compares the embedded copy with `cmp`. After the appcast is written, the release event attaches
all three files and `Tools/server-release-assets.py verify` reads the release back from the API and
confirms GitHub's digest and size are those of the file the app bundled. The upload is after the
appcast so a server is never offered a version whose app did not ship.

The Server workflow runs the same packaging and `describe` on every pull request, on its debug
build and with a `v0.0.0-ci.<run>` tag, then checks and runs that package on Ubuntu 24.04 and 26.04
without Swift installed. `Tools/test-server-release-assets.py` covers the checks themselves.

Pull requests build debug, so before tagging, ask for the release build on its own:
`gh workflow run server.yml --repo spatie/bloom --ref <branch> -f release_build=true`. Its
`release-package` job runs the release job's build, packaging and description without uploading.

### How compatibility is decided

The supervisor looks at `releases/latest` for `spatie/bloom`, which GitHub defines as the release
marked latest, never a draft or a prerelease. It offers that release when it carries exactly one
`bloom-server-linux-x86_64.tar.gz` with a digest and its tag is newer than the installed version.
It never offers a downgrade. **Prereleases are never offered to servers**; there is no server beta
channel.

After downloading by asset ID it requires GitHub's digest, plain files and directories under
`bloom-server-linux-x86_64/`, and a manifest naming the reviewed version, `x86_64`, maintenance
protocol 1 and the wire protocol the supervisor was installed for. Any mismatch fails the job before
the running release is touched. It then snapshots the database, starts the new release as a trial,
and restores the previous release and database if startup verification fails, which the job reports
as `rolledBack`.

Compatibility is by protocol version, and today the accepted range is one version. The app, the
gateway, the server and the supervisor all enforce 14, and the administrator installer writes
`protocol_version=14` into the supervisor's configuration. So a release that raises
`BloomWire.version` is refused with `incompatible_release` by every supervisor installed for the old
protocol, and those servers move through **Update Server…** in the new app, which reinstalls the
supervisor as well. Raising the protocol means changing `Tools/bloom_maintenance_install.py` in the
same commit, and saying in the release notes that servers need the administrator update.

`latest` is a flag on GitHub rather than the highest tag. A patch to an older line published with
"Set as the latest release" would point every server at it, and servers already newer would see no
update. Publish those with `--latest=false`.

### Checking a release's server assets

The workflow's verify step is the check. To repeat it, or after a dispatch:

```sh
tag=v1.4.0
dir="$(mktemp -d)"
gh release view "$tag" --repo spatie/bloom --json assets --jq '.assets[] | [.name, .size, .digest] | @tsv'
gh api repos/spatie/bloom/releases/latest --jq .tag_name
gh release download "$tag" --repo spatie/bloom --pattern 'bloom-server-linux-x86_64*' --dir "$dir"
(cd "$dir" && shasum -a 256 -c bloom-server-linux-x86_64.tar.gz.sha256)
gh api "repos/spatie/bloom/releases/tags/$tag" > "$dir/release.json"
python3 Tools/server-release-assets.py verify "$dir/bloom-server-linux-x86_64.tar.gz" --release "$dir/release.json"
```

For a stable release `releases/latest` has to print the new tag, or no server is offered it. The
`sha256` in `Bloom.app/Contents/Resources/ServerSetup/package.json` inside the published zip is the
same digest.

### How the in-app updater picks it up

Server Settings > Updates asks the server's supervisor, which asks GitHub. It caches the answer for
up to fifteen minutes, so a server may take that long to show the new version; reviewing an update
always looks again, and the plan it returns pins the asset ID and digest it will install. A plan
reviewed before an asset was replaced fails with `checksum_mismatch` rather than installing the
replacement. [docs/SERVER.md](docs/SERVER.md#server-updates) describes the flow a person sees.

### When the server asset is broken

- **Packaging failed.** The macOS job never started, so nothing was signed or published. A runner
  failure is a `gh run rerun <run-id>`. A real build failure is fixed on `main` and released as the
  next patch version; a published tag is not moved.
- **The app shipped but attaching or verifying failed.** Attach the artefact from that same run,
  kept for thirty days for this, so the digest still matches the copy in the app:
  `gh run download <run-id> --name bundled-linux-server --dir <dir>`, then
  `gh release upload <tag> <dir>/bloom-server-linux-x86_64* --clobber`, then the check above. This
  is also how a `workflow_dispatch` rebuild gets its server assets, since dispatch attaches nothing.
- **Servers are rolling back from it.** Each server has already restored itself. Stop the offer
  with `gh release delete-asset <tag> bloom-server-linux-x86_64.tar.gz --repo spatie/bloom --yes`,
  and supervisors report that the release has no server package. Do not upload different bytes
  under the same tag: the app of that version bundles the original. Ship the fix as a patch release.
- **A server updated and needs the previous version.** The supervisor does not downgrade. Use
  **Update Server…** from a Mac app that bundles the wanted version.

### Why it stays in this repository

The wire protocol, BloomCore and the tests that pin both are shared by the Mac app, the server and
the iOS clients. In a repository of its own, every protocol change would be a coordinated release
of two repositories with a window where the published halves disagree. Publishing the server on its
own schedule never needed a second repository: it needs its own assets, which a release here
already has.

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

## Verified release path

The complete zip and disk-image pipeline has shipped. Release v1.2.0, build 1208,
completed in [workflow run 34130547271](https://github.com/spatie/bloom/actions/runs/34130547271):
signing, notarisation, stapling, uploads and appcast publication all passed.
The public download redirected to its disk image and the website changelog was published.

That is evidence for the pipeline, not a substitute for checking the next release. After every
release, verify the workflow, both public artefacts, the appcast version and the website download
redirect. Publish the matching notes on `runbloom.app/changelog` as well as on GitHub.

`Tools/package-licences.sh` includes Bloom and dependency notices inside the app before signing.
It reads SwiftPM's pinned checkouts and fails if a notice is missing. The independent packaging
test runs in CI. Changes to dependencies should include a review of their distribution notices.

## Testing the parts that need no secrets

```sh
Tools/release/tests/run.sh
```

Version derivation, appcast generation, and the Sparkle key derivation, checked
by signing with Sparkle's own tool and verifying with openssl.
