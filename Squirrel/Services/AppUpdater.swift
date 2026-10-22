import AppKit
import Sparkle
import SwiftUI

/// Sparkle owns checking, downloading and its native update UI. Like SwiftMiner,
/// Squirrel starts it only when its own appcast and signing key are configured.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var startupError: String?
    let isConfigured: Bool

    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    private var observation: NSKeyValueObservation?
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        isConfigured = Self.isValidConfiguration(
            feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
        super.init()
    }

    static func isValidConfiguration(feed: String?, publicKey: String?) -> Bool {
        guard let feed, let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              let publicKey, let key = Data(base64Encoded: publicKey), key.count == 32 else { return false }
        return true
    }

    func start() {
        guard isConfigured, updater == nil else { return }
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
        userDriver = driver
        self.updater = updater
        do {
            try updater.start()
            observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.canCheckForUpdates = self.updater?.canCheckForUpdates ?? false
                }
            }
        } catch {
            startupError = error.localizedDescription
            self.updater = nil
            userDriver = nil
        }
    }

    func checkForUpdates() {
        guard let updater else {
            let alert = NSAlert()
            alert.messageText = "Updates Unavailable"
            alert.informativeText = startupError ?? "This development build does not have a Squirrel update feed and signing key configured yet. Updates will be available when releases are published."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        updater.checkForUpdates()
    }
}

/// Observe the updater directly so a native menu follows Sparkle's readiness.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(updater.isConfigured && updater.startupError == nil && !updater.canCheckForUpdates)
    }
}
