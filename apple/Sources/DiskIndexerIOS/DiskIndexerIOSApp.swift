#if os(iOS)
import CryptoKit
import DiskIndexerKit
import DiskIndexerSSH
import SwiftUI

/// The iPhone and iPad app: the shared BrowserView, reaching servers over SSH
/// with this device's own key (see SSHChannelTransport).
@main
struct DiskIndexerIOSApp: App {
    @State private var model = AppModel()
    @State private var store = ServerStore()

    var body: some Scene {
        WindowGroup {
            RootView(model: model, store: store)
        }
    }
}

/// A server the app connects to.
struct Server: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// user@host[:port], tried in order.
    var addresses: [String]
    /// Remote socket path; empty means the server default.
    var socketPath = ""

    var parsed: [SSHAddress] { addresses.compactMap(SSHAddress.init) }
}

/// Saved servers and which one is selected, in UserDefaults.
@Observable
final class ServerStore {
    private(set) var servers: [Server]
    var selectedID: UUID? {
        didSet { defaults.set(selectedID?.uuidString, forKey: "selectedServer") }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        servers = (defaults.data(forKey: "servers")).flatMap { try? JSONDecoder().decode([Server].self, from: $0) } ?? []
        selectedID = defaults.string(forKey: "selectedServer").flatMap(UUID.init)
        // `-addServer user@host` on the command line, for the Simulator.
        if servers.isEmpty, let address = defaults.string(forKey: "addServer"), let parsed = SSHAddress(address) {
            save(Server(name: parsed.host, addresses: [address]))
        }
        if selected == nil { selectedID = servers.first?.id }
    }

    var selected: Server? { servers.first { $0.id == selectedID } }

    func save(_ server: Server) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        selectedID = server.id
        persist()
    }

    func remove(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        if selectedID == server.id { selectedID = servers.first?.id }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(servers), forKey: "servers")
    }
}

struct RootView: View {
    var model: AppModel
    var store: ServerStore
    @State private var key: Curve25519.Signing.PrivateKey?
    @State private var keyError: String?
    @State private var editing: Server?
    @State private var showKey = false

    var body: some View {
        Group {
            if store.selected != nil {
                BrowserView(model: model, sidebarAccessory: AnyView(serverMenu))
            } else {
                Welcome(publicKey: publicKey, keyError: keyError) {
                    editing = Server(name: "", addresses: [""])
                }
            }
        }
        .sheet(item: $editing) { server in
            ServerEditor(server: server, isNew: !store.servers.contains { $0.id == server.id },
                         publicKey: publicKey) { saved in
                editing = nil
                guard let saved else { return }
                store.save(saved)
                connect()
            }
        }
        .sheet(isPresented: $showKey) {
            NavigationStack {
                KeySection(publicKey: publicKey, error: keyError)
                    .navigationTitle("This Device\u{2019}s Key")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { showKey = false } }
            }
            .presentationDetents([.medium])
        }
        .task {
            do {
                key = try SSHKeys.loadOrCreate()
            } catch {
                keyError = error.localizedDescription
            }
            model.snapshotDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("Snapshots")
            model.watchNetwork()
            connect()
        }
    }

    private var publicKey: String? {
        key.map { SSHKeys.openSSHPublicKey($0, comment: "diskindexer-\(UIDevice.current.name.filter { !$0.isWhitespace })") }
    }

    private var serverMenu: some View {
        Menu {
            Section("Connect To") {
                ForEach(store.servers) { s in
                    Toggle(isOn: Binding(get: { store.selectedID == s.id },
                                         set: { if $0 { store.selectedID = s.id; connect() } })) {
                        Label(s.name, systemImage: "server.rack")
                    }
                }
            }
            Button("Add Server\u{2026}", systemImage: "plus") {
                editing = Server(name: "", addresses: [""])
            }
            if let s = store.selected {
                Button("Edit \u{201C}\(s.name)\u{201D}\u{2026}", systemImage: "pencil") { editing = s }
                Button("Remove \u{201C}\(s.name)\u{201D}", systemImage: "trash", role: .destructive) {
                    store.remove(s)
                    connect()
                }
            }
            Divider()
            Button("This Device\u{2019}s Key\u{2026}", systemImage: "key") { showKey = true }
            Button("Reconnect", systemImage: "arrow.clockwise") { connect() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Image(systemName: "server.rack")
            }
        }
        .accessibilityIdentifier("servers.menu")
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: .green
        case .connecting, .waiting, .reconnecting: .yellow
        case .failed: .red
        case .disconnected: .gray
        }
    }

    private func connect() {
        guard let key, let server = store.selected, !server.parsed.isEmpty else {
            model.disconnect()
            return
        }
        let transport = SSHChannelTransport(
            name: server.name, addresses: server.parsed, key: key,
            hostKeys: DefaultsHostKeyStore(),
            socketPath: server.socketPath.trimmingCharacters(in: .whitespaces))
        model.connect(transport, cacheKey: server.id.uuidString)
    }
}

/// First launch: what the app needs before it can connect.
struct Welcome: View {
    var publicKey: String?
    var keyError: String?
    var onAdd: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("""
                        DiskIndexer searches the disk indexes on a server running diskindexer, over SSH. \
                        Add this device\u{2019}s key to the server, then add the server.
                        """)
                }
                KeySection(publicKey: publicKey, error: keyError)
                Section {
                    Button("Add Server\u{2026}", action: onAdd)
                        .accessibilityIdentifier("welcome.addServer")
                }
            }
            .navigationTitle("DiskIndexer")
        }
    }
}

/// This device's public key, to put in the server's authorized_keys.
struct KeySection: View {
    var publicKey: String?
    var error: String?

    var body: some View {
        Section {
            if let publicKey {
                Text(publicKey)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Button("Copy Public Key", systemImage: "doc.on.doc") { copyToPasteboard(publicKey) }
                ShareLink(item: publicKey)
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        } header: {
            Text("This Device\u{2019}s Key")
        } footer: {
            Text("Add it as a line of ~/.ssh/authorized_keys on the server. The private key never leaves this device.")
        }
    }
}

/// Adds or edits a server.
struct ServerEditor: View {
    @State var server: Server
    var isNew: Bool
    var publicKey: String?
    var onDone: (Server?) -> Void

    private var addresses: [String] {
        server.addresses.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var invalid: [String] { addresses.filter { SSHAddress($0) == nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $server.name, prompt: Text("Home server"))
                }
                Section {
                    ForEach(server.addresses.indices, id: \.self) { i in
                        TextField("Address \(i + 1)", text: $server.addresses[i],
                                  prompt: Text(i == 0 ? "me@192.168.1.10" : "me@server.tailnet.ts.net"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityIdentifier("server.address.\(i)")
                    }
                    .onDelete { server.addresses.remove(atOffsets: $0) }
                    .onMove { server.addresses.move(fromOffsets: $0, toOffset: $1) }
                    Button("Add Address", systemImage: "plus") { server.addresses.append("") }
                } header: {
                    Text("Addresses")
                } footer: {
                    Text(invalid.isEmpty
                         ? "user@host, or user@host:port. Tried in order, so put the home network first and a Tailscale name after it."
                         : "Not user@host: \(invalid.joined(separator: ", "))")
                        .foregroundStyle(invalid.isEmpty ? Color.secondary : Color.red)
                }
                Section {
                    TextField("Socket path", text: $server.socketPath, prompt: Text(ServerLookup.defaultSocket))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Advanced")
                }
                if isNew {
                    KeySection(publicKey: publicKey)
                }
            }
            .navigationTitle(isNew ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        var s = server
                        s.addresses = addresses
                        if s.name.trimmingCharacters(in: .whitespaces).isEmpty {
                            s.name = SSHAddress(addresses[0])?.host ?? addresses[0]
                        }
                        onDone(s)
                    }
                    .disabled(addresses.isEmpty || !invalid.isEmpty)
                    .accessibilityIdentifier("server.save")
                }
            }
        }
    }
}
#else
// The package also builds for macOS (swift test); this target is iOS only.
@main
enum DiskIndexerIOSStub {
    static func main() {}
}
#endif
