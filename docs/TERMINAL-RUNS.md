# Run chat commands in the terminal

Shell code blocks offer **Run in terminal** beside Copy once the answer has finished streaming.
This covers `sh`, `bash`, `zsh`, `shell` and `console` fences in workspace chats. A block whose
non-empty lines all start with `$ ` has those prompts removed before running.

Run opens an interactive terminal below the chat in the workspace's worktree, using your shell.
You can answer password prompts and keep chatting while it runs. The next Run reuses the most
recent Run terminal once its previous command has ended. Running another block while it is
busy opens another terminal, including when you have started a command there yourself.

Bloom automatically queues a report for the chat where you clicked Run. It contains the command,
folder, exit status and cleaned output, with the last 400 lines retained. Very large recordings
also have a byte and character limit. The agent receives the report during its turn when supported,
or after the turn otherwise. A closed chat receives no report.

The transcript shows a dimmed completion line. Expand **What the model was handed** to inspect
the full report. The report is marked as untrusted data for the agent. Recording captures terminal
output, including ordinary echoed input, but does not capture keystrokes or passwords hidden by
the program's terminal settings. Closing the terminal stops Bloom watching that run.

Suggested by Bart Kaskes, who also supplied the initial implementation outline.
