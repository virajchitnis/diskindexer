import AppKit
import DiskIndexerKit
import SwiftUI

@main
struct DiskIndexerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    @State private var store = ConnectionStore()

    var body: some Scene {
        Window("DiskIndexer", id: "main") {
            ContentView(model: model, store: store)
                // Tall enough for the Index Disk sheet's buttons to stay visible.
                .frame(minWidth: 760, minHeight: 560)
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than
        // from the .app bundle, so the app gets a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Stops the local server child and any SSH tunnel.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.disconnect() }
    }
}

struct ContentView: View {
    var model: AppModel
    var store: ConnectionStore
    @State private var editing: RemoteConnection?

    var body: some View {
        BrowserView(model: model)
            .navigationTitle(store.selectedName)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ConnectionMenu(model: model, store: store, onEdit: { editing = $0 }, onSelect: connect)
                }
            }
            .sheet(item: $editing) { remote in
                RemoteEditor(remote: remote, isNew: !store.remotes.contains { $0.id == remote.id }) { saved in
                    editing = nil
                    guard let saved else { return }
                    if store.remotes.contains(where: { $0.id == saved.id }) {
                        store.update(saved)
                    } else {
                        store.add(saved)
                    }
                    connect(saved.id.uuidString)
                }
            }
            .onAppear {
                model.pickLocalFolder = pickFolder
                if model.status == .disconnected { connect(store.selectedID) }
            }
    }

    private var subtitle: String {
        switch model.status {
        case .connected:
            let n = model.diskNodes.count
            let disks = n == 1 ? "1 disk" : "\(n) disks"
            // Which address is in use, when a server has several.
            if let r = store.selectedRemote, r.addresses.count > 1, let via = model.transport?.activeAddress {
                return "\(disks) \u{00B7} via \(via)"
            }
            return disks
        case .connecting: return "Connecting…"
        case .waiting: return "Waiting for connection…"
        case .reconnecting: return "Reconnecting…"
        case .failed: return "Not connected"
        case .disconnected: return ""
        }
    }

    private func connect(_ id: String) {
        store.selectedID = id
        model.connect(store.makeTransport())
    }

    private func pickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

struct ConnectionMenu: View {
    var model: AppModel
    var store: ConnectionStore
    var onEdit: (RemoteConnection) -> Void
    var onSelect: (String) -> Void

    var body: some View {
        Menu {
            Section("Connect To") {
                Toggle(isOn: binding(ConnectionStore.localID)) {
                    Label("This Mac", systemImage: "laptopcomputer")
                }
                ForEach(store.remotes) { r in
                    Toggle(isOn: binding(r.id.uuidString)) {
                        Label(r.name, systemImage: "server.rack")
                    }
                }
            }
            Divider()
            Button("Add Server…") {
                onEdit(RemoteConnection(name: "", hosts: [""]))
            }
            if let r = store.selectedRemote {
                Button("Edit \"\(r.name)\"…") { onEdit(r) }
                Button("Remove \"\(r.name)\"") {
                    store.remove(r)
                    onSelect(ConnectionStore.localID)
                }
            }
            Divider()
            Button("Reconnect") { onSelect(store.selectedID) }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Image(systemName: store.selectedRemote == nil ? "laptopcomputer" : "server.rack")
            }
        }
        .help("Connection: \(store.selectedName)")
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { store.selectedID == id }, set: { if $0 { onSelect(id) } })
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: .green
        case .connecting, .waiting, .reconnecting: .yellow
        case .failed: .red
        case .disconnected: .gray
        }
    }
}

struct RemoteEditor: View {
    @State var remote: RemoteConnection
    var isNew: Bool
    var onDone: (RemoteConnection?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $remote.name, prompt: Text("Home server"))
                    TextField("Socket path", text: $remote.socketPath, prompt: Text(SSHTunnel.defaultSocket))
                }
                Section {
                    ForEach(remote.hosts.indices, id: \.self) { i in
                        HStack {
                            TextField("Address \(i + 1)", text: $remote.hosts[i],
                                      prompt: Text(i == 0 ? "192.168.1.10 or enterprise" : "enterprise.tailnet.ts.net"))
                                .labelsHidden()
                            Button {
                                remote.hosts.swapAt(i, i - 1)
                            } label: { Image(systemName: "arrow.up") }
                                .disabled(i == 0)
                                .help("Try this address earlier")
                            Button {
                                remote.hosts.remove(at: i)
                            } label: { Image(systemName: "minus.circle") }
                                .disabled(remote.hosts.count == 1)
                                .help("Remove this address")
                        }
                        .buttonStyle(.borderless)
                    }
                    Button("Add Address") { remote.hosts.append("") }
                } header: {
                    Text("Addresses")
                } footer: {
                    Text("""
                        Tried in order; the first that answers is used, and every reconnect starts again                         from the top. Put the home network address first and the Tailscale name after it                         to switch automatically. Each is anything ssh accepts: an ~/.ssh/config alias,                         a host name or IP, or user@host. The app uses your ~/.ssh/config and ssh-agent,                         so run `ssh <address>` in Terminal once first to accept each host key.
                        """)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add and Connect" : "Save and Connect") {
                    var r = remote
                    r.hosts = r.addresses
                    if r.name.trimmingCharacters(in: .whitespaces).isEmpty { r.name = r.hosts[0] }
                    onDone(r)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(remote.addresses.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 480)
    }
}
