import Foundation
import ServiceManagement
import os

/// Whether Squirrel starts with the Mac.
///
/// Load-bearing rather than a convenience: the published power source dies
/// with the process, so a Squirrel that does not start at login leaves macOS
/// with no UPS at all. `SMAppService` is the source of truth — the answer is
/// read back from the system rather than remembered in preferences, so the
/// switch can never claim something macOS disagrees with.
@MainActor
final class LoginItemService: ObservableObject {
    @Published private(set) var isEnabled = false
    /// macOS has the login item but the user has not approved it yet, which
    /// they can only do in System Settings.
    @Published private(set) var requiresApproval = false
    @Published private(set) var lastError: String?

    private let log = Logger(subsystem: "io.github.johnwatso.Squirrel", category: "LoginItem")

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            log.error("Could not change the login item: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}
