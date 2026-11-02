import DiskIndexerKit
import Foundation
import Observation

struct RemoteConnection: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// Ways to reach the server, tried in order: e.g. its LAN address first,
    /// then its Tailscale name. Each is anything ssh accepts (an
    /// ~/.ssh/config alias, host, IP, or user@host).
    var hosts: [String]
    /// Remote socket path; empty means the server default.
    var socketPath: String = ""

    init(id: UUID = UUID(), name: String, hosts: [String], socketPath: String = "") {
        self.id = id
        self.name = name
        self.hosts = hosts
        self.socketPath = socketPath
    }

    /// The addresses with blanks removed.
    var addresses: [String] {
        hosts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey { case id, name, hosts, host, socketPath }

    // Entries saved before multiple addresses had a single "host".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        if let hosts = try c.decodeIfPresent([String].self, forKey: .hosts) {
            self.hosts = hosts
        } else {
            hosts = [try c.decode(String.self, forKey: .host)]
        }
        socketPath = try c.decodeIfPresent(String.self, forKey: .socketPath) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(hosts, forKey: .hosts)
        try c.encode(socketPath, forKey: .socketPath)
    }
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
            return SSHTunnel(name: r.name, hosts: r.addresses, socketPath: r.socketPath)
        }
        return LocalBackend()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(remotes) {
            UserDefaults.standard.set(data, forKey: "remotes")
        }
    }
}
