import SquirrelCore
import SwiftUI

/// The connection assistant: welcome, find, connect, select, progress, done.
///
/// Every screen here reads from `ConnectionAssistantModel`; the view owns only
/// which radio button is lit. Nothing on screen is a placeholder — the device
/// list comes from `LIST UPS` and the telemetry from the UPS itself.
struct ConnectionAssistantView: View {
    @ObservedObject var assistant: ConnectionAssistantModel
    /// Called when the user is finished, with the UPS they configured.
    let onFinish: (UPSDevice?) -> Void

    private enum FindMode { case automatic, manual }
    private enum Field: Hashable { case host, port, username, password }

    @State private var findMode: FindMode = .automatic
    @State private var selectedServerID: String?
    @FocusState private var focusedField: Field?
    /// The step on screen, which follows the model's a moment later so the
    /// outgoing step is redrawn with the right direction before it leaves.
    @State private var shownStep: ConnectionAssistantModel.Step?
    @State private var movingBack = false
    @State private var contentHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var discovery: NUTDiscoveryService { assistant.discovery }

    var body: some View {
        VStack(spacing: 0) {
            if let index = assistant.progressIndex {
                AssistantStepIndicator(titles: ["Find UPS", "Select", "Finish"], current: index)
                    .padding(.top, 18)
                    .padding(.bottom, 20)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: index)
            }

            // The window grows to fit each step, and only scrolls once a step
            // would be taller than the screen allows.
            ScrollView {
                ZStack {
                    content(for: step)
                        .id(step)
                        .transition(stepTransition)
                }
                .padding(.horizontal, 28)
                .padding(.top, assistant.progressIndex == nil ? 30 : 0)
                .padding(.bottom, 24)
                // The screens without a step indicator are a single
                // statement, so they sit in the middle of the window
                // rather than hugging the top of it.
                .frame(maxWidth: .infinity, minHeight: centersContent ? 368 : 0)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: AssistantContentHeight.self, value: geometry.size.height)
                    }
                }
            }
            .frame(height: min(contentHeight, maxContentHeight))
            .clipped()
            .onPreferenceChange(AssistantContentHeight.self) { contentHeight = $0 }

            // A short step leaves the footer at the foot of the window.
            Spacer(minLength: 0)

            if hasFooter {
                Divider()
                footer
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
        }
        .frame(width: 560)
        .frame(minHeight: 468)
        // Fixed to its content, so the window resizes with each step.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: assistant.step) { newStep in
            movingBack = Self.order(of: newStep) < Self.order(of: step)
            // Next turn, so the leaving step picks up the new direction first.
            DispatchQueue.main.async {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { shownStep = newStep }
            }
        }
    }

    private var step: ConnectionAssistantModel.Step { shownStep ?? assistant.step }

    /// Steps slide in the direction of travel, and Back slides the other way.
    /// With Reduce Motion there is no animation, so they simply swap.
    private var stepTransition: AnyTransition {
        let leading = AnyTransition.move(edge: .leading).combined(with: .opacity)
        let trailing = AnyTransition.move(edge: .trailing).combined(with: .opacity)
        return movingBack
            ? .asymmetric(insertion: leading, removal: trailing)
            : .asymmetric(insertion: trailing, removal: leading)
    }

    private static func order(of step: ConnectionAssistantModel.Step) -> Int {
        switch step {
        case .welcome: return 0
        case .find: return 1
        case .manual: return 2
        case .select: return 3
        case .connecting: return 4
        case .finished: return 5
        }
    }

    /// Room for the step indicator, footer and window chrome, so a tall step
    /// scrolls instead of running off a small screen.
    private var maxContentHeight: CGFloat {
        max(368, (NSScreen.main?.visibleFrame.height ?? 900) - 220)
    }

    private var centersContent: Bool {
        switch step {
        case .welcome, .connecting, .finished: return true
        default: return false
        }
    }

    @ViewBuilder
    private func content(for step: ConnectionAssistantModel.Step) -> some View {
        switch step {
        case .welcome: welcomeStep
        case .find: findStep
        case .manual: manualStep
        case .select: selectStep
        case .connecting: connectingStep
        case .finished: finishedStep
        }
    }

    // MARK: - 1. Welcome

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            SquirrelAppIcon()
                .frame(width: 104, height: 104)

            Text("Set Up Your UPS")
                .font(SquirrelFont.assistantTitle)
                .accessibilityAddTraits(.isHeader)

            Text("Squirrel connects to your network UPS and makes it available to macOS, just like a USB-connected UPS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)

            AssistantNoticeBox(
                kind: .positive,
                title: "Native macOS integration",
                detail: "Battery status and shutdown settings appear directly in System Settings."
            )
            .frame(maxWidth: 400)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 2. Find

    private var findStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            AssistantHeader(
                title: "Find Your UPS",
                subtitle: "Squirrel can search your network for compatible UPS servers, or you can enter an address manually."
            )

            VStack(spacing: 0) {
                AssistantChoiceRow(
                    title: "Search my network",
                    detail: discoveryDetail,
                    isSelected: findMode == .automatic,
                    action: { findMode = .automatic },
                    accessory: {
                        if discovery.state.isScanning {
                            ProgressView().controlSize(.small)
                        } else if case .finished = discovery.state {
                            Button("Scan Again") { discovery.restart() }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                )

                if findMode == .automatic {
                    discoveryResults
                }

                AssistantRowDivider()

                AssistantChoiceRow(
                    title: "Enter server address manually",
                    detail: "Type the address of a NUT server Squirrel didn't find.",
                    isSelected: findMode == .manual
                ) {
                    findMode = .manual
                    selectedServerID = nil
                }
            }
            .assistantGroup()

            if discovery.localNetworkDenied {
                AssistantNoticeBox(
                    kind: .warning,
                    title: "Squirrel can't search your local network",
                    detail: "Turn Squirrel on under Privacy & Security → Local Network in System Settings, or enter the server address manually."
                )
            }

            if let error = assistant.validationError {
                AssistantNoticeBox(kind: .negative, title: error, detail: assistant.accessHelp)
            }
        }
        .task { discovery.startIfNeeded() }
        .onAppear(perform: preselectOnlyServer)
        .onChange(of: discovery.servers.count) { _ in preselectOnlyServer() }
    }

    /// One server found, and not one Squirrel already has: choose it, so
    /// Continue works straight away.
    private func preselectOnlyServer() {
        guard findMode == .automatic, selectedServerID == nil, discovery.servers.count == 1,
              let server = discovery.servers.first, !server.deniedAccess, !assistant.isAlreadyAdded(server)
        else { return }
        selectedServerID = server.id
    }

    private var discoveryDetail: String? {
        switch discovery.state {
        case .idle:
            return nil
        case .scanning(let fraction):
            return "Searching for NUT servers… \(Int(fraction * 100))%"
        case .finished:
            return discovery.hasResults
                ? "\(discovery.servers.count) server\(discovery.servers.count == 1 ? "" : "s") found"
                : "No NUT servers answered on this network."
        case .unavailable(let message):
            return message
        }
    }

    @ViewBuilder
    private var discoveryResults: some View {
        if discovery.servers.isEmpty {
            HStack(spacing: 8) {
                if discovery.state.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Looking for NUT servers on your network…")
                } else if case .unavailable = discovery.state {
                    Text("Discovery isn't available right now. Enter the address manually instead.")
                } else {
                    Text("Nothing found yet. Your UPS server may be on another network, or need a username and password.")
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .padding(.leading, 26)
        } else {
            VStack(spacing: 0) {
                ForEach(discovery.servers) { server in
                    serverRow(server)
                    if server.id != discovery.servers.last?.id { AssistantRowDivider() }
                }
            }
            .assistantGroup()
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .padding(.leading, 26)
        }
    }

    private func serverRow(_ server: DiscoveredNUTServer) -> some View {
        Button {
            selectedServerID = server.id
            findMode = .automatic
        } label: {
            HStack(spacing: 10) {
                if let kind = illustration(for: server) {
                    AssistantIllustrationTile(kind: kind, height: 28)
                } else {
                    AssistantSymbolTile(
                        symbol: "server.rack",
                        tint: selectedServerID == server.id ? .accentColor : .secondary,
                        size: 28
                    )
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(serverTitle(server)).font(.body.weight(.medium)).lineLimit(1)
                    Text(serverDetail(server)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if assistant.isAlreadyAdded(server) {
                    AssistantStatusBadge(text: "Already added", tint: .secondary)
                } else if server.deniedAccess {
                    AssistantStatusBadge(text: "Not permitted", tint: .orange)
                } else if server.requiresAuthentication {
                    AssistantStatusBadge(text: "Sign-in needed", tint: .orange)
                } else if let identity = discoveredIdentity(of: server), identity.value("ups.status") != nil {
                    AssistantStatusBadge(
                        text: MenuBarPresentation.statusPhrase(for: identity.status),
                        tint: tint(for: identity)
                    )
                } else if server.upsNames.count > 1 {
                    AssistantStatusBadge(text: "\(server.upsNames.count) UPSes", tint: .green)
                } else if !server.upsNames.isEmpty {
                    AssistantStatusBadge(text: "Available", tint: .green)
                }
                // A selection mark, not a chevron: choosing a row selects it,
                // it doesn't open anything.
                Image(systemName: selectedServerID == server.id ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selectedServerID == server.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedServerID == server.id ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("NUT server at \(server.address)")
    }

    /// What the one UPS a server serves said about itself while it was being
    /// found. A server with several, or one that wouldn't say, gets nil so
    /// its row describes the server rather than one UPS picked at random.
    private func discoveredIdentity(of server: DiscoveredNUTServer) -> UPSReading? {
        guard server.upsNames.count == 1, let name = server.upsNames.first else { return nil }
        var variables: [String: String] = [:]
        variables["device.mfr"] = server.upsManufacturers[name]
        variables["ups.model"] = server.upsModels[name]
        variables["ups.status"] = server.upsStatuses[name]
        return variables.isEmpty ? nil : UPSReading(upsName: name, variables: variables)
    }

    /// Only once the maker is known: a guess from nothing would just be the
    /// generic tower, which says less than the server symbol.
    private func illustration(for server: DiscoveredNUTServer) -> UPSIllustrationKind? {
        guard let identity = discoveredIdentity(of: server), UPSNaming.manufacturer(in: identity) != nil else { return nil }
        return UPSIllustrationKind(reading: identity)
    }

    /// The UPS's product name, "UniFi UPS 2U", when the server serves just
    /// one and said what it is; otherwise the server's own name.
    private func serverTitle(_ server: DiscoveredNUTServer) -> String {
        discoveredIdentity(of: server).flatMap(UPSNaming.suggestedName(for:)) ?? server.displayName
    }

    /// The address, plus what kind of server it is when that is recognisable.
    /// When the title is the UPS's product name, the host name moves here so
    /// it is still visible.
    private func serverDetail(_ server: DiscoveredNUTServer) -> String {
        let kind = NUTServerKind.detect(
            hostName: server.hostName,
            upsNames: server.upsNames,
            descriptions: Array(server.upsDescriptions.values),
            manufacturers: server.upsManufacturers.values.compactMap(UPSNaming.normalisedManufacturer)
        )
        let titledByProduct = serverTitle(server) != server.displayName
        // "UniFi UPS" only repeats a title like "UniFi UPS 2U".
        let kindTitle = titledByProduct && kind == .unifi ? nil : kind?.title
        // The port only when it isn't NUT's usual one.
        let address = server.port == NUTProtocol.defaultPort ? server.host : server.address
        return [kindTitle, titledByProduct ? server.hostName : nil, address]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // MARK: - 3. Manual connection

    private var manualStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            AssistantHeader(
                title: "Connect to Your UPS",
                subtitle: "Enter the details for your NUT server."
            )

            Form {
                Section {
                    TextField("Server address", text: $assistant.host, prompt: Text("192.168.1.1 or nas.local"))
                        .focused($focusedField, equals: .host)
                        .disableAutocorrection(true)
                        .onSubmit(submitManualEntry)
                }

                Section {
                    DisclosureRow("Authentication (optional)", isExpanded: $assistant.showsAuthentication) {
                        TextField("Username", text: $assistant.username, prompt: Text("e.g. nutadmin"))
                            .focused($focusedField, equals: .username)
                            .disableAutocorrection(true)
                        SecureField("Password", text: $assistant.password)
                            .focused($focusedField, equals: .password)
                            .onSubmit(submitManualEntry)
                        defaultCredentialsMenu
                    }
                } footer: {
                    Text("Leave this closed if your NUT server allows access without a sign-in. Passwords are stored in your login Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    DisclosureRow("Advanced", isExpanded: $assistant.showsAdvanced) {
                        TextField("Port", text: $assistant.port, prompt: Text("3493"))
                            .focused($focusedField, equals: .port)
                            .frame(maxWidth: 140)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: formHeight)
            .padding(.horizontal, -20)

            if let error = assistant.validationError {
                AssistantNoticeBox(kind: .negative, title: error, detail: assistant.accessHelp)
            }
        }
        .onAppear { focusedField = .host }
    }

    /// Synology and QNAP use fixed credentials nobody remembers. Offered,
    /// never filled in unasked: most NUT servers need none at all.
    private var defaultCredentialsMenu: some View {
        let kinds = NUTServerKind.allCases.filter { $0.defaultCredentials != nil }
        return HStack {
            Spacer()
            Menu("Use Defaults For") {
                ForEach(kinds) { kind in
                    Button(kind.title) { assistant.useDefaultCredentials(of: kind) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Fill in the fixed credentials a NAS uses for its UPS server")
        }
    }

    /// A `Form` has no intrinsic height, so the step gives it one that follows
    /// which disclosures are open.
    private var formHeight: CGFloat {
        var height: CGFloat = 200
        if assistant.showsAuthentication { height += 136 }
        if assistant.showsAdvanced { height += 50 }
        return height
    }

    // MARK: - 4. Select the UPS

    private var selectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            AssistantHeader(
                title: "Select Your UPS",
                subtitle: "Choose the UPS you'd like Squirrel to connect to."
            )

            VStack(spacing: 0) {
                ForEach(assistant.candidates) { candidate in
                    AssistantChoiceRow(
                        title: candidate.title,
                        detail: UPSNaming.address(upsName: candidate.name, host: assistant.host, hostName: assistant.serverHostName),
                        symbol: "bolt.badge.clock",
                        illustration: candidate.reading.map { UPSIllustrationKind(reading: $0) },
                        isSelected: assistant.selectedUPSName == candidate.name,
                        action: { assistant.selectedUPSName = candidate.name },
                        accessory: {
                            if assistant.existingDevice(for: candidate) != nil {
                                AssistantStatusBadge(text: "Already added", tint: .secondary)
                            } else if let phrase = candidate.statusPhrase {
                                AssistantStatusBadge(text: phrase, tint: tint(for: candidate.reading))
                            }
                        }
                    )
                    if candidate.id != assistant.candidates.last?.id { AssistantRowDivider() }
                }
            }
            .assistantGroup()

            if let existing = assistant.selectedCandidate.flatMap(assistant.existingDevice(for:)) {
                AssistantNoticeBox(
                    kind: .warning,
                    title: "“\(existing.displayName)” is already in Squirrel",
                    detail: "Connecting updates it with these settings rather than adding it a second time."
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.callout.weight(.medium))
                TextField(
                    "Name",
                    text: Binding(get: { assistant.proposedName }, set: { assistant.editName($0) }),
                    prompt: Text("Network Rack UPS")
                )
                .labelsHidden()
                .accessibilityLabel("Name")
                .textFieldStyle(.roundedBorder)
                Text("How the UPS appears in Squirrel and in System Settings. You can change it later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 5. Connecting

    private var connectingStep: some View {
        VStack(spacing: 16) {
            AssistantSymbolTile(symbol: "bolt.horizontal.circle", tint: .accentColor, size: 56)
                .overlay(alignment: .bottomTrailing) {
                    ProgressView().controlSize(.small).offset(x: 4, y: 4)
                }

            VStack(spacing: 4) {
                Text("Connecting to \(assistant.selectedCandidate?.title ?? "your UPS")…")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Squirrel is setting up the connection and handing the UPS to macOS.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(assistant.stages) { stage in
                    stageRow(stage)
                    if stage.id != assistant.stages.last?.id { AssistantRowDivider() }
                }
            }
            .assistantGroup()
            .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
    }

    private func stageRow(_ stage: ConnectionStage) -> some View {
        HStack(spacing: 10) {
            stageIndicator(stage.status)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.kind.title)
                    .font(.callout)
                    .foregroundStyle(stage.status == .pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if let note = stageNote(stage.status) {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityValue(stageAccessibilityValue(stage.status))
    }

    @ViewBuilder
    private func stageIndicator(_ status: ConnectionStage.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func stageNote(_ status: ConnectionStage.Status) -> String? {
        switch status {
        case .skipped(let note): return note
        case .failed(let message): return message
        default: return nil
        }
    }

    private func stageAccessibilityValue(_ status: ConnectionStage.Status) -> String {
        switch status {
        case .pending: return "Waiting"
        case .running: return "In progress"
        case .succeeded: return "Done"
        case .skipped(let note): return "Skipped. \(note)"
        case .failed(let message): return "Failed. \(message)"
        }
    }

    // MARK: - 6. Finished

    @ViewBuilder
    private var finishedStep: some View {
        switch assistant.outcome {
        case .published:
            successStep(
                kind: .positive,
                symbol: "checkmark",
                title: "All Set!",
                subtitle: "Your UPS is now connected and available in macOS."
            ) {
                AssistantNoticeBox(
                    kind: .positive,
                    title: "Available in System Settings",
                    detail: "You can now configure your Mac's UPS shutdown settings directly in macOS."
                )
            }
        case .connectedOnly(let explanation):
            successStep(
                kind: .warning,
                symbol: "exclamationmark",
                title: "Connected to Your UPS",
                subtitle: "Squirrel is reading this UPS, but macOS isn't using it as a power source."
            ) {
                AssistantNoticeBox(kind: .warning, title: "Native integration isn't active", detail: explanation)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                resultGlyph(symbol: "xmark", tint: .red)
                VStack(spacing: 4) {
                    Text("Couldn't Connect").font(SquirrelFont.assistantTitle)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(assistant.stages) { stage in
                        stageRow(stage)
                        if stage.id != assistant.stages.last?.id { AssistantRowDivider() }
                    }
                }
                .assistantGroup()
                .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity)
        case .none:
            ProgressView()
        }
    }

    private func successStep<Notice: View>(
        kind: AssistantNoticeBox.Kind,
        symbol: String,
        title: String,
        subtitle: String,
        @ViewBuilder notice: () -> Notice
    ) -> some View {
        VStack(spacing: 12) {
            resultGlyph(symbol: symbol, tint: kind.tint)

            VStack(spacing: 4) {
                Text(title).font(SquirrelFont.assistantTitle)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            summaryCard
            notice()
        }
        .frame(maxWidth: .infinity)
    }

    private func resultGlyph(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 25, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 56, height: 56)
            .background(tint.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }

    /// Live values from the UPS. Shown only where the UPS actually reported
    /// them, so nothing here is invented.
    @ViewBuilder
    private var summaryCard: some View {
        let reading = assistant.summaryReading
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let kind = assistant.connectedDevice.map({ $0.illustration(for: reading) }) ?? reading.map({ UPSIllustrationKind(reading: $0) }) {
                    AssistantIllustrationTile(kind: kind, height: 30)
                } else {
                    AssistantSymbolTile(symbol: "bolt.badge.clock", tint: .secondary, size: 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(assistant.connectedTitle).font(.body.weight(.medium)).lineLimit(1)
                    if let device = assistant.connectedDevice {
                        Text(UPSNaming.address(upsName: device.upsName, host: device.host, hostName: assistant.serverHostName))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let reading {
                    AssistantStatusBadge(
                        text: MenuBarPresentation.statusPhrase(for: reading.status),
                        tint: tint(for: reading)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)

            if let reading, !metrics(for: reading).isEmpty {
                AssistantRowDivider()
                HStack(alignment: .top, spacing: 0) {
                    ForEach(metrics(for: reading), id: \.label) { metric in
                        VStack(spacing: 2) {
                            Label(metric.value, systemImage: metric.symbol)
                                .font(.body.weight(.medium))
                                .labelStyle(.titleAndIcon)
                            Text(metric.label).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
            }
        }
        .assistantGroup()
        .frame(maxWidth: 420)
    }

    private func metrics(for reading: UPSReading) -> [(symbol: String, value: String, label: String)] {
        var metrics: [(symbol: String, value: String, label: String)] = []
        if let charge = reading.batteryCharge {
            metrics.append((
                MenuBarPresentation.batterySymbol(forCharge: charge),
                "\(charge)%",
                "Battery charge"
            ))
        }
        if let runtime = reading.batteryRuntime {
            metrics.append(("clock", Self.runtimeDescription(seconds: runtime), "Estimated runtime"))
        }
        if let load = reading.load {
            metrics.append(("gauge.medium", "\(load)%", "Load"))
        }
        return metrics
    }

    static func runtimeDescription(seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        guard minutes >= 60 else { return "\(minutes) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }

    private func tint(for reading: UPSReading?) -> Color {
        guard let reading else { return .secondary }
        if reading.status.isCritical { return .red }
        return reading.status.isRunningOnBattery ? .orange : .green
    }

    // MARK: - Footer

    private var hasFooter: Bool {
        assistant.step != .connecting
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            // Leaving is always possible before the result: Cancel at the
            // leading edge, with Escape, and Back beside the way forward.
            if assistant.step != .finished {
                Button("Cancel") { onFinish(nil) }
                    .assistantSecondaryButton()
                    .keyboardShortcut(.cancelAction)
            }

            Spacer(minLength: 0)

            if assistant.isValidating {
                ProgressView().controlSize(.small)
            }

            if assistant.canGoBack {
                Button("Back") { assistant.back() }
                    .assistantSecondaryButton()
                    .disabled(assistant.isValidating)
            }

            switch assistant.step {
            case .welcome:
                Button("Get Started") { assistant.beginFinding() }
                .assistantPrimaryButton()
                .keyboardShortcut(.defaultAction)

            case .find:
                Button("Continue") { Task { await continueFromFind() } }
                .assistantPrimaryButton()
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinueFromFind || assistant.isValidating)

            case .manual:
                Button("Continue") { submitManualEntry() }
                .assistantPrimaryButton()
                .keyboardShortcut(.defaultAction)
                .disabled(assistant.host.trimmingCharacters(in: .whitespaces).isEmpty || assistant.isValidating)

            case .select:
                Button("Connect") { Task { await assistant.connect() } }
                .assistantPrimaryButton()
                .keyboardShortcut(.defaultAction)
                .disabled(assistant.selectedUPSName == nil)

            case .connecting:
                EmptyView()

            case .finished:
                finishedFooterButtons
            }
        }
    }

    @ViewBuilder
    private var finishedFooterButtons: some View {
        switch assistant.outcome {
        case .published:
            Button("Open Energy Settings") { MenuBarMenu.openEnergySettings() }
                .assistantSecondaryButton()
            Button("Done") { onFinish(assistant.connectedDevice) }
                .assistantPrimaryButton()
                .keyboardShortcut(.defaultAction)
        case .connectedOnly:
            // Trying again can't help when sharing is simply switched off.
            if assistant.isSharingOff {
                Button("Share with macOS") { Task { await assistant.shareWithMacOS() } }
                    .assistantSecondaryButton()
            } else {
                Button("Try Again") { Task { await assistant.retryConnection() } }
                    .assistantSecondaryButton()
            }
            Button("Done") { onFinish(assistant.connectedDevice) }
                .assistantPrimaryButton()
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Change Settings") { assistant.returnToSelection() }
                .assistantSecondaryButton()
            Button("Try Again") { Task { await assistant.retryConnection() } }
                .assistantPrimaryButton()
                .keyboardShortcut(.defaultAction)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Actions

    private var canContinueFromFind: Bool {
        findMode == .manual || selectedServer != nil
    }

    private var selectedServer: DiscoveredNUTServer? {
        discovery.servers.first { $0.id == selectedServerID }
    }

    private func continueFromFind() async {
        if findMode == .manual {
            assistant.chooseManualEntry()
            return
        }
        guard let server = selectedServer else { return }
        await assistant.use(server)
    }

    private func submitManualEntry() {
        guard !assistant.isValidating else { return }
        Task { await assistant.enumerateServer() }
    }
}

private struct AssistantContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
