import AppKit
import Combine
import SquirrelCore

/// Squirrel's status item and its menu, built with AppKit.
///
/// SwiftUI's menu-style MenuBarExtra drops symbol colours, attributed titles
/// and tab stops, and greys out every read-only row. A plain NSMenu keeps
/// native highlighting, separators and key equivalents for the actions, and
/// small item views give the read-only status rows coloured symbols and
/// right-aligned readings. Disabled native items can't do that: AppKit dims
/// them whatever their attributed colours.
///
/// The menu is described as a list of `MenuEntry` values and applied to the
/// NSMenu, updating items in place when only their content has changed, so
/// readings refresh while the menu is open without rebuilding or flicker.
@MainActor
final class MenuBarMenu: NSObject, NSMenuDelegate {
    private let appModel: AppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    private var updateScheduled = false
    private var statusSymbol: String?
    private var isMenuOpen = false

    private var settings: SettingsStore { appModel.settings }
    private var monitor: UPSMonitor { appModel.monitor }

    /// `lifecycleView` stays alive inside the status item, so SwiftUI work
    /// that needs a view (opening windows, first-run setup) has somewhere to run.
    init(appModel: AppModel, lifecycleView: NSView) {
        self.appModel = appModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.autoenablesItems = false
        // A floor, not a fixed width: AppKit can still accommodate longer
        // names, translations and keyboard equivalents.
        menu.minimumWidth = 270
        menu.delegate = self
        statusItem.menu = menu
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            lifecycleView.frame = .zero
            button.addSubview(lifecycleView)
        }

        // objectWillChange fires before the value changes, so the update runs
        // on the next turn of the main queue, which also runs during menu
        // tracking, and several changes in one turn cost one update.
        Publishers.MergeMany(
            appModel.objectWillChange.eraseToAnyPublisher(),
            appModel.settings.objectWillChange.eraseToAnyPublisher(),
            appModel.monitor.objectWillChange.eraseToAnyPublisher(),
            appModel.updater.objectWillChange.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in self?.scheduleUpdate() }
        .store(in: &cancellables)

        updateStatusButton()
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateScheduled = false
            updateStatusButton()
            if isMenuOpen { apply(entries(), to: menu) }
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        apply(entries(), to: menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isMenuOpen = true
        appModel.refreshSystemPowerSource()
        appModel.refreshPowerProfileAdvice()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isMenuOpen = false
    }

    // MARK: - Status item

    /// A template symbol that follows the menu bar's appearance. Warnings
    /// change the symbol's shape (a battery level, a triangle, a slashed
    /// bolt) rather than its colour.
    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let state = appModel.primaryDevice.map { monitor.state(for: $0) } ?? .idle
        let symbol = MenuBarPresentation.symbolName(for: state)
        if statusSymbol != symbol {
            statusSymbol = symbol
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Squirrel")
            image?.isTemplate = true
            button.image = image
        }
        let text = MenuBarPresentation.menuBarText(for: state, display: settings.preferences.menuBarDisplay)
        if let text {
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
        } else if !button.title.isEmpty {
            button.title = ""
        }
        button.setAccessibilityLabel("Squirrel")
        button.setAccessibilityValue(MenuBarPresentation.summary(for: state, isPaused: monitor.isPaused))
    }

    // MARK: - Menu contents

    private func entries() -> [MenuEntry] {
        var entries: [MenuEntry] = []
        let devices = settings.devices

        if let primary = appModel.primaryDevice {
            entries += summary(for: primary, prefix: "primary")
            entries += protectionEntries()
            let others = devices.filter { $0.id != primary.id }
            if !others.isEmpty {
                entries.append(.separator("others"))
                entries += others.map(otherDeviceEntry)
            }
        } else {
            entries.append(.row(id: "empty", .heading("No UPS configured")))
        }

        entries.append(.separator("actions"))
        entries += devices.compactMap(alarmEntry)
        entries.append(.action(id: "add", title: "Add UPS…", symbol: "plus") { [appModel] in
            appModel.beginConnectionAssistant()
        })
        entries.append(.action(id: "open", title: "Open Squirrel", symbol: "macwindow", key: "o") { [appModel] in
            appModel.triggerOpenManageWindow()
        })
        if !devices.isEmpty {
            entries.append(.action(id: "history", title: "Power History", symbol: "clock.arrow.circlepath", key: "y") { [appModel] in
                appModel.showHistory()
            })
        }
        entries.append(.action(id: "energy", title: "Open Energy Settings", symbol: "slider.horizontal.3") {
            Self.openEnergySettings()
        })

        if !devices.isEmpty {
            entries.append(.separator("controls"))
            entries.append(controlsEntry())
        }

        entries.append(.separator("app"))
        entries.append(.action(id: "settings", title: "Settings…", symbol: "gearshape", key: ",") {
            Self.openSettings()
        })
        let updater = appModel.updater
        entries.append(.action(
            id: "updates",
            title: "Check for Updates…",
            symbol: "arrow.triangle.2.circlepath",
            isEnabled: !(updater.isConfigured && updater.startupError == nil && !updater.canCheckForUpdates)
        ) {
            updater.checkForUpdates()
        })
        entries.append(.action(id: "quit", title: "Quit Squirrel", symbol: "power", key: "q") {
            NSApplication.shared.terminate(nil)
        })

        return entries
    }

    /// Name, coloured status and readings: read-only rows at the top.
    private func summary(for device: UPSDevice, prefix: String) -> [MenuEntry] {
        let state = monitor.state(for: device)
        var entries: [MenuEntry] = [
            .row(id: "\(prefix).name", .heading(device.displayName), toolTip: device.displayName),
            .row(id: "\(prefix).status", .status(MenuBarPresentation.powerStatus(for: state, isPaused: monitor.isPaused))),
        ]
        for row in MenuBarPresentation.telemetryRows(for: state) {
            entries.append(.row(id: "\(prefix).\(row.label)", .telemetry(row)))
        }
        if case .failed(let message) = state {
            entries.append(.row(id: "\(prefix).error", .note(message), toolTip: message))
        }
        return entries
    }

    /// Power protection, from the same evaluation as the window. Shown
    /// whenever a UPS is set up, so "Not shared with macOS" is visible too.
    private func protectionEntries() -> [MenuEntry] {
        guard let device = appModel.primaryDevice else { return [] }
        let status = MacProtectionStatus.evaluate(
            device: device,
            integration: appModel.nativeIntegrationState(for: device),
            advice: appModel.powerProfileAdvice,
            preferences: settings.preferences,
            integrationUnavailable: monitor.systemIntegrationUnavailable
        )
        return [.row(id: "protection", .status(MenuBarPresentation.protectionLine(for: status)), toolTip: status.explanation)]
    }

    /// Additional UPSs: name and status, with the details a level down.
    private func otherDeviceEntry(_ device: UPSDevice) -> MenuEntry {
        let status = MenuBarPresentation.powerStatus(for: monitor.state(for: device), isPaused: monitor.isPaused)
        var entry = MenuEntry(id: device.id.uuidString, title: "\(device.displayName) — \(status.title)")
        entry.submenu = summary(for: device, prefix: device.id.uuidString) + [
            .separator("\(device.id).history"),
            .action(id: "\(device.id).history", title: "Power History", symbol: "clock.arrow.circlepath") { [appModel] in
                appModel.showHistory(for: device)
            },
        ]
        return entry
    }

    /// Silencing a sounding alarm is the one command worth finding at once,
    /// so it sits at the top of the actions rather than under Controls.
    private func alarmEntry(for device: UPSDevice) -> MenuEntry? {
        guard let item = MenuBarPresentation.alarmCommand(
            supported: monitor.commands(for: device),
            reading: monitor.state(for: device).reading,
            signedIn: MenuBarPresentation.canRunCommands(on: device)
        ) else { return nil }
        let title = settings.devices.count > 1 ? "\(item.title) on \(device.displayName)" : item.title
        return .action(id: "\(device.id).alarm", title: title, symbol: "speaker.slash.fill", isEnabled: !monitor.isBusy(device)) { [appModel] in
            Task { await appModel.runCommand(item.command, titled: item.title, on: device) }
        }
    }

    /// Occasional actions, kept out of the top level of the menu. UPS
    /// commands stay text-only so they never look like the main actions.
    private func controlsEntry() -> MenuEntry {
        var submenu: [MenuEntry] = [
            .action(id: "refresh", title: "Refresh Now", symbol: "arrow.clockwise") { [appModel] in
                appModel.monitor.restart()
                appModel.refreshPowerProfileAdvice()
            },
        ]
        if monitor.isPaused {
            submenu.append(.action(id: "resume", title: "Resume Monitoring", symbol: "play.circle") { [monitor] in
                monitor.resume()
            })
        } else {
            submenu.append(.action(id: "pause", title: "Pause Monitoring", symbol: "pause.circle") { [monitor] in
                Task { await monitor.pause() }
            })
        }

        for device in settings.devices {
            let offered = MenuBarPresentation.offeredCommands(
                supported: monitor.commands(for: device),
                reading: monitor.state(for: device).reading,
                signedIn: MenuBarPresentation.canRunCommands(on: device)
            )
            guard !offered.isEmpty else { continue }
            submenu.append(.separator("\(device.id).commands"))
            if settings.devices.count > 1 {
                submenu.append(.row(id: "\(device.id).commands.name", .heading(device.displayName)))
            }
            for item in offered {
                submenu.append(.action(id: "\(device.id).\(item.command)", title: item.title, isEnabled: !monitor.isBusy(device)) { [appModel] in
                    Task { await appModel.runCommand(item.command, titled: item.title, on: device) }
                })
            }
        }

        var entry = MenuEntry(id: "controls", title: "Controls", symbol: "power")
        entry.submenu = submenu
        return entry
    }

    // MARK: - Applying

    /// Updates items in place when the menu has the same shape, and rebuilds
    /// it only when items come or go.
    private func apply(_ entries: [MenuEntry], to menu: NSMenu) {
        let sameShape = menu.items.map { $0.identifier?.rawValue } == entries.map(\.id)
        if !sameShape {
            menu.removeAllItems()
            for entry in entries {
                let item = entry.isSeparator ? NSMenuItem.separator() : SymbolMenuItem()
                item.identifier = NSUserInterfaceItemIdentifier(entry.id)
                menu.addItem(item)
            }
        }
        for (item, entry) in zip(menu.items, entries) where !entry.isSeparator {
            configure(item, with: entry)
        }
    }

    private func configure(_ item: NSMenuItem, with entry: MenuEntry) {
        if item.title != entry.title { item.title = entry.title }
        item.toolTip = entry.toolTip
        item.isEnabled = entry.isEnabled
        item.keyEquivalent = entry.keyEquivalent
        item.keyEquivalentModifierMask = entry.keyEquivalent.isEmpty ? [] : .command

        if let row = entry.row {
            let view = item.view as? MenuRowView ?? MenuRowView()
            view.show(row)
            view.toolTip = entry.toolTip
            if item.view !== view { item.view = view }
        } else if item.view != nil {
            item.view = nil
        }

        // Keep AppKit's native image column and highlight treatment. macOS
        // 27 hides symbol images by default unless visibility is requested.
        if let item = item as? SymbolMenuItem, item.symbol != entry.symbol {
            item.symbol = entry.symbol
            let image = entry.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
                .withSymbolConfiguration(.init(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular))
            image?.isTemplate = true
            item.image = image
            if #available(macOS 27, *) {
                item.preferredImageVisibility = .visible
            }
        }

        if let action = entry.action {
            let target = ActionTarget(action)
            item.representedObject = target
            item.target = target
            item.action = #selector(ActionTarget.run)
        } else {
            item.representedObject = nil
            item.target = nil
            item.action = nil
        }

        if let entries = entry.submenu {
            let submenu = item.submenu ?? {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                return submenu
            }()
            apply(entries, to: submenu)
            if item.submenu !== submenu { item.submenu = submenu }
        } else if item.submenu != nil {
            item.submenu = nil
        }
    }

    #if DEBUG
    /// For UI verification: `-SquirrelOpenMenuAtLaunch YES` opens the menu
    /// a few seconds after launch, so it can be captured without driving the
    /// menu bar, and `-SquirrelMenuAppearance Dark` (or `Light`) forces its
    /// appearance without changing the system's. Documented in
    /// Documentation/UI-Verification.md.
    func openForVerificationIfRequested() {
        guard UserDefaults.standard.bool(forKey: "SquirrelOpenMenuAtLaunch") else { return }
        switch UserDefaults.standard.string(forKey: "SquirrelMenuAppearance") {
        case "Dark": menu.appearance = NSAppearance(named: .darkAqua)
        case "Light": menu.appearance = NSAppearance(named: .aqua)
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }
    #endif

    // MARK: - Actions

    /// SettingsLink is macOS 14+. Squirrel targets Ventura, so open the
    /// Settings scene through the responder chain, whose selector was renamed
    /// in macOS 14.
    static func openSettings() {
        let selector: Selector = if #available(macOS 14, *) {
            Selector(("showSettingsWindow:"))
        } else {
            Selector(("showPreferencesWindow:"))
        }
        NSApp.sendAction(selector, to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Energy (Battery on a laptop), where the UPS Options sheet lives. The
    /// pane's legacy identifier: System Settings maps it to the current
    /// extension (com.apple.Battery-Settings.extension on macOS 27), and an
    /// unknown identifier silently opens General instead.
    static func openEnergySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.EnergySaverPrefPane") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A read-only row at the top of the menu.
private enum MenuRow: Equatable {
    case heading(String)
    case status(MenuBarPresentation.StatusLine)
    case telemetry(MenuBarPresentation.TelemetryRow)
    case note(String)
}

/// One item of the menu, described as a value so it can be compared with
/// what the menu already shows.
private struct MenuEntry {
    let id: String
    var title: String
    var symbol: String?
    var row: MenuRow?
    var keyEquivalent = ""
    var isEnabled = true
    var isSeparator = false
    var toolTip: String?
    var action: (@MainActor () -> Void)?
    var submenu: [MenuEntry]?

    static func separator(_ id: String) -> MenuEntry {
        var entry = MenuEntry(id: "separator.\(id)", title: "")
        entry.isSeparator = true
        return entry
    }

    static func row(id: String, _ row: MenuRow, toolTip: String? = nil) -> MenuEntry {
        var entry = MenuEntry(id: id, title: "")
        entry.row = row
        entry.isEnabled = false
        entry.toolTip = toolTip
        return entry
    }

    static func action(
        id: String,
        title: String,
        symbol: String? = nil,
        key: String = "",
        isEnabled: Bool = true,
        perform: @escaping @MainActor () -> Void
    ) -> MenuEntry {
        var entry = MenuEntry(id: id, title: title)
        entry.symbol = symbol
        entry.keyEquivalent = key
        entry.isEnabled = isEnabled
        entry.action = perform
        return entry
    }
}

/// Draws one read-only row, laid out on the same grid as native items: text
/// at the title inset, status symbols in front of it, readings indented to
/// the status text with values flush against the trailing edge.
private final class MenuRowView: NSView {
    private static let leading: CGFloat = 14
    private static let trailing: CGFloat = 14
    private static let symbolWidth: CGFloat = 16
    private static let symbolGap: CGFloat = 6
    private static var indent: CGFloat { leading + symbolWidth + symbolGap }
    private static var font: NSFont { NSFont.menuFont(ofSize: 0) }

    private let symbolView = NSImageView()
    private let titleField = VibrantLabel(labelWithString: "")
    private let valueField = VibrantLabel(labelWithString: "")
    private var titleLeading: NSLayoutConstraint!
    private var row: MenuRow?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        autoresizingMask = [.width]
        symbolView.imageScaling = .scaleProportionallyDown
        for field in [titleField, valueField] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
        }
        valueField.alignment = .right
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueField.setContentHuggingPriority(.required, for: .horizontal)

        for view in [symbolView, titleField, valueField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        titleLeading = titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leading)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leading),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: Self.symbolWidth),
            symbolView.heightAnchor.constraint(equalToConstant: Self.symbolWidth),
            titleLeading,
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 12),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailing),
            valueField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailing),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ row: MenuRow) {
        guard row != self.row else { return }
        self.row = row
        let font = Self.font
        symbolView.isHidden = true
        valueField.isHidden = true
        titleField.textColor = .labelColor
        titleField.font = font
        titleLeading.constant = Self.indent

        switch row {
        case .heading(let text):
            titleField.stringValue = text
            titleField.font = NSFont.systemFont(ofSize: font.pointSize + 1, weight: .semibold)
            titleLeading.constant = Self.leading
        case .status(let line):
            titleField.stringValue = line.title
            symbolView.image = NSImage(systemSymbolName: line.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .medium))
            symbolView.contentTintColor = Self.color(for: line.tone)
            symbolView.isHidden = false
        case .telemetry(let reading):
            titleField.stringValue = reading.label
            valueField.font = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            valueField.stringValue = reading.value
            valueField.textColor = .labelColor
            valueField.isHidden = false
        case .note(let text):
            titleField.stringValue = text
            titleField.textColor = .secondaryLabelColor
        }

        let height: CGFloat = if case .telemetry = row { 20 } else { 22 }
        // Retain the width AppKit has already allocated while readings change,
        // so a short value does not shrink and re-expand an open menu.
        setFrameSize(NSSize(width: max(frame.width, fittingWidth), height: height))
        setAccessibilityLabel([titleField.stringValue, valueField.isHidden ? nil : valueField.stringValue]
            .compactMap { $0 }.joined(separator: ", "))
    }

    /// Status colours from the system palette, which adapts to light, dark
    /// and increased contrast.
    private static func color(for tone: MenuBarPresentation.Tone) -> NSColor {
        switch tone {
        case .positive: .systemGreen
        case .caution: .systemOrange
        case .critical: .systemRed
        case .neutral: .secondaryLabelColor
        }
    }

    /// The narrowest width that shows the row in full; the menu stretches it
    /// to its own width. Long notes are capped and truncate, with the full
    /// text in the tooltip.
    private var fittingWidth: CGFloat {
        func width(_ field: NSTextField) -> CGFloat {
            field.attributedStringValue.size().width + 4
        }
        let title = min(width(titleField), 300)
        let value = valueField.isHidden ? 0 : width(valueField) + 24
        return ceil(titleLeading.constant + title + value + Self.trailing)
    }
}

/// Text drawn with the menu's vibrancy, like native item titles. The status
/// symbol is an ordinary image view, so it keeps its colour.
private final class VibrantLabel: NSTextField {
    override var allowsVibrancy: Bool { true }
}

/// Remembers which symbol it shows, so an unchanged image is left alone.
private final class SymbolMenuItem: NSMenuItem {
    var symbol: String?
}

/// Holds a menu item's closure; NSMenuItem keeps it alive via representedObject.
private final class ActionTarget: NSObject {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @MainActor @objc func run() {
        action()
    }
}
