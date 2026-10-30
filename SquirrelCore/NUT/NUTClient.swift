import Foundation
import Network

/// A client for one upsd server.
///
/// Deliberately small: NUT is a line protocol, so this is `Network.framework`
/// plus a line buffer, with no third-party dependency.
public actor NUTClient {
    public struct Configuration: Sendable, Equatable {
        public var host: String
        public var port: UInt16
        public var username: String?
        public var password: String?
        /// Upgrade with `STARTTLS` immediately after connecting.
        public var useTLS: Bool
        public var timeout: TimeInterval

        public init(
            host: String,
            port: UInt16 = NUTProtocol.defaultPort,
            username: String? = nil,
            password: String? = nil,
            useTLS: Bool = false,
            timeout: TimeInterval = 10
        ) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.useTLS = useTLS
            self.timeout = timeout
        }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.squirrel.nut-client")
    private var connection: NWConnection?
    private var buffer = Data()

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var isConnected: Bool { connection != nil }

    // MARK: - Connection

    public func connect() async throws {
        if connection != nil { return }

        let endpoint = NWEndpoint.Host(configuration.host)
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw NUTError.connectionFailed("Invalid port \(configuration.port)")
        }
        let connection = NWConnection(host: endpoint, port: port, using: .tcp)
        self.connection = connection

        do {
            let timeout = configuration.timeout
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = OneShot()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resumed.resume { continuation.resume() }
                    case .failed(let error):
                        resumed.resume { continuation.resume(throwing: NUTError.connectionFailed(Self.describe(error))) }
                    case .waiting(let error):
                        // Network.framework parks a refused or unreachable
                        // connection here and retries when the network changes,
                        // so connect() would never return. Callers want the
                        // answer now; the monitor does its own retrying.
                        resumed.resume { continuation.resume(throwing: NUTError.connectionFailed(Self.describe(error))) }
                    case .cancelled:
                        resumed.resume { continuation.resume(throwing: NUTError.notConnected) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                // A server that never answers at all still gets an answer.
                queue.asyncAfter(deadline: .now() + timeout) {
                    resumed.resume { continuation.resume(throwing: NUTError.timedOut) }
                }
            }
        } catch {
            self.connection = nil
            connection.cancel()
            throw error
        }

        if configuration.useTLS {
            // STARTTLS needs the socket handed to a TLS stack mid-stream, which
            // NWConnection does not support after .ready. Tracked separately;
            // refuse rather than silently sending credentials in the clear.
            throw NUTError.featureNotSupported
        }

        if let username = configuration.username, !username.isEmpty {
            _ = try await sendExpectingOK(NUTProtocol.command("USERNAME", [username]))
        }
        if let password = configuration.password, !password.isEmpty {
            _ = try await sendExpectingOK(NUTProtocol.command("PASSWORD", [password]))
        }
    }

    public func disconnect() async {
        guard let connection else { return }
        if let line = try? await send(NUTProtocol.command("LOGOUT")), !line.isEmpty {
            // upsd answers "OK Goodbye"; nothing to do with it.
        }
        connection.cancel()
        self.connection = nil
        buffer.removeAll()
    }

    /// Immediately discard a failed or cancelled transport. Do not send LOGOUT
    /// to a dead socket or wait for an unresponsive server to acknowledge it.
    public func abort() {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    // MARK: - Queries

    /// `LIST UPS` — the names upsd actually serves. Onboarding enumerates with
    /// this instead of asking the user to guess the UniFi controller's NUT ID.
    public func listUPS() async throws -> [NUTDevice] {
        let lines = try await sendExpectingList(NUTProtocol.command("LIST", ["UPS"]), query: "UPS")
        return lines.compactMap { line in
            let tokens = NUTProtocol.tokenize(line)
            guard tokens.count >= 2, tokens[0] == "UPS" else { return nil }
            return NUTDevice(name: tokens[1], description: tokens.count >= 3 ? tokens[2] : "Unavailable")
        }
    }

    public func listVariables(ups: String) async throws -> [String: String] {
        let lines = try await sendExpectingList(
            NUTProtocol.command("LIST", ["VAR", ups]), query: "VAR \(ups)"
        )
        var variables: [String: String] = [:]
        for line in lines {
            let tokens = NUTProtocol.tokenize(line)
            guard tokens.count >= 4, tokens[0] == "VAR" else { continue }
            variables[tokens[2]] = tokens[3]
        }
        return variables
    }

    public func listCommands(ups: String) async throws -> [String] {
        let lines = try await sendExpectingList(
            NUTProtocol.command("LIST", ["CMD", ups]), query: "CMD \(ups)"
        )
        return lines.compactMap { line in
            let tokens = NUTProtocol.tokenize(line)
            guard tokens.count >= 3, tokens[0] == "CMD" else { return nil }
            return tokens[2]
        }
    }

    public func variable(_ name: String, ups: String) async throws -> String {
        let line = try await send(NUTProtocol.command("GET", ["VAR", ups, name]))
        if let error = NUTError(errorLine: line) { throw error }
        let tokens = NUTProtocol.tokenize(line)
        guard tokens.count >= 4, tokens[0] == "VAR" else {
            throw NUTError.malformedResponse(line)
        }
        return tokens[3]
    }

    /// A full reading in one round trip.
    public func reading(ups: String) async throws -> UPSReading {
        let variables = try await listVariables(ups: ups)
        guard !variables.isEmpty else { throw NUTError.dataStale }
        return UPSReading(upsName: ups, variables: variables)
    }

    public func protocolVersion() async throws -> String {
        try await send(NUTProtocol.command("NETVER"))
    }

    // MARK: - Actions

    public func instantCommand(_ name: String, ups: String) async throws {
        _ = try await sendExpectingOK(NUTProtocol.command("INSTCMD", [ups, name]))
    }

    /// Registers this Mac as drawing power from the UPS. Needs an `upsmon`
    /// role in `upsd.users`.
    public func login(ups: String) async throws {
        _ = try await sendExpectingOK(NUTProtocol.command("LOGIN", [ups]))
    }

    // MARK: - Transport

    private func sendExpectingOK(_ command: String) async throws -> String {
        let line = try await send(command)
        if let error = NUTError(errorLine: line) { throw error }
        guard line.hasPrefix("OK") else { throw NUTError.malformedResponse(line) }
        return line
    }

    private func sendExpectingList(_ command: String, query: String) async throws -> [String] {
        try await write(command)
        var lines: [String] = []
        let begin = "BEGIN LIST \(query)"
        let end = "END LIST \(query)"

        let first = try await readLine()
        if let error = NUTError(errorLine: first) { throw error }
        guard first == begin else { throw NUTError.malformedResponse(first) }

        while true {
            let line = try await readLine()
            if line == end { return lines }
            if let error = NUTError(errorLine: line) { throw error }
            lines.append(line)
        }
    }

    private func send(_ command: String) async throws -> String {
        try await write(command)
        return try await readLine()
    }

    private func write(_ command: String) async throws {
        guard let connection else { throw NUTError.notConnected }
        let data = Data((command + "\n").utf8)
        try await withTransportDeadline(on: connection) { (finish: @escaping (Result<Void, Error>) -> Void) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    finish(.failure(NUTError.connectionFailed(Self.describe(error))))
                } else {
                    finish(.success(()))
                }
            })
        }
    }

    /// Runs one send or receive with the configured timeout. A server that
    /// accepts the socket and then goes silent never completes either call,
    /// and without this the monitor's poll loop would wait on it forever
    /// instead of retrying. On any transport failure the socket is discarded,
    /// so the next connect() opens a fresh one rather than reusing a dead one.
    private func withTransportDeadline<T: Sendable>(
        on connection: NWConnection,
        _ operation: @escaping (@escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let timeout = configuration.timeout
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let resumed = OneShot()
                operation { result in resumed.resume { continuation.resume(with: result) } }
                queue.asyncAfter(deadline: .now() + timeout) {
                    resumed.resume {
                        connection.cancel()
                        continuation.resume(throwing: NUTError.timedOut)
                    }
                }
            }
        } catch {
            if self.connection === connection { abort() }
            throw error
        }
    }

    /// Plain words for the network failures a person can act on. `NWError`'s
    /// own description is written for a crash log, not for someone trying to
    /// work out why their UPS will not connect.
    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(.ECONNREFUSED):
            return "the server refused the connection"
        case .posix(.ETIMEDOUT):
            return "the server did not respond"
        case .posix(.EHOSTUNREACH), .posix(.ENETUNREACH), .posix(.EHOSTDOWN), .posix(.ENETDOWN):
            return "the server could not be reached"
        case .posix(.ENOTCONN), .posix(.ECONNRESET), .posix(.EPIPE):
            return "the server closed the connection"
        case .dns:
            return "that address could not be looked up"
        default:
            return error.localizedDescription
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                var line = String(decoding: lineData, as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                return line
            }
            buffer.append(try await receive())
        }
    }

    private func receive() async throws -> Data {
        guard let connection else { throw NUTError.notConnected }
        return try await withTransportDeadline(on: connection) { (finish: @escaping (Result<Data, Error>) -> Void) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    finish(.failure(NUTError.connectionFailed(Self.describe(error))))
                } else if let data, !data.isEmpty {
                    finish(.success(data))
                } else if isComplete {
                    finish(.failure(NUTError.notConnected))
                } else {
                    finish(.success(Data()))
                }
            }
        }
    }
}

/// Guards a continuation that several callbacks could reach.
private final class OneShot: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func resume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
