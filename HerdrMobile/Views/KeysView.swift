import HerdrKit
import UIKit
import SwiftUI

struct KeysView: View {
    @EnvironmentObject private var keys: KeyStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingImport = false
    @State private var error: String?
    @State private var copied: UUID?
    @State private var renaming: SSHKeyInfo?
    @State private var newName = ""

    var body: some View {
        List {
            if keys.keys.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("NO KEYS YET").font(Theme.mono(15, .heavy)).foregroundStyle(Theme.ink)
                    Text("Generate an ed25519 key on this device or import one you already use.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                    Button("Generate key") { generate() }
                        .buttonStyle(BlockButtonStyle(compact: true))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                .cardRow()
            }
            Section {
                ForEach(keys.keys) { key in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(key.name).font(.headline).foregroundStyle(Theme.ink)
                            Spacer()
                            Text(key.keyType)
                                .font(Theme.mono(10))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .overlay(Rectangle().strokeBorder(Theme.muted, lineWidth: 1))
                                .foregroundStyle(Theme.muted)
                        }
                        Text(key.fingerprint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 8) {
                            Button {
                                UIPasteboard.general.string = key.publicKey
                                copied = key.id
                            } label: {
                                Label(copied == key.id ? "Copied" : "Copy public key", systemImage: copied == key.id ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(BlockButtonStyle(fill: copied == key.id ? Theme.mint : Theme.yellow, compact: true))
                            ShareLink(item: key.publicKey) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(BlockButtonStyle(fill: Theme.card, foreground: Theme.ink, compact: true))
                        }
                        .padding(.top, 2)
                    }
                    .padding(14)
                    .card()
                    .cardRow()
                    .contextMenu {
                        Button { startRename(key) } label: { Label("Rename", systemImage: "pencil") }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { keys.delete(key) } label: { Label("Delete", systemImage: "trash") }
                        Button { startRename(key) } label: { Label("Rename", systemImage: "pencil") }
                            .tint(Theme.sky)
                    }
                }
                .onDelete { offsets in
                    offsets.map { keys.keys[$0] }.forEach(keys.delete)
                }
            } footer: {
                Text("Add the public key to `~/.ssh/authorized_keys` on your server. Private keys stay in this device's Keychain.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 6)
            }

            if let error {
                Text(error)
                    .foregroundStyle(Theme.onAccent)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(fill: Theme.coral, shadow: 3)
                    .cardRow()
            }
        }
        .listStyle(.plain)
        .paperScreen()
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
        .alert("Rename Key", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let renaming { keys.rename(renaming, to: newName) }
            }
        }
    }

    private func startRename(_ key: SSHKeyInfo) {
        newName = key.name
        renaming = key
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
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Name")
                    TextField("Name", text: $name).field()
                    SectionLabel("Private key (OpenSSH format)").padding(.top, 8)
                    TextEditor(text: $pem)
                        .font(.caption.monospaced())
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 180)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(6)
                        .background(Theme.field)
                        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5))
                    Button("Paste from clipboard") { pem = UIPasteboard.general.string ?? "" }
                        .buttonStyle(BlockButtonStyle(fill: Theme.card, foreground: Theme.ink, compact: true))
                    SectionLabel("Passphrase").padding(.top, 8)
                    SecureField("Passphrase (if encrypted)", text: $passphrase).field()
                    if let error {
                        Text(error)
                            .foregroundStyle(Theme.onAccent)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card(fill: Theme.coral, shadow: 3)
                            .padding(.top, 8)
                    }
                }
                .padding(16)
            }
            .paperScreen()
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
