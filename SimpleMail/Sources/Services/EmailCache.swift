import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.simplemail.app", category: "EmailCache")

// MARK: - Email Cache Manager

@MainActor
final class EmailCacheManager: ObservableObject {
    static let shared = EmailCacheManager()

    @Published var lastSyncDate: Date?
    @Published var cachedEmailCount: Int = 0

    private var modelContext: ModelContext?

    private init() {}

    // MARK: - Configuration

    func configure(with context: ModelContext) {
        self.modelContext = context
        updateCacheStats()
    }

    // MARK: - Cache Statistics

    func updateCacheStats() {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<Email>()
        do {
            cachedEmailCount = try context.fetchCount(descriptor)
        } catch {
            logger.warning("Failed to fetch cache count: \(error.localizedDescription)")
            cachedEmailCount = 0
        }
        lastSyncDate = UserDefaults.standard.object(forKey: "lastEmailSync") as? Date
    }

    // MARK: - Cache Emails

    func cacheEmails(_ emails: [Email]) {
        guard let context = modelContext else {
            logger.warning("No model context configured")
            return
        }

        guard !emails.isEmpty else { return }

        let fetchedIds = Set(emails.map { $0.id })
        let oldestFetchedDate = emails.map(\.date).min()

        // Batch fetch ALL existing emails by ID to avoid N+1 queries
        let emailIds = emails.map { $0.id }
        let batchDescriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in emailIds.contains(email.id) }
        )

        let existingEmails: [Email]
        do {
            existingEmails = try context.fetch(batchDescriptor)
        } catch {
            logger.error("Failed to batch fetch existing emails: \(error.localizedDescription)")
            return
        }

        // Create lookup dictionary for O(1) access
        let existingById = Dictionary(uniqueKeysWithValues: existingEmails.map { ($0.id, $0) })

        for email in emails {
            if let existing = existingById[email.id] {
                // Update existing
                existing.isUnread = email.isUnread
                existing.isStarred = email.isStarred
                existing.labelIds = email.labelIds
                existing.snippet = email.snippet
            } else {
                // Insert new (create a copy for the context)
                let cached = Email(
                    id: email.id,
                    threadId: email.threadId,
                    snippet: email.snippet,
                    subject: email.subject,
                    from: email.from,
                    date: email.date,
                    isUnread: email.isUnread,
                    isStarred: email.isStarred,
                    hasAttachments: email.hasAttachments,
                    labelIds: email.labelIds,
                    messagesCount: email.messagesCount,
                    accountEmail: email.accountEmail,
                    listUnsubscribe: email.listUnsubscribe,
                    listId: email.listId,
                    precedence: email.precedence,
                    autoSubmitted: email.autoSubmitted
                )
                context.insert(cached)
            }
        }

        do {
            try context.save()
            UserDefaults.standard.set(Date(), forKey: "lastEmailSync")
            updateCacheStats()
            logger.info("Cached \(emails.count) emails")
        } catch {
            logger.error("Failed to cache emails: \(error.localizedDescription)")
        }

        // Cleanup: remove cached inbox emails that no longer exist in the latest fetch window.
        if let oldestDate = oldestFetchedDate, !fetchedIds.isEmpty {
            removeStaleInboxEmails(fetchedIds: fetchedIds, since: oldestDate)
        }
    }

    // MARK: - Load Cached Emails

    func loadCachedEmails(mailbox: Mailbox = .inbox, limit: Int = 100) -> [Email] {
        guard let context = modelContext else { return [] }

        let labelIds = labelIdsForMailbox(mailbox)

        var descriptor = FetchDescriptor<Email>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        // Filter by label or archive rules if needed
        switch mailbox {
        case .archive:
            descriptor.predicate = #Predicate { email in
                !email.labelIds.contains("INBOX") &&
                !email.labelIds.contains("TRASH") &&
                !email.labelIds.contains("SPAM")
            }
        default:
            if let labelId = labelIds.first {
                descriptor.predicate = #Predicate { email in
                    email.labelIds.contains(labelId)
                }
            }
        }

        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to load cached emails: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Search Cached Emails

    func searchCachedEmails(query: String) -> [Email] {
        guard let context = modelContext else { return [] }

        let lowercaseQuery = query.lowercased()
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.subject.localizedStandardContains(lowercaseQuery) ||
                email.snippet.localizedStandardContains(lowercaseQuery) ||
                email.from.localizedStandardContains(lowercaseQuery)
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )

        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to search cached emails: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Update Single Email

    func updateEmail(_ email: Email) {
        guard let context = modelContext else { return }

        let emailId = email.id
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { $0.id == emailId }
        )

        do {
            if let cached = try context.fetch(descriptor).first {
                cached.isUnread = email.isUnread
                cached.isStarred = email.isStarred
                cached.labelIds = email.labelIds
                try context.save()
            }
        } catch {
            logger.error("Failed to update email: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete Cached Email

    func deleteEmail(_ email: Email) {
        guard let context = modelContext else { return }

        let emailId = email.id
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { $0.id == emailId }
        )

        do {
            if let cached = try context.fetch(descriptor).first {
                context.delete(cached)
                try context.save()
                updateCacheStats()
            }
        } catch {
            logger.error("Failed to delete email: \(error.localizedDescription)")
        }
    }

    // MARK: - Cleanup Helpers

    private func removeStaleInboxEmails(fetchedIds: Set<String>, since oldestDate: Date) {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.labelIds.contains("INBOX") && email.date >= oldestDate
            }
        )

        do {
            let cached = try context.fetch(descriptor)
            for email in cached where !fetchedIds.contains(email.id) {
                context.delete(email)
            }
            try context.save()
            updateCacheStats()
        } catch {
            logger.error("Failed to remove stale inbox emails: \(error.localizedDescription)")
        }
    }

    // MARK: - Clear Cache

    func clearCache() {
        guard let context = modelContext else { return }

        do {
            try context.delete(model: Email.self)
            try context.delete(model: EmailDetail.self)
            try context.save()
            updateCacheStats()
            logger.info("Cache cleared")
        } catch {
            logger.error("Failed to clear cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache Email Detail

    func cacheEmailDetail(_ detail: EmailDetail) {
        guard let context = modelContext else { return }

        let detailId = detail.id
        let descriptor = FetchDescriptor<EmailDetail>(
            predicate: #Predicate { $0.id == detailId }
        )

        do {
            if let existing = try context.fetch(descriptor).first {
                existing.body = detail.body
                existing.isUnread = detail.isUnread
                existing.isStarred = detail.isStarred
            } else {
                let cached = EmailDetail(
                    id: detail.id,
                    threadId: detail.threadId,
                    snippet: detail.snippet,
                    subject: detail.subject,
                    from: detail.from,
                    date: detail.date,
                    isUnread: detail.isUnread,
                    isStarred: detail.isStarred,
                    hasAttachments: detail.hasAttachments,
                    labelIds: detail.labelIds,
                    body: detail.body,
                    to: detail.to,
                    cc: detail.cc
                )
                context.insert(cached)
            }
            try context.save()
        } catch {
            logger.error("Failed to cache email detail: \(error.localizedDescription)")
        }
    }

    // MARK: - Load Cached Email Detail

    func loadCachedEmailDetail(id emailId: String) -> EmailDetail? {
        guard let context = modelContext else { return nil }

        let descriptor = FetchDescriptor<EmailDetail>(
            predicate: #Predicate { $0.id == emailId }
        )

        do {
            return try context.fetch(descriptor).first
        } catch {
            logger.error("Failed to load cached email detail: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    private func labelIdsForMailbox(_ mailbox: Mailbox) -> [String] {
        switch mailbox {
        case .inbox: return ["INBOX"]
        case .sent: return ["SENT"]
        case .archive: return []
        case .trash: return ["TRASH"]
        case .drafts: return ["DRAFT"]
        case .starred: return ["STARRED"]
        }
    }
}

// MARK: - Offline Mode Indicator

import SwiftUI

struct OfflineModeIndicator: View {
    @ObservedObject var cacheManager = EmailCacheManager.shared

    var body: some View {
        if let lastSync = cacheManager.lastSyncDate {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
                Text("Last synced \(formatLastSync(lastSync))")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.systemGray6))
            .clipShape(Capsule())
        }
    }

    private func formatLastSync(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
