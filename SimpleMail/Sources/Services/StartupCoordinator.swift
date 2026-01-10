import Foundation
import SwiftData
import OSLog

private let startupLogger = Logger(subsystem: "com.simplemail.app", category: "StartupCoordinator")

@MainActor
final class StartupCoordinator {
    static let shared = StartupCoordinator()

    private var didConfigureCaches = false
    private var didScheduleDeferred = false

    private init() {}

    /// Configure SwiftData-backed caches. Call this as early as possible (e.g., SimpleMailApp.init())
    /// so that InboxViewModel can preload cached emails immediately.
    func configureCachesIfNeeded(modelContext: ModelContext, container: ModelContainer) {
        guard !didConfigureCaches else { return }
        didConfigureCaches = true

        startupLogger.info("StartupCoordinator.configureCachesIfNeeded start")

        EmailCacheManager.shared.configure(with: modelContext, container: container, deferIndexRebuild: true)
        SnoozeManager.shared.configure(with: modelContext)
        OutboxManager.shared.configure(with: modelContext)
        NetworkMonitor.shared.start()

        startupLogger.info("StartupCoordinator.configureCachesIfNeeded end")
    }

    /// Schedule deferred work (search index prewarm) once auth state is known.
    /// Safe to call multiple times - will only schedule once.
    func scheduleDeferredWorkIfNeeded(isAuthenticated: Bool) {
        guard isAuthenticated else { return }
        guard !didScheduleDeferred else { return }
        didScheduleDeferred = true

        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(5))

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
