import Network
import XCTest
import SquirrelCore
@testable import Squirrel

final class UPSReconnectTests: XCTestCase {
    /// A refused connection used to sit in Network.framework's waiting state,
    /// so connect() never returned and the setup assistant spun forever.
    func testConnectingWhereNothingListensFailsPromptly() async throws {
        let port = try XCTUnwrap(Self.closedLoopbackPort())
        let client = NUTClient(configuration: .init(host: "127.0.0.1", port: port, timeout: 3))
        let started = Date()
        do {
            try await client.connect()
            XCTFail("Connecting to a closed port must fail")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 2, "A refusal should fail at once, not wait for the timeout")
        }
    }

    /// A loopback port nothing listens on: bound to find a free number, then
    /// closed at once. Closing a plain socket is synchronous, unlike stopping
    /// an NWListener, so nothing can still accept on it.
    private static func closedLoopbackPort() -> UInt16? {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(socket, generic, length) == 0 && Darwin.getsockname(socket, generic, &length) == 0
            }
        }
        return bound ? UInt16(bigEndian: address.sin_port) : nil
    }

    /// A server that accepts the socket and then never answers used to leave
    /// reading() waiting forever, which stalled the monitor's poll loop for
    /// good. It must time out, and the next connect must open a fresh socket.
    func testSilentServerTimesOutAndNextConnectionRecovers() async throws {
        let server = try DroppingNUTServer(firstConnection: .silent)
        let port = try await server.start()
        defer { server.stop() }
        let client = NUTClient(configuration: .init(host: "127.0.0.1", port: port, timeout: 1))

        try await client.connect()
        let started = Date()
        do {
            _ = try await client.reading(ups: "rack")
            XCTFail("A server that never answers must not produce a reading")
        } catch {
            XCTAssertEqual(error as? NUTError, .timedOut)
            XCTAssertLessThan(Date().timeIntervalSince(started), 3, "The read should give up at the timeout")
        }
        let stillConnected = await client.isConnected
        XCTAssertFalse(stillConnected, "A timed-out socket must be discarded, not reused")

        try await client.connect()
        let recovered = try await client.reading(ups: "rack")
        XCTAssertEqual(recovered.batteryCharge, 42)
    }

    @MainActor
    func testMonitorOpensFreshSocketAfterServerDropsConnection() async throws {
        let server = try DroppingNUTServer(firstConnection: .dropsAfterOneReading)
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

/// All mutable fixture state is confined to queue. The first socket either
/// supplies one reading and then closes, or never answers at all; later
/// sockets supply a distinct recovered value.
private final class DroppingNUTServer: @unchecked Sendable {
    enum FirstConnection { case dropsAfterOneReading, silent }

    let listener: NWListener
    let firstConnection: FirstConnection
    let queue = DispatchQueue(label: "SquirrelTests.NUTReconnect")
    private var deliveredStart = false
    private var peers: [Peer] = []

    init(firstConnection: FirstConnection) throws {
        self.firstConnection = firstConnection
        listener = try NWListener(using: .tcp, on: .any)
    }

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
                let first = peers.isEmpty
                let peer = Peer(connection: connection, queue: queue,
                                drops: first && firstConnection == .dropsAfterOneReading,
                                silent: first && firstConnection == .silent)
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
        let silent: Bool
        var buffer = ""
        var readings = 0
        init(connection: NWConnection, queue: DispatchQueue, drops: Bool, silent: Bool) {
            self.connection = connection
            self.queue = queue
            self.drops = drops
            self.silent = silent
        }
        func start() { connection.start(queue: queue); receive() }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
                guard error == nil, !complete, let data else { return }
                // Holds the socket open and reads, but never replies.
                if silent { receive(); return }
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
