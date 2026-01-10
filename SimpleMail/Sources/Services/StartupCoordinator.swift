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

        // Stage 1: critical path (do synchronously so caches are ready before UI work)
        EmailCacheManager.shared.configure(with: modelContext, deferIndexRebuild: true)
        SnoozeManager.shared.configure(with: modelContext)
        OutboxManager.shared.configure(with: modelContext)
        NetworkMonitor.shared.start()

        // Stage 2: warmups happen on-demand (first email open)
        prewarmWebKitIfNeeded()
        WKWebViewPool.shared.warm(count: 4)

        // Stage 3: Deferred search index warmup (after UI is responsive)
        // Use .utility priority and delay to avoid startup tax
        if isAuthenticated {
            Task.detached(priority: .utility) {
                // Wait for UI to settle before warming search index
                try? await Task.sleep(for: .seconds(2))

                // Cancellation guard: get current account AFTER sleep
                // (user may have logged out or switched accounts during delay)
                guard let currentAccount = await MainActor.run(body: {
                    AuthService.shared.currentAccount?.email
                }) else {
                    startupLogger.debug("Search prewarm skipped - no current account")
                    return
                }

                await SearchIndexManager.shared.prewarmIfNeeded(accountEmail: currentAccount)
                startupLogger.info("Search index prewarmed for current account")
            }
        }
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
