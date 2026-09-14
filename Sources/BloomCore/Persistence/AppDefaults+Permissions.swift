import Foundation

/// Each provider has its own settings row. Unconfigured providers inherit the older global choice.
extension AppDefaults {
    public static func permissionModeKey(for backend: AgentKind) -> String {
        Key.permissionMode + "." + backend.rawValue
    }

    public func permissionMode(for backend: AgentKind) -> PermissionMode {
        (providerPermissionModes[backend] ?? permissionMode).nearest(on: backend)
    }

    public mutating func setPermissionMode(_ mode: PermissionMode?, for backend: AgentKind) {
        providerPermissionModes[backend] = mode?.nearest(on: backend)
    }
}
