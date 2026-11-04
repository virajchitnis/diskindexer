#if os(iOS)
import CryptoKit
import DiskIndexerKit
import DiskIndexerSSH
import SwiftUI

/// Spike: the shared BrowserView, reaching a server through
/// SSHChannelTransport with this device's own key.
@main
struct DiskIndexerIOSApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

struct RootView: View {
    var model: AppModel
    @AppStorage("spike.addresses") private var addresses = ""
    @AppStorage("spike.socket") private var socket = ""
    @State private var showSettings = false
    @State private var key: Curve25519.Signing.PrivateKey?
    @State private var keyError: String?

    var body: some View {
        Group {
            if key != nil, !parsed.isEmpty, !showSettings {
                BrowserView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button { showSettings = true } label: {
                                Label("Server", systemImage: "server.rack")
                            }
                        }
                    }
            } else {
                settings
            }
        }
        .task {
            do {
                let k = try SSHKeys.loadOrCreate()
                key = k
                // For setting up a test server from the Simulator's console.
                print("DISKINDEXER_PUBLIC_KEY", SSHKeys.openSSHPublicKey(k, comment: "diskindexer-ios"))
                if !parsed.isEmpty { connect() }
            } catch {
                keyError = error.localizedDescription
            }
        }
    }

    private var parsed: [SSHAddress] {
        addresses.split(whereSeparator: { $0 == "," || $0 == "\n" }).compactMap { SSHAddress(String($0)) }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("me@server, me@server.tailnet.ts.net", text: $addresses, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("spike.addresses")
                    TextField("Socket path (optional)", text: $socket)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("user@host or user@host:port. Several, separated by commas, are tried in order.")
                }
                Section {
                    if let key {
                        let line = SSHKeys.openSSHPublicKey(key, comment: "diskindexer-ios")
                        Text(line).font(.footnote.monospaced()).textSelection(.enabled)
                        Button("Copy Public Key") { copyToPasteboard(line) }
                        ShareLink(item: line)
                    } else if let keyError {
                        Text(keyError).foregroundStyle(.red)
                    }
                } header: {
                    Text("This Device\u{2019}s Key")
                } footer: {
                    Text("Add it to ~/.ssh/authorized_keys on the server.")
                }
                Section {
                    Button("Connect") {
                        showSettings = false
                        connect()
                    }
                    .disabled(parsed.isEmpty || key == nil)
                    .accessibilityIdentifier("spike.connect")
                }
            }
            .navigationTitle("DiskIndexer")
        }
    }

    private func connect() {
        guard let key, !parsed.isEmpty else { return }
        let transport = SSHChannelTransport(
            name: parsed[0].host, addresses: parsed, key: key,
            hostKeys: DefaultsHostKeyStore(),
            socketPath: socket.trimmingCharacters(in: .whitespaces))
        model.snapshotDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Snapshots")
        model.watchNetwork()
        model.connect(transport, cacheKey: addresses)
    }
}
#else
// The package also builds for macOS (swift test); this target is iOS only.
@main
enum DiskIndexerIOSStub {
    static func main() {}
}
#endif
