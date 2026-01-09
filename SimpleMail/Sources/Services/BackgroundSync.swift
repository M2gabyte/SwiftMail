import Foundation
import BackgroundTasks
import UserNotifications
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.simplemail.app", category: "BackgroundSync")

// MARK: - Background Sync Manager

final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()

    private let syncTaskIdentifier = "com.simplemail.app.sync"
    private let notificationTaskIdentifier = "com.simplemail.app.notification"
    private let summaryTaskIdentifier = "com.simplemail.app.summaries"
    private let outboxTaskIdentifier = "com.simplemail.app.outbox"

    private init() {}

    // MARK: - Registration

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: syncTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                logger.error("Unexpected task type for sync task")
                task.setTaskCompleted(success: false)
                return
            }
            self.handleSyncTask(refreshTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: notificationTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                logger.error("Unexpected task type for notification task")
                task.setTaskCompleted(success: false)
                return
            }
            self.handleNotificationTask(processingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: summaryTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                logger.error("Unexpected task type for summary task")
                task.setTaskCompleted(success: false)
                return
            }
            self.handleSummaryTask(processingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: outboxTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                logger.error("Unexpected task type for outbox task")
                task.setTaskCompleted(success: false)
                return
            }
            self.handleOutboxTask(processingTask)
        }
    }

    // MARK: - Schedule Tasks

    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: syncTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeoutConfig.backgroundSyncInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled sync task")
        } catch {
            logger.error("Failed to schedule sync: \(error.localizedDescription)")
        }
    }

    func scheduleNotificationCheck() {
        let request = BGProcessingTaskRequest(identifier: notificationTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeoutConfig.notificationCheckInterval)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled notification check")
        } catch {
            logger.error("Failed to schedule notification check: \(error.localizedDescription)")
        }
    }

    func scheduleSummaryProcessingIfNeeded() {
        Task {
            let shouldRun = await shouldRunAggressiveSummaryProcessing()
            if shouldRun {
                scheduleSummaryProcessing()
            } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: summaryTaskIdentifier)
            }
        }
    }

    private func scheduleSummaryProcessing() {
        let request = BGProcessingTaskRequest(identifier: summaryTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeoutConfig.summaryProcessingInterval)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled summary processing task")
        } catch {
            logger.error("Failed to schedule summary processing: \(error.localizedDescription)")
        }
    }

    /// Schedule outbox processing when there are pending emails
    func scheduleOutboxProcessing() {
        Task { @MainActor in
            guard OutboxManager.shared.pendingCount > 0 else {
                return
            }

            let request = BGProcessingTaskRequest(identifier: outboxTaskIdentifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 60) // Try in 1 minute
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false

            do {
                try BGTaskScheduler.shared.submit(request)
                logger.info("Scheduled outbox processing task")
            } catch {
                logger.error("Failed to schedule outbox processing: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Handle Tasks

    private func handleSyncTask(_ task: BGAppRefreshTask) {
        scheduleBackgroundSync() // Schedule next sync

        let syncTask = Task {
            do {
                try await performSync()
                task.setTaskCompleted(success: true)
            } catch is CancellationError {
                logger.info("Sync task was cancelled due to expiration")
                task.setTaskCompleted(success: false)
            } catch {
                logger.error("Sync failed: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            logger.warning("Sync task expiring - cancelling work")
            syncTask.cancel()
        }
    }

    private func handleNotificationTask(_ task: BGProcessingTask) {
        scheduleNotificationCheck() // Schedule next check

        let notificationTask = Task {
            do {
                try await checkForNewEmails()
                task.setTaskCompleted(success: true)
            } catch is CancellationError {
                logger.info("Notification task was cancelled due to expiration")
                task.setTaskCompleted(success: false)
            } catch {
                logger.error("Notification check failed: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            logger.warning("Notification task expiring - cancelling work")
            notificationTask.cancel()
        }
    }

    private func handleSummaryTask(_ task: BGProcessingTask) {
        scheduleSummaryProcessing() // Schedule next processing

        let summaryTask = Task {
            do {
                let shouldRun = await shouldRunAggressiveSummaryProcessing()
                guard shouldRun else {
                    task.setTaskCompleted(success: true)
                    return
                }
                try await processSummaryQueue()
                task.setTaskCompleted(success: true)
            } catch is CancellationError {
                logger.info("Summary task was cancelled due to expiration")
                task.setTaskCompleted(success: false)
            } catch {
                logger.error("Summary processing failed: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            logger.warning("Summary task expiring - cancelling work")
            summaryTask.cancel()
        }
    }

    private func handleOutboxTask(_ task: BGProcessingTask) {
        let outboxTask = Task { @MainActor in
            await OutboxManager.shared.processQueue()

            // If there are still pending emails, schedule another attempt
            if OutboxManager.shared.pendingCount > 0 {
                scheduleOutboxProcessing()
            }

            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            logger.warning("Outbox task expiring - cancelling work")
            outboxTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    // MARK: - Sync Logic

    private func performSync() async throws {
        let isAuthenticated = await MainActor.run { AuthService.shared.isAuthenticated }
        guard isAuthenticated else {
            return
        }

        // Check for cancellation before network call
        try Task.checkCancellation()

        let accounts = await MainActor.run { AuthService.shared.accounts }
        guard !accounts.isEmpty else { return }

        for account in accounts {
            if Task.isCancelled { break }
            let result = try await syncAccount(account)

            // Check for cancellation before cache update
            try Task.checkCancellation()

            if !result.emails.isEmpty {
                await EmailCacheManager.shared.cacheEmails(result.emails, isFullInboxFetch: result.isFullSync)
            }
            if !result.deletedIds.isEmpty {
                await EmailCacheManager.shared.deleteEmails(ids: result.deletedIds, accountEmail: account.email)
            }

            logger.info("Synced \(result.emails.count) emails (\(result.deletedIds.count) deleted) for \(account.email)")

            let emailModels = result.emails.map(Email.init(dto:))
            let summaryCandidates = emailModels.compactMap { email -> SummaryQueue.Candidate? in
                guard let accountEmail = email.accountEmail else { return nil }
                return SummaryQueue.Candidate(
                    emailId: email.id,
                    threadId: email.threadId,
                    accountEmail: accountEmail,
                    subject: email.subject,
                    from: email.from,
                    snippet: email.snippet,
                    date: email.date,
                    isUnread: email.isUnread,
                    isStarred: email.isStarred,
                    listUnsubscribe: email.listUnsubscribe
                )
            }
            await SummaryQueue.shared.enqueueCandidates(summaryCandidates)

            let prefetchCandidates = emailModels.compactMap { email -> BodyPrefetchQueue.Candidate? in
                guard let accountEmail = email.accountEmail else { return nil }
                return BodyPrefetchQueue.Candidate(
                    emailId: email.id,
                    threadId: email.threadId,
                    accountEmail: accountEmail,
                    date: email.date,
                    isUnread: email.isUnread,
                    isStarred: email.isStarred,
                    listUnsubscribe: email.listUnsubscribe
                )
            }
            await BodyPrefetchQueue.shared.enqueueCandidates(prefetchCandidates)
        }
    }

    private struct SyncResult {
        let emails: [EmailDTO]
        let deletedIds: [String]
        let isFullSync: Bool
    }

    private func syncAccount(_ account: AuthService.Account) async throws -> SyncResult {
        let accountEmail = account.email.lowercased()
        let lastHistoryId = await MainActor.run {
            AccountDefaults.string(for: "gmailHistoryId", accountEmail: accountEmail)
        }

        if let lastHistoryId {
            do {
                let delta = try await fetchHistoryDelta(for: account, startHistoryId: lastHistoryId)
                if let newHistoryId = delta.historyId {
                    await MainActor.run {
                        AccountDefaults.setString(newHistoryId, for: "gmailHistoryId", accountEmail: accountEmail)
                    }
                }
                return SyncResult(
                    emails: delta.changedEmails,
                    deletedIds: delta.deletedIds,
                    isFullSync: false
                )
            } catch let error as GmailError {
                if case .notFound = error {
                    logger.warning("HistoryId invalid for \(accountEmail). Falling back to full sync.")
                } else {
                    throw error
                }
            }
        }

        let (emails, _) = try await GmailService.shared.fetchInbox(
            for: account,
            maxResults: 50
        )
        if let profile = try? await GmailService.shared.getProfile(for: account) {
            await MainActor.run {
                AccountDefaults.setString(profile.historyId, for: "gmailHistoryId", accountEmail: accountEmail)
            }
        }
        return SyncResult(emails: emails, deletedIds: [], isFullSync: true)
    }

    private struct HistoryDelta {
        let changedEmails: [EmailDTO]
        let deletedIds: [String]
        let historyId: String?
    }

    private func fetchHistoryDelta(
        for account: AuthService.Account,
        startHistoryId: String
    ) async throws -> HistoryDelta {
        var historyRecords: [HistoryRecord] = []
        var pageToken: String?
        var newestHistoryId: String?

        repeat {
            let response = try await GmailService.shared.getHistory(
                for: account,
                startHistoryId: startHistoryId,
                pageToken: pageToken
            )
            if let history = response.history {
                historyRecords.append(contentsOf: history)
            }
            if newestHistoryId == nil {
                newestHistoryId = response.historyId
            } else if let responseHistory = response.historyId {
                newestHistoryId = responseHistory
            }
            pageToken = response.nextPageToken
        } while pageToken != nil

        let (addedIds, deletedIds, labelChangedIds) = collectHistoryMessageIds(historyRecords)
        let changedIds = Array(addedIds.union(labelChangedIds))

        let changedEmails = try await GmailService.shared.fetchEmails(
            messageIds: changedIds,
            for: account
        )

        return HistoryDelta(
            changedEmails: changedEmails,
            deletedIds: Array(deletedIds),
            historyId: newestHistoryId
        )
    }

    private func collectHistoryMessageIds(
        _ records: [HistoryRecord]
    ) -> (added: Set<String>, deleted: Set<String>, labelChanged: Set<String>) {
        var added: Set<String> = []
        var deleted: Set<String> = []
        var labelChanged: Set<String> = []

        for record in records {
            if let additions = record.messagesAdded {
                for item in additions {
                    added.insert(item.message.id)
                }
            }
            if let deletions = record.messagesDeleted {
                for item in deletions {
                    deleted.insert(item.message.id)
                }
            }
            if let labelAdds = record.labelsAdded {
                for item in labelAdds {
                    labelChanged.insert(item.message.id)
                }
            }
            if let labelRemovals = record.labelsRemoved {
                for item in labelRemovals {
                    labelChanged.insert(item.message.id)
                }
            }
        }

        // If deleted, don't refetch.
        labelChanged.subtract(deleted)
        added.subtract(deleted)

        return (added, deleted, labelChanged)
    }

    private func processSummaryQueue() async throws {
        let isAuthenticated = await MainActor.run { AuthService.shared.isAuthenticated }
        guard isAuthenticated else { return }

        // Check for cancellation before processing
        try Task.checkCancellation()

        let accounts = await MainActor.run { AuthService.shared.accounts }
        guard !accounts.isEmpty else { return }

        for account in accounts {
            if Task.isCancelled { break }
            let summaryCandidates = await MainActor.run {
                EmailCacheManager.shared.loadCachedEmails(
                    mailbox: .inbox,
                    limit: 100,
                    accountEmail: account.email
                ).compactMap { email -> SummaryQueue.Candidate? in
                    guard let accountEmail = email.accountEmail else { return nil }
                    return SummaryQueue.Candidate(
                        emailId: email.id,
                        threadId: email.threadId,
                        accountEmail: accountEmail,
                        subject: email.subject,
                        from: email.from,
                        snippet: email.snippet,
                        date: email.date,
                        isUnread: email.isUnread,
                        isStarred: email.isStarred,
                        listUnsubscribe: email.listUnsubscribe
                    )
                }
            }
            await SummaryQueue.shared.enqueueCandidates(summaryCandidates)
        }
    }

    private func checkForNewEmails() async throws {
        let isAuthenticated = await MainActor.run { AuthService.shared.isAuthenticated }
        guard isAuthenticated else {
            return
        }

        // Check for cancellation before processing
        try Task.checkCancellation()

        // Process scheduled sends
        await ScheduledSendManager.shared.processDueSends()

        // Process offline outbox queue
        await OutboxManager.shared.processQueue()

        // Check for cancellation after scheduled sends
        try Task.checkCancellation()

        // Prune old notification keys periodically
        pruneNotificationKeys()

        let accounts = await MainActor.run { AuthService.shared.accounts }
        guard !accounts.isEmpty else { return }

        for account in accounts {
            if Task.isCancelled { break }
            let (emails, _) = try await GmailService.shared.fetchInbox(
                for: account,
                query: "is:unread",
                maxResults: 10
            )

            // Check for cancellation before processing notifications
            try Task.checkCancellation()

            var newEmails: [EmailDTO] = []
            for email in emails {
                let alreadyNotified = await MainActor.run {
                    AccountDefaults.bool(for: "notified_\(email.id)", accountEmail: email.accountEmail)
                }
                if !alreadyNotified {
                    newEmails.append(email)
                }
            }

            for email in newEmails {
                // Check for cancellation in the loop
                if Task.isCancelled { break }

                let accountEmail = email.accountEmail
                let settings = await loadSettings(accountEmail: accountEmail)
                guard settings.notificationsEnabled else { continue }

                let vipSenders = await MainActor.run {
                    Set(AccountDefaults.stringArray(for: "vipSenders", accountEmail: accountEmail))
                }
                let isVIP = vipSenders.contains(email.senderEmail.lowercased())

                // Check notification preferences
                if isVIP && settings.notifyVIPSenders {
                    await sendNotification(for: email, isVIP: true)
                    await MainActor.run {
                        AccountDefaults.setBool(true, for: "notified_\(email.id)", accountEmail: email.accountEmail)
                    }
                } else if settings.notifyNewEmails {
                    await sendNotification(for: email, isVIP: false)
                    await MainActor.run {
                        AccountDefaults.setBool(true, for: "notified_\(email.id)", accountEmail: email.accountEmail)
                    }
                }
            }
        }
    }

    private func loadSettings(accountEmail: String?) async -> AppSettings {
        let data = await MainActor.run {
            AccountDefaults.data(for: "appSettings", accountEmail: accountEmail)
        }
        guard let data else {
            return AppSettings()
        }

        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            logger.error("Failed to decode app settings: \(error.localizedDescription)")
            return AppSettings()
        }
    }

    private func shouldRunAggressiveSummaryProcessing() async -> Bool {
        let accounts = await MainActor.run { AuthService.shared.accounts }
        if accounts.isEmpty {
            let settings = await loadSettings(accountEmail: nil)
            return settings.precomputeSummaries && settings.backgroundSummaryProcessing
        }

        for account in accounts {
            let settings = await loadSettings(accountEmail: account.email)
            if settings.precomputeSummaries && settings.backgroundSummaryProcessing {
                return true
            }
        }
        return false
    }

    // MARK: - Notification Key Pruning

    /// Prune old notification de-dupe keys to prevent unbounded UserDefaults growth
    /// Called during background sync to clean up keys older than 7 days
    private func pruneNotificationKeys() {
        let defaults = UserDefaults.standard
        let now = Date()
        let maxAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days

        // Get all keys
        let allKeys = defaults.dictionaryRepresentation().keys

        // Track notification keys with timestamps
        let notificationKeysKey = "notificationKeyTimestamps"
        var timestamps = defaults.dictionary(forKey: notificationKeysKey) as? [String: Double] ?? [:]

        // Find notification keys
        for key in allKeys where key.hasPrefix("notified_") {
            // If we don't have a timestamp for this key, add one
            if timestamps[key] == nil {
                timestamps[key] = now.timeIntervalSince1970
            }
        }

        // Remove old keys
        var keysToRemove: [String] = []
        for (key, timestamp) in timestamps {
            let age = now.timeIntervalSince1970 - timestamp
            if age > maxAge {
                defaults.removeObject(forKey: key)
                keysToRemove.append(key)
            }
        }

        // Update timestamps dictionary
        for key in keysToRemove {
            timestamps.removeValue(forKey: key)
        }
        defaults.set(timestamps, forKey: notificationKeysKey)

        if !keysToRemove.isEmpty {
            logger.info("Pruned \(keysToRemove.count) old notification keys")
        }
    }

    // MARK: - Notifications

    private func sendNotification(for email: EmailDTO, isVIP: Bool = false) async {
        let content = UNMutableNotificationContent()

        if isVIP {
            content.title = "⭐ \(email.senderName)"
            content.interruptionLevel = .timeSensitive
        } else {
            content.title = email.senderName
        }

        content.subtitle = email.subject
        content.body = email.snippet
        content.sound = isVIP ? .defaultCritical : .default
        content.badge = 1

        // Add category for actions
        content.categoryIdentifier = "EMAIL"

        // Add user info for handling taps
        content.userInfo = [
            "emailId": email.id,
            "threadId": email.threadId,
            "isVIP": isVIP,
            "accountEmail": email.accountEmail ?? ""
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "email_\(email.id)",
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.info("Sent \(isVIP ? "VIP " : "")notification for: \(email.subject)")
        } catch {
            logger.error("Failed to send notification: \(error.localizedDescription)")
        }
    }

    // MARK: - Notification Setup

    @discardableResult
    func requestNotificationPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])

            if granted {
                await setupNotificationCategories()
            }

            return granted
        } catch {
            logger.error("Notification permission error: \(error.localizedDescription)")
            return false
        }
    }

    private func setupNotificationCategories() async {
        let archiveAction = UNNotificationAction(
            identifier: "ARCHIVE",
            title: "Archive",
            options: []
        )

        let replyAction = UNNotificationAction(
            identifier: "REPLY",
            title: "Reply",
            options: [.foreground]
        )

        let markReadAction = UNNotificationAction(
            identifier: "MARK_READ",
            title: "Mark as Read",
            options: []
        )

        let emailCategory = UNNotificationCategory(
            identifier: "EMAIL",
            actions: [archiveAction, replyAction, markReadAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([emailCategory])
    }
}

// MARK: - Notification Handler

final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        guard let emailId = userInfo["emailId"] as? String else {
            completionHandler()
            return
        }

        let accountEmail = (userInfo["accountEmail"] as? String)?.lowercased()

        Task { @MainActor in
            let account = AuthService.shared.accounts.first { $0.email.lowercased() == accountEmail }

            switch response.actionIdentifier {
            case "ARCHIVE":
                do {
                    if let account {
                        try await GmailService.shared.archive(messageId: emailId, account: account)
                    } else {
                        try await GmailService.shared.archive(messageId: emailId)
                    }
                } catch {
                    logger.error("Failed to archive from notification: \(error.localizedDescription)")
                }

            case "MARK_READ":
                do {
                    if let account {
                        try await GmailService.shared.markAsRead(messageId: emailId, account: account)
                    } else {
                        try await GmailService.shared.markAsRead(messageId: emailId)
                    }
                } catch {
                    logger.error("Failed to mark as read from notification: \(error.localizedDescription)")
                }

            case "REPLY":
                // This would navigate to compose screen
                // Handled by the app delegate or scene delegate
                break

            case UNNotificationDefaultActionIdentifier:
                // Tap on notification - navigate to email
                // Post notification to open email detail
                NotificationCenter.default.post(
                    name: .openEmail,
                    object: nil,
                    userInfo: userInfo
                )

            default:
                break
            }

            completionHandler()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openEmail = Notification.Name("openEmail")
}
