import SquirrelCore
import SwiftUI

/// Where a UPS's server and NUT sign-in are changed, laid out like a System
/// Settings pane: the UPS at the top, then the server and the sign-in as two
/// grouped cards. Nothing is applied until a tested draft is saved, and the
/// sign-in card says what signing in would unlock for this particular UPS.
struct UPSConnectionView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var editor: ConnectionEditorModel
    let onFinish: () -> Void
    @State private var testTask: Task<Void, Never>?

    private var monitor: UPSMonitor { appModel.monitor }
    private var reading: UPSReading? { monitor.lastReading(for: editor.device) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 20) {
                serverSection
                signInSection
            }
            .padding(.horizontal, 24)
            .disabled(editor.isTesting)

            message
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

            Divider()
            HStack(spacing: 10) {
                Button {
                    testTask = Task { await editor.testConnection() }
                } label: {
                    HStack(spacing: 6) {
                        if editor.isTesting { ProgressView().controlSize(.small) }
                        Text(editor.isTesting ? "Testing…" : "Test Connection")
                    }
                }
                .disabled(editor.isTesting)
                Spacer()
                Button("Cancel", action: onFinish)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if editor.save() { onFinish() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!editor.canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("Connection")
        .onDisappear {
            testTask?.cancel()
            editor.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            UPSDeviceIllustration(kind: editor.device.illustration(for: reading), isTiled: false)
                .frame(width: 84, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(editor.device.displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(headerDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var headerDetail: String {
        let address = editor.device.port == NUTProtocol.defaultPort
            ? editor.device.host
            : "\(editor.device.host):\(editor.device.port)"
        return "\(address) · \(UPSAppearance.shortStatus(for: monitor.state(for: editor.device), isPaused: monitor.isPaused))"
    }

    // MARK: - Server

    private var serverSection: some View {
        ConnectionSection("Server") {
            ConnectionRow("Address") {
                TextField("Address", text: $editor.host, prompt: Text("nas.local or IP address"))
                    .connectionField()
            }
            RowDivider()
            ConnectionRow("Port") {
                TextField("Port", text: $editor.port, prompt: Text(String(NUTProtocol.defaultPort)))
                    .connectionField()
            }
            RowDivider()
            if editor.candidates.count > 1 {
                ConnectionRow("UPS") {
                    Picker("UPS", selection: $editor.selectedUPSName) {
                        if editor.selectedUPSName == nil {
                            Text("Choose a UPS…").tag(String?.none)
                        }
                        ForEach(editor.candidates) { candidate in
                            Text(candidate.title).tag(Optional(candidate.name))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } else {
                ConnectionRow("UPS identifier") {
                    Text(editor.selectedUPSName ?? editor.device.upsName)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Sign-in

    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConnectionSection("Sign-In") {
                ConnectionRow("Username") {
                    TextField("Username", text: $editor.username, prompt: Text("Not signed in"))
                        .connectionField()
                }
                RowDivider()
                ConnectionRow("Password") {
                    SecureField("Password", text: $editor.password, prompt: Text("None"))
                        .connectionField()
                }
            }
            Text(signInFootnote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    /// What signing in is for, for this UPS rather than in general. A sign-in
    /// that unlocks nothing is still needed by servers that guard readings.
    private var signInFootnote: String {
        let unlocks = MenuBarPresentation.signInUnlocks(supported: monitor.commands(for: editor.device))
        let lead = unlocks.isEmpty
            ? "This UPS's server doesn't offer any command Squirrel sends, so sign in only if the server needs it to share readings."
            : "Signing in lets Squirrel send this UPS commands: \(ListFormatter.localizedString(byJoining: unlocks)). Use a NUT user allowed to run them."
        return lead + " Passwords are stored in your login Keychain."
    }

    // MARK: - Status

    @ViewBuilder
    private var message: some View {
        Group {
            if let error = editor.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if let result = editor.resultMessage {
                Label(result, systemImage: editor.selectedCandidate?.reading == nil ? "info.circle" : "checkmark.circle.fill")
                    .foregroundStyle(editor.selectedCandidate?.reading == nil ? Color.secondary : Color.green)
            } else if editor.hasChanges {
                Text("Test the connection to save your changes. Monitoring carries on meanwhile.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Change the server or sign-in, then test the connection to save.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Layout

/// A titled card of rows, like a group in System Settings.
private struct ConnectionSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .dashboardCard(radius: 10)
        }
    }
}

/// The inset hairline between rows of a section.
private struct RowDivider: View {
    var body: some View { DashboardDivider().padding(.leading, 14) }
}

/// A label on the left and its control on the right.
private struct ConnectionRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
            Spacer(minLength: 12)
            control
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 14)
    }
}

private extension View {
    /// A borderless, trailing field, as System Settings draws text rows.
    func connectionField() -> some View {
        textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .autocorrectionDisabled()
            .frame(maxWidth: 260)
    }
}
