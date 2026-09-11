# Working with code in Bloom

Open a file from the inspector, a transcript reference or Command-P. Add `:line` or
`:line:column` to a filename in Command-P to open at that position. Transcript references such as
`Sources/App.swift:42` and Markdown file links open inside Bloom. Back and Forward remember file
positions within each workspace.

The file toolbar offers Find, navigation, a language override, line wrapping and the current line
and column. Reading and editing use the same native text surface and retain selection and scroll
position when switching files. Command-E switches between reading or reviewing and editing.

The Navigate menu contains:

- **Search workspace code:** case-insensitive text search across tracked and unignored files.
  Results open at their matching lines. Searches show up to 200 matching lines and skip binary
  files, files larger than 1 MB and symlinks outside the workspace.
- **Jump to symbol:** filter declarations in the current buffer, including unsaved edits.
  This lightweight outline recognises common declaration syntax. It is not a semantic index.
- **Go to line:** accepts a one-based line and optional column, such as `42:7`.
- **Go to Definition:** asks an installed language server about the symbol at the caret.
- **Find Usages:** lists references to the symbol, excluding its declaration.
- **Ask about selected code:** appends the file, line range and selected text to the chosen
  conversation's draft. It does not send the message.

Command-click a relative import or file path to follow it. Command-click a symbol to request its
definition. When that definition points back to the clicked symbol, Command-click lists its usages
instead. Command-Shift-click opens the destination in a new tab, including a destination chosen
from multiple results. A single definition or usage opens directly. Go to Definition and Find
Usages are both available in the contextual menu. Bloom looks for
SourceKit-LSP, TypeScript Language Server, Intelephense, Pyright, rust-analyzer, gopls, Ruby LSP or
Vue Language Server on PATH, according to the file's language. It does not install servers.
Lookups reuse a connection for up to a minute of inactivity, using the
[Language Server Protocol](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/).
Project dependencies and the server's available build information determine what it can resolve.
Multiple definitions open a native menu beside the symbol, with project-relative paths.
Ignored files follow project files, and Laravel Idea helpers under `vendor/_laravel_idea/` come last; missing servers and failed requests are reported in the pane.

For PHP and Blade files inside a Laravel app, Bloom also queries
[Laravel LSP](https://github.com/laravel/lsp). Install it with
`composer global require laravel/lsp` and put Composer's global `vendor/bin` directory on PATH.
Intelephense handles PHP symbols and usages; Laravel LSP adds framework definitions such as
`view('front.blog.index')`, which opens `resources/views/front/blog/index.blade.php`.
Both use the current editor contents, including unsaved changes. Results are combined and deduplicated.
The nearest directory containing `artisan` and `composer.json` within the workspace is the Laravel
root. Its dependencies, including Tinker, must be installed so Laravel LSP can boot the app.
Bloom forwards file changes to refresh Laravel's index and disables Pest helper generation.
Quoted PHP and Blade references try language servers before the ordinary file-path fallback.
Command-Shift-click opens the result in a new tab, including Laravel views.

Hold Command over a word to underline the definition lookup target. The underline marks where a
lookup can be requested; the language server may still return no definition. Command-[ and
Command-] move backwards and forwards while a file or diff pane has focus.

The editor supports native undo and find, automatic indentation, Tab and Shift-Tab for indenting
selections, Command-Option-[ and Command-Option-] for indentation, and Command-/ for toggling comments.
Matching brackets and the current line are highlighted. Syntax colouring includes embedded script
and style regions in Vue and HTML, Blade expressions, and JSX attributes and expressions.
Large buffers remain editable with plain text above the highlighting limit of 400,000 UTF-16 units.
Files must be UTF-8 text and at most 4 MB.

The standalone diff has a find field with previous and next matching lines, including deletions.
Searching reveals folded context. Its Open source action opens the current match in the editor;
the contextual menu can also open the source at the beginning of a displayed code block.

Open files are checked for disk changes every three seconds. Clean buffers refresh automatically.
Unsaved edits stay intact when an agent changes the file. Compare shows the draft beside the disk
version and offers to keep editing, use the disk version or explicitly save the draft over it.
Saving still refuses a disk version that changed after the comparison was loaded.

For development, `Bloom --source-editor-probe` checks the native editor in an unshown window and
writes light and dark screenshots under `/tmp/editor-*.png`. Add `--language-server` to check a
real SourceKit-LSP lookup between two temporary Swift files. Use an isolated `BLOOM_DB_PATH`.

`./Tools/test-core.sh EditorExperienceTests WorktreeWatcherTests` covers navigation and file
watching. Set `BLOOM_LOCAL_LSP=1` for the real Intelephense check. To also test Laravel view links,
set `BLOOM_LARAVEL_LSP_VENDOR` to the `vendor` directory of a disposable Laravel app with Tinker
installed; the test creates its own app and checks unsaved content and renamed Blade files.
