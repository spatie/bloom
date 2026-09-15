import Foundation

public typealias RemoteTerminalKey = TerminalKey

public extension TerminalKey {
    var data: Data { Data(bytes) }
}
