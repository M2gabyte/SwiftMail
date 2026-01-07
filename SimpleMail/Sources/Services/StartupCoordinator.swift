import Foundation
import SwiftData
import OSLog

private let startupLogger = Logger(subsystem: "com.simplemail.app", category: "StartupCoordinator")

@MainActor
final class StartupCoordinator {
    static let shared = StartupCoordinator()

    private var didStart = false
    private var didPreloadContacts = false

    private init() {}

    func start(modelContext: ModelContext, isAuthenticated: Bool) {
        guard !didStart else { return }
        didStart = true

        // Stage 1: critical path (immediate, non-blocking)
        EmailCacheManager.shared.configure(with: modelContext, deferIndexRebuild: true)
        SnoozeManager.shared.configure(with: modelContext)
        OutboxManager.shared.configure(with: modelContext)
        NetworkMonitor.shared.start()

        // Stage 2: after first frame (short delay)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if isAuthenticated {
                await preloadContactsIfNeeded()
            }
        }

        // Stage 3: background warmups (longer delay)
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(2))
            let accountEmail = await MainActor.run { AuthService.shared.currentAccount?.email.lowercased() }
            await SearchIndexManager.shared.prewarmIfNeeded(accountEmail: accountEmail)
            await AccountWarmupCoordinator.shared.schedulePrewarmNext()
            startupLogger.info("Completed deferred warmups")
        }
    }

    func handleAuthChanged(isAuthenticated: Bool) {
        if isAuthenticated {
            Task { @MainActor in
                await preloadContactsIfNeeded()
            }
        }
    }

    private func preloadContactsIfNeeded() async {
        guard !didPreloadContacts else { return }
        didPreloadContacts = true
        await PeopleService.shared.preloadContacts()
    }
}
