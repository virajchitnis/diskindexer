import Foundation
import Network

/// Calls `onChange` when the device's network changes: an interface comes or
/// goes (Wi-Fi, Ethernet, a VPN such as Tailscale) or connectivity is lost or
/// regained. The first report, which only describes the current network, is
/// skipped.
final class NetworkWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private var last: String?

    init(onChange: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = Self.signature(status: "\(path.status)", interfaces: path.availableInterfaces.map(\.name))
            defer { self.last = signature }
            if let last = self.last, last != signature { onChange() }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkWatcher"))
    }

    deinit { monitor.cancel() }

    static func signature(status: String, interfaces: [String]) -> String {
        status + ":" + interfaces.sorted().joined(separator: ",")
    }
}
