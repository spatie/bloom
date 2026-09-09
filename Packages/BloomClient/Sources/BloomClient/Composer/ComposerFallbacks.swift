import Foundation

/// Default values have one owner, including host settings and clients without a loaded session.
public enum ComposerFallbacks {
    public static let model = "opus"
    public static let effort = "high"
    public static let permissionMode = PermissionMode.bypassPermissions
}
