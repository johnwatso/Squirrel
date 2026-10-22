import Foundation
import SquirrelCore

/// Local automation for Squirrel. Talks only to the running app through macOS
/// distributed notifications; it opens no network port and needs no privileges.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReply: String?
    private var storedSuccess = false

    func store(reply: String, success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard storedReply == nil else { return }
        storedReply = reply
        storedSuccess = success
    }

    var result: (reply: String, success: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard let storedReply else { return nil }
        return (storedReply, storedSuccess)
    }
}

enum Squirrelctl {
    static let timeout: TimeInterval = 5

    static var usage: String {
        var lines = ["usage: squirrelctl <command>", ""]
        for command in SquirrelCommand.allCases {
            lines.append("  \(command.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))\(command.summary)")
        }
        lines.append("  help      Show this message")
        return lines.joined(separator: "\n")
    }

    static func run(arguments: [String]) -> Int32 {
        guard let first = arguments.first else {
            print(usage)
            return 64
        }
        if ["help", "--help", "-h"].contains(first) {
            print(usage)
            return 0
        }
        guard let command = SquirrelCommand(rawValue: first) else {
            FileHandle.standardError.write(Data("squirrelctl: unknown command \(first)\n".utf8))
            print(usage)
            return 64
        }
        guard arguments.count == 1 else {
            FileHandle.standardError.write(Data("squirrelctl: \(command.rawValue) takes no arguments\n".utf8))
            return 64
        }
        return send(command)
    }

    private static func send(_ command: SquirrelCommand) -> Int32 {
        let center = DistributedNotificationCenter.default()
        let responseID = UUID().uuidString
        let box = ReplyBox()

        let observer = center.addObserver(
            forName: SquirrelCommandChannel.responseName(for: responseID),
            object: nil,
            queue: .main
        ) { notification in
            let info = notification.userInfo as? [String: String] ?? [:]
            box.store(
                reply: info[SquirrelCommandChannel.replyKey] ?? "",
                success: info[SquirrelCommandChannel.successKey] == "1"
            )
        }
        defer { center.removeObserver(observer) }

        center.postNotificationName(
            SquirrelCommandChannel.requestName,
            object: nil,
            userInfo: [
                SquirrelCommandChannel.commandKey: command.rawValue,
                SquirrelCommandChannel.responseIDKey: responseID,
            ],
            deliverImmediately: true
        )

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = box.result {
                if result.success {
                    print(result.reply)
                    return 0
                }
                FileHandle.standardError.write(Data("squirrelctl: \(result.reply)\n".utf8))
                return 1
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        FileHandle.standardError.write(Data("squirrelctl: Squirrel is not running, or did not answer in time.\n".utf8))
        return 69
    }
}

exit(Squirrelctl.run(arguments: Array(CommandLine.arguments.dropFirst())))
