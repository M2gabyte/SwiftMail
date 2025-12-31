import Foundation
import SwiftData

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
        cachedEmailCount = (try? context.fetchCount(descriptor)) ?? 0
        lastSyncDate = UserDefaults.standard.object(forKey: "lastEmailSync") as? Date
    }

    // MARK: - Cache Emails

    func cacheEmails(_ emails: [Email]) {
        guard let context = modelContext else {
            print("[EmailCache] No model context configured")
            return
        }

        for email in emails {
            // Check if already exists
            let emailId = email.id
            let descriptor = FetchDescriptor<Email>(
                predicate: #Predicate { $0.id == emailId }
            )

            if let existing = try? context.fetch(descriptor).first {
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
            print("[EmailCache] Cached \(emails.count) emails")
        } catch {
            print("[EmailCache] Failed to cache emails: \(error)")
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

        // Filter by label if needed
        if !labelIds.isEmpty {
            let labelId = labelIds[0]
            descriptor.predicate = #Predicate { email in
                email.labelIds.contains(labelId)
            }
        }

        do {
            return try context.fetch(descriptor)
        } catch {
            print("[EmailCache] Failed to load cached emails: \(error)")
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
            print("[EmailCache] Failed to search cached emails: \(error)")
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

        if let cached = try? context.fetch(descriptor).first {
            cached.isUnread = email.isUnread
            cached.isStarred = email.isStarred
            cached.labelIds = email.labelIds

            do {
                try context.save()
            } catch {
                print("[EmailCache] Failed to update email: \(error)")
            }
        }
    }

    // MARK: - Delete Cached Email

    func deleteEmail(_ email: Email) {
        guard let context = modelContext else { return }

        let emailId = email.id
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { $0.id == emailId }
        )

        if let cached = try? context.fetch(descriptor).first {
            context.delete(cached)

            do {
                try context.save()
                updateCacheStats()
            } catch {
                print("[EmailCache] Failed to delete email: \(error)")
            }
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
            print("[EmailCache] Cache cleared")
        } catch {
            print("[EmailCache] Failed to clear cache: \(error)")
        }
    }

    // MARK: - Cache Email Detail

    func cacheEmailDetail(_ detail: EmailDetail) {
        guard let context = modelContext else { return }

        let detailId = detail.id
        let descriptor = FetchDescriptor<EmailDetail>(
            predicate: #Predicate { $0.id == detailId }
        )

        if let existing = try? context.fetch(descriptor).first {
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

        try? context.save()
    }

    // MARK: - Load Cached Email Detail

    func loadCachedEmailDetail(id emailId: String) -> EmailDetail? {
        guard let context = modelContext else { return nil }

        let descriptor = FetchDescriptor<EmailDetail>(
            predicate: #Predicate { $0.id == emailId }
        )

        return try? context.fetch(descriptor).first
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
