import SwiftUI

struct UPSConnectionView: View {
    @ObservedObject var editor: ConnectionEditorModel
    let onFinish: () -> Void
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connection").font(.title2.weight(.semibold))
                Text(editor.device.displayName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(24)

            VStack(alignment: .leading, spacing: 12) {
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text("Server").foregroundStyle(.secondary)
                            TextField("Server", text: $editor.host, prompt: Text("nas.local or IP address"))
                                .labelsHidden()
                                .accessibilityLabel("Server")
                                .autocorrectionDisabled()
                        }
                        GridRow {
                            Text("Port").foregroundStyle(.secondary)
                            TextField("Port", text: $editor.port)
                                .labelsHidden()
                                .accessibilityLabel("Port")
                                .autocorrectionDisabled()
                        }
                        if editor.candidates.count > 1 {
                            GridRow {
                                Text("UPS device").foregroundStyle(.secondary)
                                Picker("UPS device", selection: $editor.selectedUPSName) {
                                    if editor.selectedUPSName == nil {
                                        Text("Choose a UPS…").tag(String?.none)
                                    }
                                    ForEach(editor.candidates) { candidate in
                                        Text(candidate.name).tag(Optional(candidate.name))
                                    }
                                }
                                .labelsHidden()
                                .accessibilityLabel("UPS device")
                            }
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                }
                Text("Test the server to verify this connection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    DisclosureGroup("Authentication", isExpanded: $editor.showsAuthentication) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                            GridRow {
                                Text("Username").foregroundStyle(.secondary)
                                TextField("Username", text: $editor.username, prompt: Text("Optional"))
                                    .labelsHidden()
                                    .accessibilityLabel("Username")
                                    .autocorrectionDisabled()
                            }
                            GridRow {
                                Text("Password").foregroundStyle(.secondary)
                                SecureField("Password", text: $editor.password, prompt: Text("Optional"))
                                    .labelsHidden()
                                    .accessibilityLabel("Password")
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(.top, 12)
                    }
                    .padding(10)
                }
                Text("Only required by some NUT servers. Passwords are stored in your login Keychain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .disabled(editor.isTesting)

            VStack(alignment: .leading, spacing: 10) {
                if let error = editor.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if let message = editor.resultMessage {
                    Label(message, systemImage: editor.selectedCandidate?.reading == nil ? "info.circle" : "checkmark.circle.fill")
                        .foregroundStyle(editor.selectedCandidate?.reading == nil ? Color.secondary : Color.green)
                } else {
                    Text("Changes take effect when you save. Monitoring continues while you edit.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(20)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear {
            testTask?.cancel()
            editor.cancel()
        }
    }
}
