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
    private var webKitWarmer: WKWebView?  // Keep alive briefly to complete warmup

    private init() {}

    func start(modelContext: ModelContext, isAuthenticated: Bool) {
        guard !didStart else { return }
        didStart = true

        // Stage 1: critical path (immediate, non-blocking)
        EmailCacheManager.shared.configure(with: modelContext, deferIndexRebuild: true)
        SnoozeManager.shared.configure(with: modelContext)
        OutboxManager.shared.configure(with: modelContext)
        NetworkMonitor.shared.start()

        // Stage 2: after first frame (defer heavy work)
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self else { return }
            await MainActor.run {
                self.prewarmWebKit()
            }
            if isAuthenticated {
                self.scheduleContactsPreloadIfNeeded(delaySeconds: 5)
            }
        }

        // Stage 3: background warmups (longer delay)
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(4))
            let accountEmail = await MainActor.run { AuthService.shared.currentAccount?.email.lowercased() }
            await SearchIndexManager.shared.prewarmIfNeeded(accountEmail: accountEmail)
            await AccountWarmupCoordinator.shared.schedulePrewarmNext()
            startupLogger.info("Completed deferred warmups")
        }
    }

    func handleAuthChanged(isAuthenticated: Bool) {
        if isAuthenticated {
            scheduleContactsPreloadIfNeeded(delaySeconds: 5)
        }
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
