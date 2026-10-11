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
            Form {
                Section("Server") {
                    TextField("Name (optional)", text: $host.name)
                    TextField("Hostname or IP", text: $host.hostname)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $host.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Authentication") {
                    Picker("Method", selection: authChoice) {
                        Text("Password").tag(AuthChoice.password)
                        Text("SSH Key").tag(AuthChoice.key)
                    }
                    .pickerStyle(.segmented)

                    if authChoice.wrappedValue == .password {
                        SecureField(hosts.hasPassword(for: host) ? "Password (saved)" : "Password", text: $password)
                            .textContentType(.password)
                    } else if keys.keys.isEmpty {
                        Button("Create or Import a Key…") { showingKeys = true }
                    } else {
                        Picker("Key", selection: selectedKey) {
                            ForEach(keys.keys) { key in
                                Text(key.name).tag(Optional(key.id))
                            }
                        }
                        Button("Manage Keys…") { showingKeys = true }
                    }
                }

                Section {
                    Toggle("Open herdr on connect", isOn: $host.autoAttachHerdr)
                    Toggle("Watch agents & notify", isOn: $host.monitorAgents)
                    TextField("herdr path", text: $host.herdrPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    TextField("Session name (optional)", text: $host.herdrSession)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("herdr")
                } footer: {
                    Text("Install herdr on the server with `curl -fsSL https://herdr.dev/install.sh | sh`. The app runs `herdr` in the shell and polls `herdr api snapshot` over a separate SSH channel.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(isNew ? "New Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .sheet(isPresented: $showingKeys) {
                NavigationStack { KeysView() }
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
