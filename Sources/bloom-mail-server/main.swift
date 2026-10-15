import Darwin
import Foundation

// The app keeps our stdin pipe open. If it quits or crashes, EOF stops the SMTP server, so a
// leftover process cannot claim its ports and database on the next launch. Mailpit must not
// inherit that pipe itself, or its own copy of the write end would keep the read open forever.
guard CommandLine.arguments.count == 6 else { Darwin.exit(2) }

let arguments = CommandLine.arguments
let logURL = URL(fileURLWithPath: arguments[5])
if !FileManager.default.fileExists(atPath: logURL.path) {
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
}
guard let log = try? FileHandle(forWritingTo: logURL) else { Darwin.exit(2) }
_ = try? log.seekToEnd()

let mailpit = Process()
mailpit.executableURL = URL(fileURLWithPath: arguments[1])
mailpit.arguments = [
    "--database", arguments[2],
    "--smtp", "127.0.0.1:\(arguments[3])",
    "--listen", "127.0.0.1:\(arguments[4])",
    "--allowed-hosts", "localhost,127.0.0.1",
    "--disable-version-check",
]
mailpit.standardInput = FileHandle.nullDevice
mailpit.standardOutput = log
mailpit.standardError = log
mailpit.terminationHandler = { process in
    Darwin._exit(process.terminationStatus == 0 ? 0 : 1)
}

do {
    try mailpit.run()
} catch {
    let message = "Could not launch bundled mail server: \(error)\n"
    try? log.write(contentsOf: Data(message.utf8))
    Darwin.exit(1)
}

var byte: UInt8 = 0
while true {
    let count = Darwin.read(STDIN_FILENO, &byte, 1)
    if count == 0 { break }
    if count < 0 && errno != EINTR { break }
}
if mailpit.isRunning { mailpit.terminate() }
mailpit.waitUntilExit()
