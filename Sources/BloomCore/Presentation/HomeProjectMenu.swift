import Foundation

/// The rows of Home's project menu, and the order they come in.
///
/// **Alphabetical, not the sidebar's stored order.** The sidebar is arranged by hand and read by
/// position, so its order means something there. This menu is a list somebody scans for a name,
/// and at thirty projects the stored order reads as no order at all: the owner's copy put
/// `monizze` first and `laravel-honeypot` last, with five `laravel-` packages scattered between.
/// `localizedStandardCompare` is Finder's rule, so case does not split `VicGames` off from the rest
/// and a `2` sorts before a `10`.
///
/// **Visible projects first, hidden ones after.** A hidden project still needs a row here, because
/// its workspaces keep turning up on Home (see `ProjectVisibility`, which is emphatic that hiding
/// loses nothing), and a filter that cannot reach rows the list is showing is a filter with a hole
/// in it. But the owner has said those projects are not worth the room, so they go below the ones
/// he works in rather than interleaved with them.
public struct HomeProjectMenu: Equatable, Sendable {
    public var visible: [Repo]
    public var hidden: [Repo]

    public init(_ repos: [Repo]) {
        let sorted = repos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        visible = sorted.filter { !$0.hidden }
        hidden = sorted.filter(\.hidden)
    }
}
