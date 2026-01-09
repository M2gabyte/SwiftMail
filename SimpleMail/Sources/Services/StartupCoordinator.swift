import Foundation
import SwiftData
import WebKit
import OSLog

private let startupLogger = Logger(subsystem: "com.simplemail.app", category: "StartupCoordinator")

@MainActor
final class StartupCoordinator {
    static let shared = StartupCoordinator()

    private var didStart = false
    private var didPreloadContacts = false
    private var didPrewarmWebKit = false
    private var webKitWarmer: WKWebView?  // Keep alive briefly to complete warmup

    private init() {}

    func start(modelContext: ModelContext, isAuthenticated: Bool) {
        guard !didStart else { return }
        didStart = true

        // Stage 1: critical path (off main where possible)
        Task.detached(priority: .userInitiated) { @MainActor in
            EmailCacheManager.shared.configure(with: modelContext, deferIndexRebuild: true)
            SnoozeManager.shared.configure(with: modelContext)
            OutboxManager.shared.configure(with: modelContext)
            NetworkMonitor.shared.start()
        }

        // Stage 2: warmups happen on-demand (first email open)

        // Stage 3: disabled for now to avoid background hitches
    }

    func handleAuthChanged(isAuthenticated: Bool) {
        if isAuthenticated { }
    }

    func prewarmWebKitIfNeeded() {
        guard !didPrewarmWebKit else { return }
        didPrewarmWebKit = true
        prewarmWebKit()
    }

    private func scheduleContactsPreloadIfNeeded(delaySeconds: Double) {
        guard !didPreloadContacts else { return }
        didPreloadContacts = true
        Task.detached(priority: .background) {
            if delaySeconds > 0 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
            await PeopleService.shared.preloadContacts()
        }
    }

    /// Pre-warm WebKit by creating a WKWebView and loading minimal content.
    /// This triggers GPU, WebContent, and Networking process launches early,
    /// so the first email opens instantly instead of waiting 2+ seconds.
    private func prewarmWebKit() {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        webKitWarmer = webView

        // Release after processes have launched (1 second should be enough)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            self.webKitWarmer = nil
        }
    }
}
