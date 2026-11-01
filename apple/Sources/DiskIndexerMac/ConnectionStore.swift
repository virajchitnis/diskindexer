import DiskIndexerKit
import Foundation
import Observation

struct RemoteConnection: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// Anything ssh accepts: an ~/.ssh/config alias, host, or user@host.
    var host: String
    /// Remote socket path; empty means the server default.
    var socketPath: String = ""
}

/// The saved remote servers and which connection is active, in UserDefaults.
@MainActor
@Observable
final class ConnectionStore {
    static let localID = "local"

    private(set) var remotes: [RemoteConnection] = []
    var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedConnection") }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "remotes"),
           let saved = try? JSONDecoder().decode([RemoteConnection].self, from: data) {
            remotes = saved
        }
        selectedID = UserDefaults.standard.string(forKey: "selectedConnection") ?? Self.localID
        if selectedID != Self.localID && !remotes.contains(where: { $0.id.uuidString == selectedID }) {
            selectedID = Self.localID
        }
    }

    var selectedRemote: RemoteConnection? {
        remotes.first { $0.id.uuidString == selectedID }
    }

    var selectedName: String {
        selectedRemote?.name ?? "This Mac"
    }

    func add(_ r: RemoteConnection) {
        remotes.append(r)
        save()
    }

    func update(_ r: RemoteConnection) {
        guard let i = remotes.firstIndex(where: { $0.id == r.id }) else { return }
        remotes[i] = r
        save()
    }

    func remove(_ r: RemoteConnection) {
        remotes.removeAll { $0.id == r.id }
        if selectedID == r.id.uuidString { selectedID = Self.localID }
        save()
    }

    func makeTransport() -> Transport {
        if let r = selectedRemote {
            return SSHTunnel(name: r.name, host: r.host, socketPath: r.socketPath)
        }
        return LocalBackend()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(remotes) {
            UserDefaults.standard.set(data, forKey: "remotes")
        }
    }
}
