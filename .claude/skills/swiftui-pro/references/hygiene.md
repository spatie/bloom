# Project checks

Follow `CLAUDE.md` for architecture, prose, lint and validation. `make lint` and `make swiftlint`
are separate checks. Core tests do not compile the app target.

Keep credentials out of the repository and out of ordinary defaults storage. Store secrets in
the appropriate keychain or existing credential mechanism; not all user preferences are secrets.

Follow the project's current localisation and asset pipeline. Do not assume a string catalogue,
generated localisation symbols or an Xcode project exists.

For visual verification use the repository's probes or offscreen rendering where appropriate.
`ImageRenderer` does not capture every AppKit-backed view. Do not claim a rendered SwiftUI image
verifies embedded terminals, web views or native window behaviour it cannot show.
