import HerdrKit
import UIKit
import SwiftUI

struct KeysView: View {
    @EnvironmentObject private var keys: KeyStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingImport = false
    @State private var error: String?
    @State private var copied: UUID?

    var body: some View {
        List {
            Section {
                ForEach(keys.keys) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(key.name).font(.headline)
                            Spacer()
                            Text(key.keyType).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(key.fingerprint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack {
                            Button {
                                UIPasteboard.general.string = key.publicKey
                                copied = key.id
                            } label: {
                                Label(copied == key.id ? "Copied" : "Copy Public Key", systemImage: copied == key.id ? "checkmark" : "doc.on.doc")
                            }
                            ShareLink(item: key.publicKey) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { offsets in
                    offsets.map { keys.keys[$0] }.forEach(keys.delete)
                }
            } footer: {
                Text("Add the public key to `~/.ssh/authorized_keys` on your server. Private keys stay in this device's Keychain.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("SSH Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { generate() } label: { Label("Generate ed25519 Key", systemImage: "sparkles") }
                    Button { showingImport = true } label: { Label("Import Private Key", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingImport) {
            ImportKeyView()
        }
    }

    private func generate() {
        do {
            let name = "\(UIDevice.current.name) \(keys.keys.count + 1)"
            try keys.generate(name: name)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ImportKeyView: View {
    @EnvironmentObject private var keys: KeyStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Imported key"
    @State private var pem = ""
    @State private var passphrase = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section("Private key (OpenSSH format)") {
                    TextEditor(text: $pem)
                        .font(.caption.monospaced())
                        .frame(minHeight: 180)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste from Clipboard") { pem = UIPasteboard.general.string ?? "" }
                }
                SecureField("Passphrase (if encrypted)", text: $passphrase)
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            try keys.importKey(name: name, pem: pem, passphrase: passphrase)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(pem.isEmpty)
                }
            }
        }
    }
}
