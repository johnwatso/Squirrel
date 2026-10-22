import Foundation
import Network
import SquirrelCore
import os

/// Drives `NUTDiscovery` for the UI: one scan at a time, results in a stable
/// order, and a plain reason when a scan finds nothing.
@MainActor
final class NUTDiscoveryService: ObservableObject {
    enum State: Equatable {
        case idle
        /// `fraction` is 0...1, so the UI can show real progress rather than
        /// an indeterminate spinner that never ends.
        case scanning(fraction: Double)
        case finished
        /// Discovery could not run at all — no usable network, or macOS
        /// refusing local network access.
        case unavailable(String)

        var isScanning: Bool {
            if case .scanning = self { return true }
            return false
        }
    }

    @Published private(set) var servers: [DiscoveredNUTServer] = []
    @Published private(set) var state: State = .idle
    /// Set when macOS has denied Squirrel local network access, which makes
    /// every probe fail silently and looks exactly like an empty network.
    @Published private(set) var localNetworkDenied = false

    private let log = Logger(subsystem: "io.github.johnwatso.Squirrel", category: "Discovery")
    private var scanTask: Task<Void, Never>?
    private var authorizationBrowser: NWBrowser?
    private let browserQueue = DispatchQueue(label: "io.github.johnwatso.Squirrel.discovery-authorization")

    var hasResults: Bool { !servers.isEmpty }

    func start(port: UInt16 = NUTProtocol.defaultPort) {
        guard scanTask == nil else { return }
        servers = []
        checkLocalNetworkAuthorization()

        guard !NUTDiscovery.localSubnets().isEmpty else {
            state = .unavailable("This Mac isn't on a network Squirrel can search.")
            return
        }

        state = .scanning(fraction: 0)
        scanTask = Task { [weak self] in
            for await event in NUTDiscovery.scan(port: port) {
                guard let self else { return }
                switch event {
                case .found(let server):
                    self.insert(server)
                case .progress(let completed, let total):
                    guard total > 0 else { continue }
                    self.state = .scanning(fraction: Double(completed) / Double(total))
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.state = .finished
            self.scanTask = nil
            self.log.notice("Discovery finished with \(self.servers.count, privacy: .public) server(s)")
        }
    }

    func restart(port: UInt16 = NUTProtocol.defaultPort) {
        stop()
        start(port: port)
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        authorizationBrowser?.cancel()
        authorizationBrowser = nil
        if state.isScanning { state = .idle }
    }

    /// Keeps the list sorted by address so rows do not jump around as replies
    /// arrive out of order.
    private func insert(_ server: DiscoveredNUTServer) {
        guard !servers.contains(where: { $0.id == server.id }) else { return }
        servers.append(server)
        servers.sort { $0.host.compare($1.host, options: .numeric) == .orderedAscending }
    }

    /// Browsing a Bonjour service is the public mechanism macOS uses to
    /// evaluate local network access. NUT does not advertise itself, so a
    /// result is never expected here — but a policy-denied DNS-SD error is a
    /// definite answer that the switch in System Settings is off.
    private func checkLocalNetworkAuthorization() {
        guard authorizationBrowser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_nut._tcp", domain: nil), using: .tcp)
        authorizationBrowser = browser

        browser.stateUpdateHandler = { [weak self] state in
            guard case let .waiting(error) = state, case let .dns(code) = error, code == -65_570 else { return }
            Task { @MainActor [weak self] in
                self?.localNetworkDenied = true
                self?.authorizationBrowser?.cancel()
                self?.authorizationBrowser = nil
            }
        }
        browser.start(queue: browserQueue)
    }
}
