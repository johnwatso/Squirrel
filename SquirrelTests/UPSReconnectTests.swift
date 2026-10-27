import Network
import XCTest
import SquirrelCore
@testable import Squirrel

final class UPSReconnectTests: XCTestCase {
    /// A refused connection used to sit in Network.framework's waiting state,
    /// so connect() never returned and the setup assistant spun forever.
    func testConnectingWhereNothingListensFailsPromptly() async throws {
        let server = try DroppingNUTServer()
        let port = try await server.start()
        server.stop()  // The port is now known to be closed.
        let client = NUTClient(configuration: .init(host: "127.0.0.1", port: port, timeout: 3))
        let started = Date()
        do {
            try await client.connect()
            XCTFail("Connecting to a closed port must fail")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 2, "A refusal should fail at once, not wait for the timeout")
        }
    }

    @MainActor
    func testMonitorOpensFreshSocketAfterServerDropsConnection() async throws {
        let server = try DroppingNUTServer()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "SquirrelTests.Reconnect.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, credentialStore: NoCredentials())
        settings.preferences.publishPowerSource = false
        settings.preferences.showNotifications = false
        settings.preferences.preventSleepDuringOutage = false
        let device = UPSDevice(displayName: "Reconnect fixture", host: "127.0.0.1", port: port, upsName: "rack", publishesToSystem: false, pollInterval: 0.05)
        settings.upsert(device)
        let monitor = UPSMonitor(settings: settings, publisher: PowerSourcePublisher(), sleepAssertion: SleepAssertionService(), notifications: NotificationService(settings: settings), history: PowerHistory(inMemory: true))
        monitor.start()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, monitor.state(for: device).reading?.batteryCharge != 42 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let recovered = monitor.state(for: device).reading
        await monitor.pause()
        XCTAssertEqual(recovered?.batteryCharge, 42, "The second TCP connection must supply the recovered reading")
    }
}

private struct NoCredentials: CredentialStoring {
    func password(forAccount account: String) -> String? { nil }
    func setPassword(_ password: String?, forAccount account: String) {}
}

/// All mutable fixture state is confined to queue. The first socket supplies
/// one reading, then closes; later sockets supply a distinct recovered value.
private final class DroppingNUTServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "SquirrelTests.NUTReconnect")
    private var deliveredStart = false
    private var peers: [Peer] = []

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                guard !deliveredStart else { return }
                switch state {
                case .ready:
                    deliveredStart = true
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    deliveredStart = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                let peer = Peer(connection: connection, queue: queue, drops: peers.isEmpty)
                peers.append(peer)
                peer.start()
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            for peer in peers { peer.connection.cancel() }
            listener.cancel()
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            peers.removeAll()
        }
    }

    private final class Peer: @unchecked Sendable {
        let connection: NWConnection
        let queue: DispatchQueue
        let drops: Bool
        var buffer = ""
        var readings = 0
        init(connection: NWConnection, queue: DispatchQueue, drops: Bool) {
            self.connection = connection
            self.queue = queue
            self.drops = drops
        }
        func start() { connection.start(queue: queue); receive() }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
                guard error == nil, !complete, let data else { return }
                buffer += String(decoding: data, as: UTF8.self)
                while let end = buffer.firstIndex(of: "\n") {
                    let command = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    buffer.removeSubrange(...end)
                    if command == "LIST VAR rack", drops, readings > 0 {
                        connection.cancel()
                        return
                    }
                    let reply: String
                    if command == "LIST VAR rack" {
                        readings += 1
                        reply = "BEGIN LIST VAR rack\nVAR rack ups.status \"OL\"\nVAR rack battery.charge \"\(drops ? 100 : 42)\"\nEND LIST VAR rack\n"
                    } else if command == "LIST CMD rack" {
                        reply = "BEGIN LIST CMD rack\nEND LIST CMD rack\n"
                    } else {
                        reply = "OK\n"
                    }
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
                }
                receive()
            }
        }
    }
}
