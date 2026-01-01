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

    private init() {}

    // MARK: - Registration

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: syncTaskIdentifier,
            using: nil
        ) { task in
            self.handleSyncTask(task as! BGAppRefreshTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: notificationTaskIdentifier,
            using: nil
        ) { task in
            self.handleNotificationTask(task as! BGProcessingTask)
        }
    }

    // MARK: - Schedule Tasks

    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: syncTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled sync task")
        } catch {
            logger.error("Failed to schedule sync: \(error.localizedDescription)")
        }
    }

    func scheduleNotificationCheck() {
        let request = BGProcessingTaskRequest(identifier: notificationTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60) // 5 minutes
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled notification check")
        } catch {
            logger.error("Failed to schedule notification check: \(error.localizedDescription)")
        }
    }

    // MARK: - Handle Tasks

    private func handleSyncTask(_ task: BGAppRefreshTask) {
        scheduleBackgroundSync() // Schedule next sync

        let syncTask = Task {
            do {
                try await performSync()
                task.setTaskCompleted(success: true)
            } catch {
                logger.error("Sync failed: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            syncTask.cancel()
        }
    }

    private func handleNotificationTask(_ task: BGProcessingTask) {
        scheduleNotificationCheck() // Schedule next check

        let notificationTask = Task {
            do {
                try await checkForNewEmails()
                task.setTaskCompleted(success: true)
            } catch {
                logger.error("Notification check failed: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            notificationTask.cancel()
        }
    }

    // MARK: - Sync Logic

    private func performSync() async throws {
        guard await AuthService.shared.isAuthenticated else {
            return
        }

        // Fetch latest emails
        let (emails, _) = try await GmailService.shared.fetchInbox(maxResults: 50)

        // Update local cache (SwiftData)
        await MainActor.run {
            EmailCacheManager.shared.cacheEmails(emails)
        }

        logger.info("Synced \(emails.count) emails to cache")
    }

    private func checkForNewEmails() async throws {
        guard await AuthService.shared.isAuthenticated else {
            return
        }

        // Load settings
        let settings = loadSettings()
        guard settings.notificationsEnabled else { return }

        // Check for new unread emails
        let (emails, _) = try await GmailService.shared.fetchInbox(
            query: "is:unread",
            maxResults: 10
        )

        let vipSenders = Set(UserDefaults.standard.stringArray(forKey: "vipSenders") ?? [])

        let newEmails = emails.filter { email in
            // Check if we've already notified for this email
            !UserDefaults.standard.bool(forKey: "notified_\(email.id)")
        }

        for email in newEmails {
            let isVIP = vipSenders.contains(email.senderEmail.lowercased())

            // Check notification preferences
            if isVIP && settings.notifyVIPSenders {
                await sendNotification(for: email, isVIP: true)
                UserDefaults.standard.set(true, forKey: "notified_\(email.id)")
            } else if settings.notifyNewEmails {
                await sendNotification(for: email, isVIP: false)
                UserDefaults.standard.set(true, forKey: "notified_\(email.id)")
            }
        }
    }

    private func loadSettings() -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: "appSettings"),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings
        }
        return AppSettings()
    }

    // MARK: - Notifications

    private func sendNotification(for email: Email, isVIP: Bool = false) async {
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
            "isVIP": isVIP
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

        Task {
            switch response.actionIdentifier {
            case "ARCHIVE":
                try? await GmailService.shared.archive(messageId: emailId)

            case "MARK_READ":
                try? await GmailService.shared.markAsRead(messageId: emailId)

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
