# Native remote terminals

Mac and iOS both use SwiftTerm 1.19.0. The iOS adapter uses its UIKit terminal view, native text
selection, hardware keyboard handling and built-in Esc/Tab/Ctrl/arrow accessory. A native toolbar
adds direct Ctrl-C, keyboard visibility, reconnect and close. No terminal emulator is reimplemented
in Bloom and no shell executes on the iOS device.

`RemoteTerminalConnection` is the shared transport contract: pull the next output `Data`, send
input, resize and close. The server owns the named tmux session. Closing a tab or disconnecting
detaches its transport; `workspace.closeTerminal(name:)` is the separate operation that ends the
shell. Reopening the same name restores the existing screen. A normal remote exit ends the stream
without showing an error. Input is never replayed automatically after an uncertain network failure.

## SSH relay

The app first requests the existing `terminalStream(workspaceID:name:)` RPC. This returns a
short-lived `/tmp/bloom-terminal-UUID.sock` capability for the owning runtime's tmux stream.
The app then opens a host-key-pinned SSH exec channel running the configured `bloom-server connect`
command. Its first line selects terminal relay protocol 1:

```json
{"terminalProtocol":1,"terminalSocket":"/tmp/bloom-terminal-00000000-0000-4000-8000-000000000001.sock"}
```

The updated connect executable accepts exactly these two fields. It requires the controlled
absolute filename, a valid UUID, a real socket according to `lstat`, and ownership by its own user.
Symlinks and arbitrary Unix sockets are refused. Success begins with `{"terminalReady":true}`;
failure begins with `{"terminalError":"explanation"}`. Subsequent lines are the existing terminal
frames. The first-line handshake is a transport binding, not a new runtime RPC operation.
An ordinary first-line RPC continues through the original JSON relay unchanged.

This works with the same restricted SSH forced command as ordinary Bloom RPC. It needs no PTY
permission, general shell execution, new public TCP port or less restrictive host-key policy.
An older connect executable closes the unsupported stream; the app gives an update/reopen error
with a bounded startup timeout. Upgrading the connect executable can be validated separately from
the long-running daemon. A running daemon need not restart for this transport extension.

Frames share one Swift value, `RemoteTerminalFrame`, which the server re-exports as
`ServerTerminalFrame`:

```json
{"kind":"input","data":"bHMNCg=="}
{"kind":"resize","columns":120,"rows":40}
{"kind":"output","data":"SGVsbG8NCg=="}
```

`data` is Base64. Input frames carry at most 16,384 decoded bytes; output frames at most 65,536.
Columns must be 2...500 and rows 2...300. Input lines longer than 100,000 bytes are refused by the
relay. The server relay polls bounded buffers in both directions, so blocked screen output cannot
starve keyboard input. Native SSH output pauses parent-socket reads until the renderer asks for
another frame. This matters because NIOSSH consumes parent read-complete events; disabling child
channel autoRead alone did not bound buffered output.

## HTTPS

The same controller uses `HTTPSTerminalConnection` over the existing authenticated gateway
WebSocket. `HTTPSConnection` supplies the API token just before opening the connection. Input and
output use binary frames; resize uses a JSON text frame. API tokens do not enter a browser or
preview webpage. See [server protocol](SERVER-PROTOCOL.md) for the endpoint and authentication.

## Verification

`SSHTerminalTests` runs a real local NIOSSH server and checks pinned host verification, 400 KB of
ANSI output under a slow reader, input, resize, closing a pending read, normal remote exit and
reconnection. `RemoteTerminalTests` checks socket capability shape and frame limits.
`ServerTerminalRelayTests` rejects regular files, symlinks and unrelated socket paths while
accepting an owned terminal socket. These tests do not claim that the current production connect
executable has already been upgraded.

Linux child launch also resets the spawning thread's signal mask through the shared
`ProcessLaunch` boundary used by streaming processes, shell commands and Git. The caller's mask
is restored synchronously after launch, including failures. Without this, Swift worker-thread
masks can reach tmux and its shell, so Ctrl-C appears on screen but cannot interrupt the process.
`ProcessLaunchTests` exercises child and caller masks on Linux.

The opt-in iOS `--bloom-live-terminal` integration check uses the production native controller and
transport. It creates one uniquely named terminal, checks output, input, PTY dimensions, Ctrl-C,
and retained shell state after disconnect/reconnect, captures its actual view, then explicitly
ends only that test shell. It requires the public live-connection configuration documented in
`IOS.md`; no credentials or fixture output are compiled into it.
