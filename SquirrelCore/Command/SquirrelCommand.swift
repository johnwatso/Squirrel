import Foundation

/// The vocabulary shared by the app and `squirrelctl`.
///
/// Kept in SquirrelCore so the two sides cannot drift: a renamed string here
/// is a compile error there, rather than a CLI that quietly times out.
public enum SquirrelCommand: String, CaseIterable, Sendable {
    case status
    case system
    case pause
    case resume
    case refresh
    case version

    public var summary: String {
        switch self {
        case .status:  return "Show the monitored UPS and its current reading"
        case .system:  return "Show what macOS itself reports about the power source"
        case .pause:   return "Pause monitoring and remove the UPS from macOS"
        case .resume:  return "Resume monitoring"
        case .refresh: return "Poll the UPS now"
        case .version: return "Show the running app's version"
        }
    }
}

/// `squirrelctl` talks to the running app over distributed notifications. It
/// opens no network port and needs no privileges.
public enum SquirrelCommandChannel {
    public static let requestName = Notification.Name("io.github.johnwatso.Squirrel.command")
    public static let responsePrefix = "io.github.johnwatso.Squirrel.command-response."
    public static let appBundleIdentifier = "io.github.johnwatso.Squirrel"

    public static let commandKey = "command"
    public static let responseIDKey = "responseID"
    public static let replyKey = "reply"
    public static let successKey = "ok"

    public static func responseName(for responseID: String) -> Notification.Name {
        Notification.Name(responsePrefix + responseID)
    }
}
