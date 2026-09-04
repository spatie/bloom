# Menus and keys

Every action Bloom can perform, where it is reachable from, and which key it carries. Read off the
source on 2026-08-27 rather than remembered.

## The rule this document exists to hold

**A premium Mac app publishes every action in the menu bar, with its key beside it, so you learn
the keys by using the menus.** A context menu is a shortcut to somewhere you already are; the menu
bar is the map of what the app can do. An action that lives only on a right click, only on a hover
button, or only as a keystroke nobody wrote down is an action most users will never find.

Three corollaries, and each of them is a decision the code has already taken somewhere:

- **Greyed rather than absent, in the menu bar.** The opposite of what the context menus do.
  `BloomCommands` already greys Split Right on a Notes tab rather than dropping it, and the
  Workspace menu greys every item when nothing is selected. A row that vanishes teaches nothing.
- **One action, one name.** A menu item and the context menu offering the same thing say the same
  words. `PaneKind.title`, `PaneNaming`, `BrowserToolbar.Control.name` and `SetupRunOffer.title`
  each exist because two surfaces were naming one action two ways.
- **A key equivalent claimed by a focused view beats the menu bar**, and a key registered on both
  a hidden button and a menu item is not a tie: the button wins and the item never fires. This was
  measured three times in this repository. So a key is either the menu's or the view's, never both.

## The menu bar today

`Sources/Bloom/Views/Chrome/App/BloomCommands.swift`, plus `RepoSettingsCommands` in
`Sources/Bloom/Views/RepoSettings/RepoSettingsWindow.swift`, plus what SwiftUI and AppKit
contribute for free.

### Bloom

| Item | Key | Source |
| --- | --- | --- |
| About Bloom | | ours, replacing `.appInfo` |
| Check for Updates… | | ours, Sparkle |
| Settings… | `⌘,` | SwiftUI's `Settings` scene |
| Services, Hide, Hide Others, Show All, Quit | `⌘H` `⌥⌘H` `⌘Q` | AppKit |

### File

| Item | Key | Enabled when |
| --- | --- | --- |
| New Workspace… | `⌘N` | a project exists |
| New Workspace from Pull Request… | | a project exists |
| Project Settings… | `⇧⌘,` | a project exists |
| New Session | `⌘T` | a workspace is selected |
| New Terminal Tab | `⇧⌘T` | a workspace is selected |
| New Browser Tab | `⇧⌘B` | a workspace is selected |
| Show Changes | `⇧⌘D` | a workspace is selected |
| Show Notes | `⇧⌘N` | a workspace is selected |
| Rename Tab | | the tab in front has a name to change |
| Close Tab | `⌘W` | main window is key and a tab is closable |
| Start a Project… | `⌥⌘N` | always |
| Save | `⌘S` | a window has published a `SaveAction` |

### Edit

| Item | Key | Notes |
| --- | --- | --- |
| Undo, Redo, Cut, Copy, Paste, Select All | `⌘Z` `⇧⌘Z` `⌘X` `⌘C` `⌘V` `⌘A` | AppKit |
| Find > Find… | `⌘F` | falls through to Search when nothing in front can find |
| Find > Find Next | `⌘G` | |
| Find > Find Previous | `⇧⌘G` | |
| Quick Search… | `⌘K` | always, but a focused terminal keeps the key |
| Search | `⇧⌘F` | a project exists |

### View

| Item | Key | Enabled when |
| --- | --- | --- |
| Split Right > Chat / Terminal / Browser | `⌘\` on the kind this pane is | a workspace is selected |
| Split Down > Chat / Terminal / Browser | `⇧⌘\` on the kind this pane is | a workspace is selected |
| Close Pane | `⌃⌘W` | a workspace is selected |
| Zoom Pane | `⇧⌘↩` | a split shell is in front |
| Focus Pane > Left / Right / Up / Down | | a split shell is in front |
| Previous Tab / Next Tab | `⇧⌘[` `⇧⌘]` | the strip has more than one tab |
| Go to Tab > (each tab) | `⌘1`…`⌘9` | the strip is not empty |
| Next / Previous Changed File | `⌥⌘J` `⌥⌘K` | a review is open and something changed |
| Toggle Sidebar | `⌃⌘S` | always |
| Toggle Inspector | `⌥⌘I` | a workspace is selected |
| Next / Previous Workspace | `⌥⌘↓` `⌥⌘↑` | any workspace exists |
| Next Unread | `⇧⌘U` | something is unread |
| Go to Home | `⇧⌘H` | not already on Home |
| Zoom In / Zoom Out / Actual Size | `⌘+` `⌘-` `⌘0` | the focused text can zoom |
| Enter Full Screen | `⌃⌘F` | AppKit |

### Workspace

| Item | Key | Enabled when |
| --- | --- | --- |
| Rename | | a workspace is the subject |
| Pin / Unpin | | a live workspace is the subject |
| Mark as Unread / Mark as Read | | a live workspace is the subject |
| Colour > None and ten colours | | a live workspace is the subject |
| Merge / Squash and merge / Rebase and merge | | the pull request band is on screen and GitHub will take a merge |
| Archive Workspace | `⌘⌫` | a live workspace is the subject |
| Restore Workspace | | an archived workspace is the subject |
| Open in Editor | `⇧⌘E` | a live workspace is the subject |
| Reveal in Finder | `⇧⌘R` | a live workspace is the subject |
| Copy Name | | live or archived |
| Copy Branch Name | `⇧⌘C` | live or archived |
| Run Setup / Run Setup Again | | the project has a setup script |
| Run > (each run script) | | the project has run scripts |
| Stop Agent | `⌘.` | a turn is running |

### Window

Entirely SwiftUI's and AppKit's: Minimise `⌘M`, Zoom, Fill and Arrange, Bloom, Discovered Seas,
Bring All to Front, then the window list. `⇧⌘W` closes the window, forced onto the item by
`WindowCloseShortcut` because `⌘W` belongs to the tab.

**Nothing was added to it, and that is the answer rather than an omission.** Each `Window` scene
contributes its own item, which both opens the window when it is closed and raises it when it is
not, so Bloom and Discovered Seas are already there and a command of our own would print either
name twice. The project settings windows are a `WindowGroup(id:for:)`, which contributes no item
of its own and is opened from File instead, where a project is already dealt with. What is left is
the standard set, and it is complete.

### Help

Bloom Help `⌘?`, Welcome to Bloom…, Send Feedback… `⌥⌘F`, Submit a Prompt…

## Every other surface, and what it holds

The columns are: is it in the menu bar, does it carry a key, is that key discoverable.

### The centre pane's own menu (`CenterPaneMenu`, right click on a pane)

| Action | In the menu bar | Key |
| --- | --- | --- |
| Split Right > Chat / Terminal / Browser | yes | `⌘\` on the kind this pane is |
| Split Down > Chat / Terminal / Browser | yes | `⇧⌘\` on the kind this pane is |
| Close Pane | yes | `⌃⌘W` |

**This was the headline gap and it is closed.** The View menu's Split Right and Split Down used to
DUPLICATE: a chat twice, a fresh shell, the same page again. The split people actually want, a
browser or a terminal beside the conversation, existed only in this two-level context menu with no
key on it and no menu bar item anywhere. `CenterPaneMenu`'s own doc says a second copy of a
transcript is almost never the point.

The keystroke changed meaning with it, and that is worth knowing: `⌘\` now means "another one of
these, beside this one" rather than "this one again". On a shell it does what it always did. On a
browser it opens the address field rather than the page you were on, and on a conversation it
starts a new one rather than showing the same transcript in both halves. The context menu still
carries no key equivalents, for the reason written at the head of `CenterPaneMenu`.

### A terminal pane's menu (`TerminalPaneMenu`, AppKit, right click in a shell)

| Action | In the menu bar | Key | Who claims the key |
| --- | --- | --- | --- |
| Split Right > Chat / Terminal / Browser | **no** | `⌘D` on Terminal | `BloomTerminalView.performKeyEquivalent` |
| Split Down > Chat / Terminal / Browser | **no** | `⇧⌘D` on Terminal | same |
| Zoom Pane / Zoom Out | **no** | `⇧⌘↩` | same |
| Close Pane | yes | `⌘W` | same, and it means the pane rather than the tab |

`⌘D` is drawn on the Terminal row rather than on the parent, because AppKit never fires the action
of an item that has a submenu. That trick is the one the View menu should borrow.

### A terminal pane, keys with no menu item at all

| Action | Key | Anywhere in a menu |
| --- | --- | --- |
| Focus pane left / right / up / down | `⌥⌘←→↑↓` | **no** |
| Clear the shell and its scrollback | `⌘K` | **no**, and it beats Edit's Quick Search |
| Copy, Paste | `⌘C` `⌘V` | Edit menu's, but the terminal answers them itself |
| Terminal text bigger / smaller / actual | `⌘+` `⌘-` `⌘0` | View menu's Zoom trio, resolved onto the terminal |

### A tab (`TabItemView`, right click on a tab)

| Action | In the menu bar | Key |
| --- | --- | --- |
| Open in Split Right / Split Down | **no** | none |
| Rename | **no** | none |
| Close | yes, as Close Tab | `⌘W` |

Dragging a tab onto a pane's edge does the same thing as Open in Split Right, and is discoverable
only by trying it.

### A workspace row (`WorkspaceMenuItems`, sidebar and Home)

| Action | In the menu bar | Key |
| --- | --- | --- |
| Open in Editor | yes | `⇧⌘E` |
| Reveal in Finder | yes | `⇧⌘R` |
| Copy Branch Name | yes | `⇧⌘C` |
| Run Setup / Run Setup Again | yes | none |
| Pin / Unpin | **no** | none |
| Mark as Read / Mark as Unread | **no** | none |
| Colour > None and ten colours | **no** | none |
| Rename | yes | none |
| Archive | yes | `⌘⌫` |

An archived row (`HomeRowMenu`) offers Open, Restore Workspace and Copy Branch Name. Restore and
Copy Branch Name are in the menu bar; **Open, which opens an archived transcript for reading, is
not.**

### The window's title (`WorkspaceMenuItems`, scope `.title`)

Rename, Copy Name, Copy Branch Name, Open in Editor, Reveal in Finder. **Copy Name is nowhere in
the menu bar**; the other four are. Double clicking the title renames, which is discoverable only
from the tooltip.

### A project header (`ProjectMenuItems`, right click on a project)

| Action | In the menu bar | Key |
| --- | --- | --- |
| New workspace | yes, as New Workspace… | `⌘N` |
| Rename | **no** | none |
| Project settings… | yes | `⇧⌘,` |
| Reveal in Finder | **no** | none |
| Hide project / Unhide project | **no** | none |
| Remove project | **no** | none |

The File menu's Project Settings… acts on the selected workspace's project; this menu acts on the
project it was raised from. The two are not always the same project, which is worth saying out
loud somewhere a user can read it.

### The browser pane

| Action | Where it lives | In the menu bar | Key |
| --- | --- | --- | --- |
| Back / Forward | toolbar arrows | **no** | none |
| Jump back or forward several pages | right click on an arrow | **no** | none |
| Reload / Stop | toolbar | **no** | none |
| Send a Screenshot to the Agent | toolbar, and the page menu | **no** | none |
| Share | toolbar | **no** | none |
| Open in External Browser | page context menu | **no** | none |
| Find in page, next, previous | find bar | yes, Edit > Find | `⌘F` `⌘G` `⇧⌘G` |
| Downloads bar dismissal | the bar itself | **no** | none |

A browser with no Back in any menu is the second most obvious gap after the split.

### The inspector

| Action | Where it lives | In the menu bar | Key |
| --- | --- | --- | --- |
| Changes / Files / Pull Request tabs | segmented picker | **no** | none |
| What the changes are measured from (`DiffScopeMenuItems`) | toolbar menu | **no** | none |
| Copy Branch Name, Reveal Worktree in Finder, Open in… (`WorktreeMenuItems`) | overflow menu | partly | `⇧⌘C`, `⇧⌘R` |
| Open Pull Request, Share pull request | overflow menu | **no** | none |
| Toggle diff and edit | hidden button | **no** | `⌘E` |
| Unified / side by side | file bar menu | **no** | none |
| Ignore whitespace | file bar menu | **no** | none |
| Revert file | file bar menu and row menu | **no** | none |
| Reveal in Finder, Copy path (a changed file, a folder, a tree row) | row menus | **no** | none |
| Comment on This Line | diff line menu | **no** | none |
| Send This Failure to the Agent | check row menu | **no** | none |
| Open on GitHub, Copy link (pull request) | summary menu | **no** | none |
| Merge, Squash and merge, Rebase and merge | the band's split button | yes | none |
| Choose the merge method | the split button's chevron | **no**, deliberately | none |
| Create pull request, Continue, Archive, Fix merge conflicts | buttons | Archive only | `⌘⌫` |
| Save an edited file | hidden button | greyed, always | `⌘S` |

`⌘E` and `⌘S` are both hidden `keyboardShortcut` buttons with no menu item, which is the exact
pattern this repository has already removed twice (the four tab keys, and the review's `⌥⌘J/K`).
`FileEditPane` binds `⌘S` and does not publish a `SaveAction`, so the File menu's Save is greyed
while a file edit is exactly what `⌘S` would write. `FocusedMenuValues` asks for that publication
in its own doc comment.

### The composer

| Action | Where it lives | In the menu bar | Key |
| --- | --- | --- | --- |
| Send | Return in the box | **no** | `↩` |
| Newline | `⇧↩` | **no** | `⇧↩` |
| Stop the agent | stop button | yes | `⌘.` |
| Insert a quick prompt | footer button and `/` menu | **no** | none |
| Edit or delete a quick prompt | row menu | **no** | none |
| Attach a file | footer button, paste, drop | **no** | none |
| Fast mode | footer toggle | **no** | none |
| Slash commands | `/` menu | **no** | none |
| File mentions | `@` menu | **no** | none |
| Show a review comment in the diff, remove it | chip menu | **no** | none |

### The transcript

| Action | Where it lives | In the menu bar | Key |
| --- | --- | --- | --- |
| Copy answer, Copy files touched, Copy raw event | turn footer menu | **no** | none |
| Copy Link, Open Link, Open in External Browser, open in a split | link menu | **no** | none |
| Allow once / This session / Always allow / Deny / Deny and stop | permission card | **no** | `⌘↩` on the default |
| Copy the subject of a permission ask | card menu | **no** | none |
| Answer an agent's question | question card | **no** | `↩` on the default |
| Run this repository's setup script again | failed setup row | yes | none |

### Home and the sidebar

| Action | Where it lives | In the menu bar | Key |
| --- | --- | --- | --- |
| Start a project (sidebar heading, both empty states) | `+` button, buttons | yes | `⌥⌘N` |
| Home scopes: All, Needs you, Running, Live, Archived | chip strip | **no** | none |
| Home project filter | menu | **no** | none |
| Sidebar filter: which workspaces, hidden projects (`SidebarFilterMenuItems`) | status bar menu | **no** | none |
| What the sidebar glyphs mean | status bar button | **no** | none |
| Settings | status bar button | yes | `⌘,` |
| Reorder projects, reorder workspaces | drag | **no** | none |
| Archive a workspace, with a confirmation | row hover button | yes, without the confirmation | `⌘⌫` |
| Resize the sidebar, the inspector, the composer, a pane | drag a divider | **no** | none |

### Settings and the project settings window

Agents, appearance, prompts and the per project settings are all reachable from `⌘,` and `⇧⌘,`.
Removing a project from Settings, and removing a run script, are buttons inside those windows and
belong there. Storage was a pane here and is not any more: what the archived work costs, and the
only way to give the space back, are on Home's Archived chip, beside the rows they are about.

## Keys, and who wins

Every key equivalent registered anywhere, and which registration takes the press. A view that has
first responder beats the menu bar; a hidden `keyboardShortcut` button in the view hierarchy beats
a menu item.

| Key | Menu bar | View claim | Winner when both apply |
| --- | --- | --- | --- |
| `⌘\` `⇧⌘\` | Split Right / Down | none | menu bar |
| `⌘D` `⇧⌘D` | none | terminal splits a shell | terminal |
| `⇧⌘↩` | none | terminal zooms the pane | terminal |
| `⌥⌘←→` | none | terminal moves pane focus | terminal |
| `⌥⌘↑↓` | Previous / Next Workspace | terminal moves pane focus | **terminal, silently** |
| `⌘W` | Close Tab | terminal closes the pane | terminal, deliberately |
| `⌘K` | Quick Search… | terminal clears the shell | terminal, deliberately |
| `⌘C` `⌘V` | Edit's own | terminal copies and pastes | terminal |
| `⌘+` `⌘-` `⌘0` | Zoom In / Out / Actual Size | terminal text size | terminal, and both act on the same shell |
| `⌘F` `⌘G` `⇧⌘G` | Find submenu | browser finds in the page | browser, when the page has the keyboard |
| `⌘G` `⇧⌘G` | Find Next / Previous | the browser find bar's own buttons | the bar, while it is up |
| `⌘E` | none | inspector toggles diff and edit | the hidden button |
| `⌘S` | Save | `FileEditPane`, `RepoSettingsSaveBar` | the button, and Save is greyed for the first |
| `⇧⌘[` `⇧⌘]` | Previous / Next Tab | the create sheet's source picker | the sheet, while it is up |

**One of these is a bug rather than an allocation.** `⌥⌘↑` and `⌥⌘↓` mean Previous and Next
Workspace in the View menu and mean "move the focus one pane up or down" inside a terminal. Both
are reasonable bindings taken from different applications, and nothing in the app says which one
you are about to get. It is listed here rather than fixed here, because changing either is a
decision about muscle memory rather than about menus.

## Where the work was cut

**This branch.** The split, which was the finding that started this: the View menu's two items take
the same three kinds the context menus have, and `⌘\` and `⇧⌘\` move onto the row meaning "the same
again". Then the actions that belong to the window and to a workspace: the Workspace menu becomes
everything a workspace row's menu offers, plus the merge, which had no item in any menu at all; the
tab actions are completed, the terminal pane's own actions are published, and the standard menus
are checked for shape.

**Left for a second pass**, in the order they are worth doing:

1. **The browser.** Back, Forward, Reload and Stop, Open in External Browser, Send a Screenshot to
   the Agent, Share. Needs no new plumbing: `CenterTabStore.liveBrowser(for:)` already hands over
   the session, and `BrowserToolbar.Control.name` already holds the wording. `⌘[`, `⌘]` and `⌘R`
   are free.
2. **The inspector.** The tab picker, the diff scope, the file bar's three toggles, Revert file,
   Copy path, and the remaining pull request items. Two of these need `⌘E` and `⌘S` moved off their
   hidden buttons onto `@FocusedValue`s, which is what `FocusedMenuValues` already asks for and
   what the merge item on this branch is the worked example of.
3. **A Project menu, or a project group in File.** Rename, Reveal in Finder, Hide, Remove. Four
   items that exist only on a right click.
4. **The composer and the transcript.** Attach a file, insert a quick prompt, fast mode, and the
   turn footer's three copies.

## What should stay out of the menu bar, and why

- **Dragging.** Reordering projects and workspaces, dragging a tab onto a pane edge, and every
  divider. Each has a menu equivalent already or is a direct manipulation with no discrete action
  behind it. Dragging a tab onto a pane edge is Open in Split Right, which does belong in a menu.
- **The composer's Return and Shift Return.** They are text editing, not commands, and a menu item
  for "type a newline" is noise.
- **Rows of a list.** An item that acts on the row the pointer is over has no subject at the top of
  the screen: Reveal in Finder on a changed file, Copy path on a folder, Open Terminal Tab Here on
  a tree row. The tabs are in Go to Tab because nine keys hang off them and the selected tab is a
  real subject. The workspaces are in the sidebar and reachable with `⌥⌘↑↓`; a Workspaces submenu
  listing every workspace on the machine would be a second sidebar that goes stale.
- **Choosing the merge method.** It is a per-project mode, set from the split button's chevron and
  remembered. A submenu of the three in the menu bar would be a second place to set it, and a row
  in it would have to both change the mode and merge, which is the one thing that button's own menu
  refuses to do. The menu bar's item says which merge is in force and performs that one.
- **Anything inside Settings or the project settings window.** Removing a run script is a button in
  the editor that owns it. A menu bar item for it would have to name which script.
- **Discovered Seas.** A `Window` scene contributes its own Window menu item, and a command of our
  own printed the name twice. See the comment at the head of `OceansWindow`.
- **Ask Siri.** macOS puts it on context menus itself. It is not ours to move or to mirror.
