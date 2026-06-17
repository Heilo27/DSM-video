import Foundation

/// Single source of truth for the consumer-facing app name.
///
/// NOTE: This is the *client app* name shown to users ("DSM Video"). It is
/// intentionally distinct from the server package name "DSVideoServer", which
/// is a separate product and must not be changed.
enum AppInfo {
    static let displayName = "DSM Video"
}
