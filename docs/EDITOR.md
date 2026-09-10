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
- **Ask about selected code:** appends the file, line range and selected text to the chosen
  conversation's draft. It does not send the message.

Command-click a relative import or file path to follow it. Command-click a symbol to request its
definition. Go to Definition is also available in the editor's contextual menu. Bloom looks for
SourceKit-LSP, TypeScript Language Server, Intelephense, Pyright, rust-analyzer, gopls, Ruby LSP or
Vue Language Server on PATH, according to the file's language. It does not install servers.
Lookups reuse a connection for up to a minute of inactivity, using the
[Language Server Protocol](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/).
Project dependencies and the server's available build information determine what it can resolve.
Multiple definitions offer a chooser; missing servers and failed requests are reported in the pane.

The editor supports native undo and find, automatic indentation, Tab and Shift-Tab for indenting
selections, Command-[ and Command-] for indentation, and Command-/ for toggling comments.
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
