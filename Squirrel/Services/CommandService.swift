import Foundation
import SquirrelCore

/// Answers `squirrelctl` over distributed notifications.
///
/// Deliberately routed through `SquirrelIntentBridge`, so the shell and the
/// App Intents surface give the same answers from the same code.
enum CommandService {
    static func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: SquirrelCommandChannel.requestName,
            object: nil,
            queue: .main
        ) { notification in
            guard let info = notification.userInfo as? [String: String],
                  let rawCommand = info[SquirrelCommandChannel.commandKey],
                  let responseID = info[SquirrelCommandChannel.responseIDKey]
            else { return }
            Task { @MainActor in
                let (reply, ok) = await perform(rawCommand)
                DistributedNotificationCenter.default().postNotificationName(
                    SquirrelCommandChannel.responseName(for: responseID),
                    object: nil,
                    userInfo: [
                        SquirrelCommandChannel.replyKey: reply,
                        SquirrelCommandChannel.successKey: ok ? "1" : "0",
                    ],
                    deliverImmediately: true
                )
            }
        }
    }

    @MainActor
    private static func perform(_ rawCommand: String) async -> (reply: String, ok: Bool) {
        guard let command = SquirrelCommand(rawValue: rawCommand) else {
            return ("Unknown command \(rawCommand)", false)
        }
        do {
            switch command {
            case .status:
                return (try SquirrelIntentBridge.statusSummary(), true)
            case .system:
                return (SquirrelIntentBridge.systemPowerSourceSummary(), true)
            case .pause:
                return (try await SquirrelIntentBridge.pause(), true)
            case .resume:
                return (try SquirrelIntentBridge.resume(), true)
            case .refresh:
                return (try SquirrelIntentBridge.refresh(), true)
            case .version:
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                return ("Squirrel \(version)", true)
            }
        } catch {
            return (error.localizedDescription, false)
        }
    }
}
