import Foundation
import Network

/// Monitors network connectivity state using NWPathMonitor
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isConnected: Bool = true
    private(set) var connectionType: ConnectionType = .unknown

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.simplemail.networkmonitor")
    private var isMonitoring = false

    enum ConnectionType: String {
        case wifi
        case cellular
        case wired
        case unknown
    }

    private init() {}

    /// Start monitoring network connectivity
    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }

                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied

                // Determine connection type
                if path.usesInterfaceType(.wifi) {
                    self.connectionType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = .cellular
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionType = .wired
                } else {
                    self.connectionType = .unknown
                }

                // Post notification when connectivity changes
                if wasConnected != self.isConnected {
                    NotificationCenter.default.post(
                        name: .networkConnectivityChanged,
                        object: nil,
                        userInfo: ["isConnected": self.isConnected]
                    )

                    // Trigger outbox processing when coming back online
                    if self.isConnected {
                        Task {
                            await OutboxManager.shared.processQueue()
                        }
                    }
                }
            }
        }

        monitor.start(queue: queue)
    }

    /// Stop monitoring network connectivity
    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitor.cancel()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let networkConnectivityChanged = Notification.Name("networkConnectivityChanged")
}
