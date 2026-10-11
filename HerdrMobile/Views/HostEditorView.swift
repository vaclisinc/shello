import HerdrKit
import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var keys: KeyStore
    @Environment(\.dismiss) private var dismiss

    @State private var host: HostProfile
    @State private var password = ""
    @State private var portText: String
    @State private var error: String?
    @State private var showingKeys = false
    private let isNew: Bool

    init(host: HostProfile) {
        _host = State(initialValue: host)
        _portText = State(initialValue: String(host.port))
        isNew = host.hostname.isEmpty
    }

    private enum AuthChoice: Hashable { case password, key }

    private var authChoice: Binding<AuthChoice> {
        Binding(
            get: { if case .key = host.auth { return .key } else { return .password } },
            set: { choice in
                switch choice {
                case .password: host.auth = .password
                case .key: host.auth = .key(keys.keys.first?.id ?? UUID())
                }
            }
        )
    }

    private var selectedKey: Binding<UUID?> {
        Binding(
            get: { if case .key(let id) = host.auth { return id } else { return nil } },
            set: { if let id = $0 { host.auth = .key(id) } }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    group("Server") {
                        TextField("Name (optional)", text: $host.name)
                            .field()
                        TextField("Hostname or IP", text: $host.hostname)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .field(monospaced: true)
                        HStack(spacing: 10) {
                            TextField("Username", text: $host.username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .field(monospaced: true)
                            TextField("Port", text: $portText)
                                .keyboardType(.numberPad)
                                .field(monospaced: true)
                                .frame(width: 86)
                        }
                    }

                    group("Authentication") {
                        BlockSegmented(selection: authChoice, options: [(.password, "Password"), (.key, "SSH Key")])
                        if authChoice.wrappedValue == .password {
                            SecureField(hosts.hasPassword(for: host) ? "Password (saved)" : "Password", text: $password)
                                .textContentType(.password)
                                .field()
                        } else if keys.keys.isEmpty {
                            Button("Create or import a key") { showingKeys = true }
                                .buttonStyle(BlockButtonStyle(compact: true))
                        } else {
                            HStack {
                                Text("Key").font(Theme.mono(13)).foregroundStyle(Theme.muted)
                                Spacer()
                                Picker("Key", selection: selectedKey) {
                                    ForEach(keys.keys) { key in
                                        Text(key.name).tag(Optional(key.id))
                                    }
                                }
                                .tint(Theme.ink)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Theme.field)
                            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5))
                            Button("Manage keys") { showingKeys = true }
                                .buttonStyle(BlockButtonStyle(fill: Theme.card, foreground: Theme.ink, compact: true))
                        }
                    }

                    group("On connect", footer: startupFooter) {
                        BlockSegmented(selection: $host.startup, options: [
                            (.herdr, "herdr"), (.tmux, "tmux"), (.shell, "Shell"), (.custom, "Custom"),
                        ])
                        switch host.startup {
                        case .herdr:
                            Toggle("Watch agents & notify", isOn: $host.monitorAgents)
                                .tint(Theme.mint)
                                .padding(.vertical, 2)
                            TextField("herdr path", text: $host.herdrPath)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .field(monospaced: true)
                            TextField("herdr session name (optional)", text: $host.herdrSession)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .field(monospaced: true)
                        case .tmux:
                            TextField("tmux session name", text: $host.tmuxSession)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .field(monospaced: true)
                        case .shell:
                            EmptyView()
                        case .custom:
                            TextField("Command, e.g. zellij attach -c", text: $host.customCommand)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .field(monospaced: true)
                        }
                    }

                    if let error {
                        Text(error)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.onAccent)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card(fill: Theme.coral, shadow: 3)
                    }
                }
                .padding(16)
            }
            .paperScreen()
            .navigationTitle(isNew ? "New Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).bold()
                }
            }
            .sheet(isPresented: $showingKeys) {
                NavigationStack { KeysView() }
            }
        }
    }

    private var startupFooter: String {
        switch host.startup {
        case .herdr:
            return "Install herdr on the server with `curl -fsSL https://herdr.dev/install.sh | sh`. Shello runs `herdr` in the shell and watches your agents over a separate SSH channel."
        case .tmux:
            return "Runs `tmux new-session -A -s <name>`: reattaches if the session exists, otherwise creates it, so your work survives disconnects."
        case .shell:
            return "A plain login shell. Anything running is lost if the connection drops."
        case .custom:
            return "Typed into the shell right after connecting."
        }
    }

    private func group<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .card()
            if let footer {
                Text(.init(footer))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 2)
            }
        }
    }

    private func save() {
        host.port = Int(portText) ?? 0
        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        host.username = host.username.trimmingCharacters(in: .whitespaces)
        guard host.isValid else {
            error = "Hostname, username and a port between 1 and 65535 are required."
            return
        }
        if case .key(let id) = host.auth, keys.key(id) == nil {
            error = "Choose an SSH key."
            return
        }
        if case .password = host.auth, password.isEmpty, !hosts.hasPassword(for: host) {
            error = "Enter a password."
            return
        }
        do {
            try hosts.save(host, password: password)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
