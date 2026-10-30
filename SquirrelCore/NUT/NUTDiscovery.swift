import Foundation
import Network

/// A NUT server found on the local network.
public struct DiscoveredNUTServer: Identifiable, Sendable, Equatable, Hashable {
    /// The literal IPv4 address that answered.
    public let host: String
    public let port: UInt16
    /// Reverse-DNS name, when the network supplies one. Never invented.
    public let hostName: String?
    /// The UPS names this server serves, from `LIST UPS`. Empty when the
    /// server refused to answer without credentials.
    public let upsNames: [String]
    /// The `LIST UPS` description for each UPS, where the server set one.
    /// Often the only clue to what kind of server this is.
    public let upsDescriptions: [String: String]
    /// What each UPS reports as its maker and model, where the server lets a
    /// stranger read them. Enough to draw the right UPS before connecting.
    public let upsManufacturers: [String: String]
    public let upsModels: [String: String]
    /// Each UPS's `ups.status` at the moment it was found, e.g. "OL".
    public let upsStatuses: [String: String]
    /// The server spoke NUT but would not list its devices unauthenticated.
    public let requiresAuthentication: Bool
    /// The server answered `ACCESS-DENIED`: it is refusing this Mac by
    /// address, which no username fixes. NAS UPS servers (Synology, QNAP)
    /// answer this way to any client not on their permitted list.
    public let deniedAccess: Bool

    public var id: String { "\(host):\(port)" }

    /// What to show as the row title: the real host name if the network knows
    /// one, otherwise the address itself.
    public var displayName: String { hostName ?? host }

    public var address: String { "\(host):\(port)" }

    public init(
        host: String,
        port: UInt16,
        hostName: String? = nil,
        upsNames: [String] = [],
        upsDescriptions: [String: String] = [:],
        upsManufacturers: [String: String] = [:],
        upsModels: [String: String] = [:],
        upsStatuses: [String: String] = [:],
        requiresAuthentication: Bool = false,
        deniedAccess: Bool = false
    ) {
        self.host = host
        self.port = port
        self.hostName = hostName
        self.upsNames = upsNames
        self.upsDescriptions = upsDescriptions
        self.upsManufacturers = upsManufacturers
        self.upsModels = upsModels
        self.upsStatuses = upsStatuses
        self.requiresAuthentication = requiresAuthentication
        self.deniedAccess = deniedAccess
    }
}

/// What a scan reports as it runs.
public enum NUTDiscoveryEvent: Sendable {
    case progress(completed: Int, total: Int)
    case found(DiscoveredNUTServer)
}

/// Finds NUT servers by probing the Mac's own IPv4 subnets on the NUT port.
///
/// NUT has no Bonjour service to browse, so discovery is a bounded sweep of
/// the networks this Mac is actually attached to — the addresses come from
/// `getifaddrs`, never from a guess about what the user's router is numbered.
/// A host only counts as found once it has answered `LIST UPS` in NUT's own
/// protocol, so an unrelated service listening on 3493 is not reported as a UPS.
public enum NUTDiscovery {
    /// One IPv4 network this Mac is attached to.
    public struct LocalSubnet: Sendable, Equatable {
        public let address: UInt32
        public let prefixLength: Int

        public init(address: UInt32, prefixLength: Int) {
            self.address = address
            self.prefixLength = prefixLength
        }

        public func contains(_ other: UInt32) -> Bool {
            guard prefixLength > 0 else { return true }
            let mask = UInt32.max << (32 - min(prefixLength, 32))
            return address & mask == other & mask
        }

        /// The addresses worth probing, excluding this Mac, the network
        /// address and the broadcast address.
        ///
        /// Wide networks are clamped to the /24 containing this Mac: sweeping
        /// a /16 is 65,000 connections, which is a port scan, not discovery.
        public func candidateAddresses(maximumHosts: Int) -> [UInt32] {
            let effectivePrefix = max(prefixLength, 32 - Int(log2(Double(maximumHosts))))
            guard effectivePrefix < 31 else { return [] }
            let mask = effectivePrefix == 0 ? 0 : UInt32.max << (32 - effectivePrefix)
            let base = address & mask
            let count = UInt32(1) << (32 - effectivePrefix)
            return ((base + 1)..<(base + count - 1)).filter { $0 != address }
        }
    }

    /// Scans every local IPv4 subnet for NUT servers.
    ///
    /// - Parameters:
    ///   - port: the TCP port to probe. 3493 unless the user says otherwise.
    ///   - timeout: how long a single host gets to complete a TCP handshake.
    ///   - maximumConcurrentProbes: how many sockets are in flight at once.
    ///   - maximumHostsPerSubnet: the clamp that keeps a wide netmask from
    ///     turning discovery into a sweep of tens of thousands of addresses.
    public static func scan(
        port: UInt16 = NUTProtocol.defaultPort,
        timeout: TimeInterval = 2,
        maximumConcurrentProbes: Int = 48,
        maximumHostsPerSubnet: Int = 256
    ) -> AsyncStream<NUTDiscoveryEvent> {
        let candidates = candidateHosts(maximumHostsPerSubnet: maximumHostsPerSubnet)
        return AsyncStream { continuation in
            let task = Task {
                let total = candidates.count
                guard total > 0 else {
                    continuation.yield(.progress(completed: 0, total: 0))
                    continuation.finish()
                    return
                }

                var completed = 0
                var iterator = candidates.makeIterator()

                await withTaskGroup(of: DiscoveredNUTServer?.self) { group in
                    for _ in 0..<min(maximumConcurrentProbes, total) {
                        guard let next = iterator.next() else { break }
                        group.addTask { await probe(host: next, port: port, timeout: timeout) }
                    }

                    while let result = await group.next() {
                        completed += 1
                        if let result { continuation.yield(.found(result)) }
                        continuation.yield(.progress(completed: completed, total: total))

                        if Task.isCancelled {
                            group.cancelAll()
                            continue
                        }
                        if let next = iterator.next() {
                            group.addTask { await probe(host: next, port: port, timeout: timeout) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Every address worth probing, in a stable order, with duplicates from
    /// overlapping interfaces removed.
    public static func candidateHosts(maximumHostsPerSubnet: Int = 256) -> [String] {
        var seen = Set<UInt32>()
        var hosts: [String] = []
        for subnet in localSubnets() {
            for address in subnet.candidateAddresses(maximumHosts: maximumHostsPerSubnet)
            where seen.insert(address).inserted {
                hosts.append(ipv4String(address))
            }
        }
        return hosts
    }

    /// The IPv4 networks this Mac is attached to right now.
    public static func localSubnets() -> [LocalSubnet] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var subnets: [LocalSubnet] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_POINTOPOINT == 0,
                  let rawAddress = interface.pointee.ifa_addr,
                  rawAddress.pointee.sa_family == sa_family_t(AF_INET),
                  let rawMask = interface.pointee.ifa_netmask
            else { continue }

            let address = ipv4Value(rawAddress)
            let mask = ipv4Value(rawMask)
            // A link-local 169.254/16 address means DHCP never answered; there
            // is nothing on it to find.
            guard address != 0, mask != 0, address >> 16 != 0xA9FE else { continue }

            let subnet = LocalSubnet(address: address, prefixLength: mask.nonzeroBitCount)
            if !subnets.contains(subnet) { subnets.append(subnet) }
        }
        return subnets
    }

    /// This Mac's own IPv4 address on the network that reaches `host`, or
    /// its first address if none of its networks contains it. What a NAS's
    /// "permitted devices" list needs, read rather than guessed.
    public static func localAddress(toward host: String) -> String? {
        let subnets = localSubnets()
        var target = in_addr()
        if inet_pton(AF_INET, host, &target) == 1 {
            let value = UInt32(bigEndian: target.s_addr)
            if let match = subnets.first(where: { $0.contains(value) }) {
                return ipv4String(match.address)
            }
        }
        return subnets.first.map { ipv4String($0.address) }
    }

    // MARK: - Probing

    /// Opens one connection and speaks NUT over it.
    ///
    /// Deliberately not built on `NUTClient`: a sweep needs a hard deadline on
    /// the TCP handshake, which `NUTClient` has no reason to impose, and
    /// opening a socket to test the port and then a second one to talk is two
    /// connections in quick succession — which some UPS servers, serving one
    /// client at a time, simply refuse. One connection, one `LIST UPS`.
    ///
    /// A host is only reported once it has answered in NUT's own protocol, so
    /// an unrelated service listening on the port is never shown as a UPS.
    ///
    /// `includingLoopback` is for tests, which can only run a server locally.
    static func probe(host: String, port: UInt16, timeout: TimeInterval, includingLoopback: Bool = false) async -> DiscoveredNUTServer? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }

        let options = NWProtocolTCP.Options()
        options.connectionTimeout = Int(timeout.rounded(.up))
        options.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: options)
        if !includingLoopback { parameters.prohibitedInterfaceTypes = [.loopback] }

        let session = ProbeSession(
            connection: NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        )
        defer { session.cancel() }

        guard await session.open(timeout: timeout),
              await session.send(NUTProtocol.command("LIST", ["UPS"]) + "\n", timeout: timeout)
        else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        guard let first = await session.readLine(before: deadline) else { return nil }

        if let error = NUTError(errorLine: first) {
            // An error in NUT's own vocabulary still proves this is a NUT
            // server; one that will not list its devices to a stranger is
            // worth offering with a note that it needs a sign-in.
            guard error.isAuthenticationProblem else { return nil }
            let denied = error == .accessDenied
            return DiscoveredNUTServer(
                host: host,
                port: port,
                hostName: reverseDNSName(for: host),
                requiresAuthentication: !denied,
                deniedAccess: denied
            )
        }
        guard first == "BEGIN LIST UPS" else { return nil }

        var names: [String] = []
        var descriptions: [String: String] = [:]
        while let line = await session.readLine(before: deadline) {
            if line == "END LIST UPS" {
                // Still on the one connection: what each UPS says it is.
                var manufacturers: [String: String] = [:]
                var models: [String: String] = [:]
                var statuses: [String: String] = [:]
                for name in names.prefix(4) {
                    var maker = await variable("device.mfr", ups: name, session: session, before: deadline)
                    if maker == nil { maker = await variable("ups.mfr", ups: name, session: session, before: deadline) }
                    manufacturers[name] = maker
                    models[name] = await variable("ups.model", ups: name, session: session, before: deadline)
                    statuses[name] = await variable("ups.status", ups: name, session: session, before: deadline)
                }
                return DiscoveredNUTServer(
                    host: host,
                    port: port,
                    hostName: reverseDNSName(for: host),
                    upsNames: names,
                    upsDescriptions: descriptions,
                    upsManufacturers: manufacturers.compactMapValues { $0 },
                    upsModels: models.compactMapValues { $0 },
                    upsStatuses: statuses.compactMapValues { $0 }
                )
            }
            if NUTError(errorLine: line) != nil { return nil }
            let tokens = NUTProtocol.tokenize(line)
            guard tokens.count >= 2, tokens[0] == "UPS" else { continue }
            names.append(tokens[1])
            // upsd says "Unavailable" when the admin never set one.
            if tokens.count >= 3, tokens[2] != "Unavailable", !tokens[2].isEmpty {
                descriptions[tokens[1]] = tokens[2]
            }
        }
        return nil
    }

    /// One `GET VAR` on the probe's connection. Nil for anything but a value,
    /// including the error a server gives for a variable it doesn't have.
    private static func variable(_ variable: String, ups: String, session: ProbeSession, before deadline: Date) async -> String? {
        guard await session.send(NUTProtocol.command("GET", ["VAR", ups, variable]) + "\n", timeout: deadline.timeIntervalSinceNow),
              let line = await session.readLine(before: deadline)
        else { return nil }
        let tokens = NUTProtocol.tokenize(line)
        guard tokens.count >= 4, tokens[0] == "VAR", !tokens[3].isEmpty else { return nil }
        return tokens[3]
    }

    /// The name the network knows this address by, or nil. Only ever called
    /// for the handful of hosts that actually answered.
    public static func reverseDNSName(for host: String) -> String? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }

        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getnameinfo(
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_in>.size),
                    &name,
                    socklen_t(NI_MAXHOST),
                    nil,
                    0,
                    NI_NAMEREQD
                )
            }
        }
        guard status == 0 else { return nil }

        var resolved = String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        while resolved.hasSuffix(".") { resolved.removeLast() }
        // Bonjour answers with "gateway.local"; the suffix is noise in a list.
        if resolved.lowercased().hasSuffix(".local") { resolved.removeLast(6) }
        return resolved.isEmpty || resolved == host ? nil : resolved
    }

    // MARK: - Address arithmetic

    private static func ipv4Value(_ pointer: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
    }

    public static func ipv4String(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}

/// One connection's worth of NUT conversation, with a deadline on every step.
///
/// `NWConnection`'s callbacks arrive on its own queue, so the buffer is held
/// under a lock rather than by actor isolation.
private final class ProbeSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "io.github.johnwatso.Squirrel.discovery-probe")
    private let lock = NSLock()
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// `.waiting` counts as a failure: on a local subnet it means refused or
    /// unreachable, and waiting out the system's own retry schedule would make
    /// a sweep take minutes.
    func open(timeout: TimeInterval) async -> Bool {
        await race(timeout: timeout) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let once = DiscoveryOneShot()
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.fire { continuation.resume(returning: true) }
                    case .failed, .cancelled, .waiting:
                        once.fire { continuation.resume(returning: false) }
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        } ?? false
    }

    func send(_ command: String, timeout: TimeInterval) async -> Bool {
        await race(timeout: timeout) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let once = DiscoveryOneShot()
                self.connection.send(content: Data(command.utf8), completion: .contentProcessed { error in
                    once.fire { continuation.resume(returning: error == nil) }
                })
            }
        } ?? false
    }

    func readLine(before deadline: Date) async -> String? {
        while true {
            if let line = bufferedLine() { return line }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            let received = await race(timeout: remaining) { await self.receive() } ?? nil
            guard let data = received, !data.isEmpty else { return nil }
            append(data)
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
    }

    private func bufferedLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = buffer.firstIndex(of: 0x0A) else { return nil }
        let lineData = buffer[buffer.startIndex..<index]
        buffer.removeSubrange(buffer.startIndex...index)
        var line = String(decoding: lineData, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }

    private func receive() async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let once = DiscoveryOneShot()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
                once.fire { continuation.resume(returning: error == nil ? data : nil) }
            }
        }
    }

    /// Runs `work`, giving up and returning nil once `timeout` has passed.
    ///
    /// A task group only returns once every child has, and a callback waiting
    /// on the connection does not stop for cancellation. So on timeout the
    /// connection itself is cancelled, which makes its pending send or receive
    /// complete; without that a silent server held the probe, and the sweep,
    /// forever. A timed-out session is finished either way.
    private func race<Value: Sendable>(
        timeout: TimeInterval,
        work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await work() }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                } catch {
                    return nil
                }
                self.connection.cancel()
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

/// Guards a continuation several `NWConnection` callbacks could reach.
private final class DiscoveryOneShot: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func fire(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
