# Open: crash and beachball when creating a workspace

Status as of the pause. Reproducible, root cause NOT yet found. Bisecting is partly done, and
the results below rule several things out, so do not re-run those.

## Symptom

Creating a workspace (deep link or the sheet) beachballs the window for a few seconds, then the
app dies with:

```
*** Terminating app due to uncaught exception 'NSGenericException', reason:
'The window has been marked as needing another Update Constraints in Window pass, but it has
already had more Update Constraints in Window passes than there are views in the window.
<SwiftUI.AppKitWindow: 0x...> {{153, 105}, {1440, 900}}'
```

That is an unbounded layout-invalidation loop, not a single bad update. Two exceptions are thrown
per run.

## Reliable reproduction

```sh
# a repo whose setup script prints 4000 lines
/tmp/baton-fixrepo                      # recreate if gone, see below
BATON_DB_PATH=/tmp/shots/fix.sqlite .build/arm64-apple-macosx/debug/Baton.app/Contents/MacOS/Baton
open "baton://prompt=...&path=%2Fprivate%2Ftmp%2Fbaton-fixrepo"
```

Dies within about 6 seconds of the deep link. stderr carries the exception and the stack;
`~/Library/Logs/DiagnosticReports/Baton-*.ips` has the full report.

Recreate the test repo:

```sh
D=/tmp/baton-fixrepo; rm -rf $D; mkdir -p $D/app; cd $D
git init -q -b main; git config user.email d@d; git config user.name Demo
git config commit.gpgsign false
mkdir -p .conductor
printf '[scripts]\nsetup = %s\necho "starting"\nfor i in $(seq 1 4000); do echo "line $i"; done\n%s\n' "'''" "'''" > .conductor/settings.toml
echo "# Demo" > README.md; git add -A; git commit -qm initial
```

## The stack that matters

The most informative throw (there are two shapes, see below):

```
NSWindow _postWindowNeedsUpdateConstraints          <- throws here
NSView _informContainerThatSubviewsNeedUpdateConstraints
NSView setNeedsUpdateConstraints:
SwiftUI NSHostingView.setNeedsUpdate
SwiftUI NSHostingView.requestUpdate(after:)
SwiftUI ViewGraphHost.LayoutInvalidator.invalidate
SwiftUI AppKitPlatformViewHost.invalidateLayout          <- an NSViewRepresentable
SwiftUI AppKitPlatformViewHost.enqueueLayoutInvalidation
SwiftUI AppKitPlatformViewHost._layoutMetricsInvalidatedForHostedView
AppKit  _NSConstraintBasedLayoutHostingView constraintsDidChangeInEngine:
CoreAutoLayout NSISEngine tryToChangeConstraintSuchThatMarker:isReplacedByMarkerPlusDelta:
```

`AppKitPlatformViewHost` is SwiftUI's host for an **NSViewRepresentable**. Something wrapped in
one keeps changing its layout metrics, which invalidates, which re-measures, forever.

The other shape goes through `ToolbarBridge.preferencesDidChange` and
`Toolbar.LocationStorage.updatedVendedItems`, which is the toolbar re-vending its items during
its own update.

## Ruled OUT by bisecting (each disabled, crash still happened)

- The bottom panel and the embedded terminal (`BottomPanelView` removed from
  `WorkspaceDetailView`). Still crashed.
- The window toolbar (`.toolbar { toolbar }` removed from `RootView`). Still crashed.
- The composer (`ComposerView` replaced with a plain `Text`). Still crashed. One run of this
  configuration looked clean, but re-running it crashed with 2 exceptions, so that first result
  was a fluke. Do not trust a single clean run: this needs several.

## Still suspect

The remaining `NSViewRepresentable`s in the window, in rough order of suspicion:

1. `VisualEffectBackground` in `Theme.swift`, applied through `.sidebarMaterial()` and
   `.headerMaterial()`. It is in the sidebar, which is present in every crashing configuration.
2. `WindowAccessor` in `AppChrome.swift`.
3. Anything SwiftUI itself hosts through `AppKitPlatformViewHost` for `List` with
   `.listStyle(.sidebar)`, which is an `NSOutlineView` underneath. The sidebar was never
   disabled during bisecting, and it is the one thing common to every crashing run.

**The next bisect step should be the sidebar**: replace `SidebarView()` in `RootView` with a
plain `Text`, or swap the `List` for a `ScrollView` plus `LazyVStack`, and re-run several times.
The sidebar is the only major component not yet eliminated.

A related warning seen earlier, probably the same root cause:
`Application performed a reentrant operation in its NSTableView delegate.`

## Fixes already made (keep these, they were real bugs)

- `AppModel.selectedModel` used to call `model(for:)`, which creates a model and writes
  `existing.workspace`. Reading it from a view body therefore mutated observable state during
  the render pass. The toolbar read it four times per update. It is now a pure dictionary
  lookup, with `existingModel(for:)` alongside it, and `reload()` refreshes the models' workspace
  values off the render pass. This was certainly a bug; it was not, on its own, the whole crash.
- Setup output used to hop to the main actor once per line and append to a growing string, which
  is quadratic and floods the main queue. It is now batched through `LineBuffer` and flushed
  about eight times a second, capped at 200 KB. This is the most likely cause of the beachball.
- `WorkspaceModel.runSetupThenSend` read up to six settings files from disk synchronously on the
  main actor, at the exact moment a workspace is created. Now detached.
- The session tab strip is hidden whenever there is a single session.

## Unrelated but worth knowing

The window count read through the accessibility API drops to 0 a second or two after the deep
link, while the process is still alive. Unexplained. It may just be the API failing against a
stalled app, or it may be the window genuinely being torn down and rebuilt, which would be a
strong hint about the loop.
