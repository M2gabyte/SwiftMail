import Foundation
import SwiftData
import UserNotifications
import OSLog

// MARK: - Snooze Manager

private let logger = Logger(subsystem: "com.simplemail.app", category: "SnoozeManager")

@MainActor
@Observable
final class SnoozeManager {
    static let shared = SnoozeManager()

    var snoozedEmails: [SnoozedEmail] = []

    private var modelContext: ModelContext?
    private var checkTimer: Timer?

    private init() {
        startSnoozeCheck()
    }

    deinit {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    // MARK: - Configuration

    func configure(with context: ModelContext) {
        self.modelContext = context
        loadSnoozedEmails()
    }

    // MARK: - Load Snoozed Emails

    func loadSnoozedEmails() {
        guard let context = modelContext else {
            logger.warning("Cannot load snoozed emails: no model context")
            return
        }

        let descriptor = FetchDescriptor<SnoozedEmail>(
            sortBy: [SortDescriptor(\.snoozeUntil, order: .forward)]
        )

        do {
            snoozedEmails = try context.fetch(descriptor)
            logger.info("Loaded \(self.snoozedEmails.count) snoozed emails")
        } catch {
            logger.error("Failed to load snoozed emails: \(error.localizedDescription)")
        }
    }

    // MARK: - Snooze Email

    func snoozeEmail(_ email: Email, until date: Date) async {
        guard let context = modelContext else {
            logger.error("Cannot snooze email: no model context configured")
            return
        }

        let snoozed = SnoozedEmail(
            id: email.id,
            threadId: email.threadId,
            subject: email.subject,
            snippet: email.snippet,
            from: email.from,
            date: email.date,
            snoozeUntil: date
        )

        context.insert(snoozed)

        do {
            try context.save()
            snoozedEmails.append(snoozed)
            snoozedEmails.sort { $0.snoozeUntil < $1.snoozeUntil }

            await scheduleSnoozeNotification(for: snoozed)

            logger.info("Snoozed email '\(email.subject)' until \(date.formatted())")
        } catch {
            logger.error("Failed to save snoozed email: \(error.localizedDescription)")
        }
    }

    // MARK: - Unsnooze Email

    func unsnoozeEmail(_ snoozed: SnoozedEmail) async {
        guard let context = modelContext else {
            logger.warning("Cannot unsnooze: no model context")
            return
        }

        do {
            try await GmailService.shared.unarchive(messageId: snoozed.id)
            logger.info("Unarchived email via Gmail API")
        } catch {
            logger.error("Failed to unarchive email: \(error.localizedDescription)")
        }

        context.delete(snoozed)

        do {
            try context.save()
            snoozedEmails.removeAll { $0.id == snoozed.id }
            cancelSnoozeNotification(for: snoozed)
            logger.info("Unsnoozed email: \(snoozed.subject)")
        } catch {
            logger.error("Failed to delete snoozed record: \(error.localizedDescription)")
        }
    }

    // MARK: - Cancel Snooze

    func cancelSnooze(_ snoozed: SnoozedEmail) {
        guard let context = modelContext else {
            logger.warning("Cannot cancel snooze: no model context")
            return
        }

        context.delete(snoozed)

        do {
            try context.save()
            snoozedEmails.removeAll { $0.id == snoozed.id }
            cancelSnoozeNotification(for: snoozed)
            logger.info("Cancelled snooze for: \(snoozed.subject)")
        } catch {
            logger.error("Failed to cancel snooze: \(error.localizedDescription)")
        }
    }

    // MARK: - Check Expired Snoozes

    private func startSnoozeCheck() {
        // Check every minute
        checkTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkExpiredSnoozes()
            }
        }
    }

    func checkExpiredSnoozes() async {
        let now = Date()
        let expired = snoozedEmails.filter { $0.snoozeUntil <= now }

        for snoozed in expired {
            await unsnoozeEmail(snoozed)
        }
    }

    // MARK: - Notifications

    private func scheduleSnoozeNotification(for snoozed: SnoozedEmail) async {
        let content = UNMutableNotificationContent()
        content.title = "Snoozed Email"
        content.subtitle = EmailParser.extractSenderName(from: snoozed.from)
        content.body = snoozed.subject
        content.sound = .default
        content.categoryIdentifier = "SNOOZED_EMAIL"
        content.userInfo = [
            "emailId": snoozed.id,
            "threadId": snoozed.threadId,
            "type": "snooze"
        ]

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: snoozed.snoozeUntil
            ),
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: "snooze_\(snoozed.id)",
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.info("Scheduled notification for: \(snoozed.snoozeUntil.formatted())")
        } catch {
            logger.error("Failed to schedule notification: \(error.localizedDescription)")
        }
    }

    private func cancelSnoozeNotification(for snoozed: SnoozedEmail) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["snooze_\(snoozed.id)"]
        )
    }

    // MARK: - Get Snooze Info

    func getSnoozeInfo(for emailId: String) -> SnoozedEmail? {
        snoozedEmails.first { $0.id == emailId }
    }

    func isSnoozed(_ emailId: String) -> Bool {
        snoozedEmails.contains { $0.id == emailId }
    }
}

// MARK: - Snoozed Emails View

import SwiftUI

struct SnoozedEmailsView: View {
    @ObservedObject var snoozeManager = SnoozeManager.shared

    var body: some View {
        List {
            if snoozeManager.snoozedEmails.isEmpty {
                ContentUnavailableView(
                    "No Snoozed Emails",
                    systemImage: "clock.badge.checkmark",
                    description: Text("Emails you snooze will appear here")
                )
            } else {
                ForEach(snoozeManager.snoozedEmails) { snoozed in
                    SnoozedEmailRow(snoozed: snoozed)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                snoozeManager.cancelSnooze(snoozed)
                            } label: {
                                Label("Cancel", systemImage: "xmark.circle")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task {
                                    await snoozeManager.unsnoozeEmail(snoozed)
                                }
                            } label: {
                                Label("Unsnooze Now", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.blue)
                        }
                }
            }
        }
        .navigationTitle("Snoozed")
        .onAppear {
            snoozeManager.loadSnoozedEmails()
        }
    }
}

struct SnoozedEmailRow: View {
    let snoozed: SnoozedEmail

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(EmailParser.extractSenderName(from: snoozed.from))
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Label(formatSnoozeTime(snoozed.snoozeUntil), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(snoozed.subject)
                .font(.subheadline)
                .lineLimit(1)

            Text(snoozed.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private func formatSnoozeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
