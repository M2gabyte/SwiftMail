import Foundation
import SwiftData
import UserNotifications

// MARK: - Snooze Manager

@MainActor
final class SnoozeManager: ObservableObject {
    static let shared = SnoozeManager()

    @Published var snoozedEmails: [SnoozedEmail] = []

    private var modelContext: ModelContext?
    private var checkTimer: Timer?

    private init() {
        // Start checking for expired snoozes
        startSnoozeCheck()
    }

    // MARK: - Configuration

    func configure(with context: ModelContext) {
        self.modelContext = context
        loadSnoozedEmails()
    }

    // MARK: - Load Snoozed Emails

    func loadSnoozedEmails() {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<SnoozedEmail>(
            sortBy: [SortDescriptor(\.snoozeUntil, order: .forward)]
        )

        do {
            snoozedEmails = try context.fetch(descriptor)
        } catch {
            print("[SnoozeManager] Failed to load snoozed emails: \(error)")
        }
    }

    // MARK: - Snooze Email

    func snoozeEmail(_ email: Email, until date: Date) async {
        guard let context = modelContext else {
            print("[SnoozeManager] No model context configured")
            return
        }

        // Create snoozed email record
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

            // Schedule notification
            await scheduleSnoozeNotification(for: snoozed)

            print("[SnoozeManager] Snoozed email until: \(date)")
        } catch {
            print("[SnoozeManager] Failed to save snoozed email: \(error)")
        }
    }

    // MARK: - Unsnooze Email

    func unsnoozeEmail(_ snoozed: SnoozedEmail) async {
        guard let context = modelContext else { return }

        // Move back to inbox via Gmail API
        do {
            try await GmailService.shared.unarchive(messageId: snoozed.id)
        } catch {
            print("[SnoozeManager] Failed to unarchive email: \(error)")
        }

        // Remove from local database
        context.delete(snoozed)

        do {
            try context.save()
            snoozedEmails.removeAll { $0.id == snoozed.id }

            // Cancel notification
            cancelSnoozeNotification(for: snoozed)

            print("[SnoozeManager] Unsnoozed email: \(snoozed.subject)")
        } catch {
            print("[SnoozeManager] Failed to delete snoozed record: \(error)")
        }
    }

    // MARK: - Cancel Snooze

    func cancelSnooze(_ snoozed: SnoozedEmail) {
        guard let context = modelContext else { return }

        context.delete(snoozed)

        do {
            try context.save()
            snoozedEmails.removeAll { $0.id == snoozed.id }
            cancelSnoozeNotification(for: snoozed)
        } catch {
            print("[SnoozeManager] Failed to cancel snooze: \(error)")
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
            print("[SnoozeManager] Scheduled notification for: \(snoozed.snoozeUntil)")
        } catch {
            print("[SnoozeManager] Failed to schedule notification: \(error)")
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
