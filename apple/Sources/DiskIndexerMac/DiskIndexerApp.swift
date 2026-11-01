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
            return n == 1 ? "1 disk" : "\(n) disks"
        case .connecting: return "Connecting…"
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
                onEdit(RemoteConnection(name: "", host: ""))
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
        case .connecting, .reconnecting: .yellow
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
                    TextField("SSH host", text: $remote.host, prompt: Text("enterprise or user@example.com"))
                    TextField("Socket path", text: $remote.socketPath, prompt: Text(SSHTunnel.defaultSocket))
                } footer: {
                    Text("""
                        The server must be running `diskindexer serve` (see `make install-service`). \
                        The app connects with /usr/bin/ssh using your ~/.ssh/config and ssh-agent, so \
                        run `ssh <host>` in Terminal once first to accept the host key.
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
                    r.host = r.host.trimmingCharacters(in: .whitespaces)
                    if r.name.trimmingCharacters(in: .whitespaces).isEmpty { r.name = r.host }
                    onDone(r)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(remote.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460)
    }
}
