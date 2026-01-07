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

    private init() {
        NotificationCenter.default.addObserver(
            forName: .accountDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateCacheStats()
            }
        }
    }

    // MARK: - Configuration

    func configure(with context: ModelContext, deferIndexRebuild: Bool = true) {
        self.modelContext = context
        updateCacheStats()
        guard deferIndexRebuild else {
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                let cached = await MainActor.run {
                    self.loadAllCachedEmails()
                }
                await SearchIndexManager.shared.rebuildIndex(with: cached)
            }
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(300))
            let cached = await MainActor.run {
                self.loadAllCachedEmails()
            }
            await SearchIndexManager.shared.rebuildIndex(with: cached)
        }
    }

    func configureIfNeeded() {
        guard modelContext == nil else { return }
        // Log warning instead of creating a potentially inconsistent context
        logger.warning("EmailCache accessed before configure() was called - operations will be skipped")
    }

    /// Whether the cache is properly configured
    var isConfigured: Bool {
        modelContext != nil
    }

    // MARK: - Cache Statistics

    func updateCacheStats() {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<Email>()
        let count: Int
        do {
            count = try context.fetchCount(descriptor)
        } catch {
            logger.warning("Failed to fetch cache count: \(error.localizedDescription)")
            count = 0
        }
        Task { @MainActor in
            let accountEmail = AuthService.shared.currentAccount?.email
            cachedEmailCount = count
            lastSyncDate = AccountDefaults.date(for: "lastEmailSync", accountEmail: accountEmail)
        }
    }

    func cachedEmailCount(accountEmail: String?) -> Int {
        guard let context = modelContext else { return 0 }
        guard let accountEmail = accountEmail?.lowercased() else {
            return cachedEmailCount
        }

        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.accountEmail == accountEmail
            }
        )
        do {
            return try context.fetchCount(descriptor)
        } catch {
            logger.warning("Failed to fetch account email count: \(error.localizedDescription)")
            return 0
        }
    }

    func loadAllCachedEmails(accountEmail: String? = nil) -> [Email] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<Email>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        do {
            let results = try context.fetch(descriptor)
            if let accountEmail = accountEmail?.lowercased() {
                return results.filter { $0.accountEmail?.lowercased() == accountEmail }
            }
            return results
        } catch {
            logger.error("Failed to load all cached emails: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Cache Emails

    /// Cache emails, optionally cleaning up stale entries
    /// - Parameters:
    ///   - emails: Emails to cache
    ///   - isFullInboxFetch: If true and emails contain INBOX items, remove cached INBOX
    ///     emails not in this set. Set to false for filtered/search/paginated fetches to
    ///     avoid incorrectly deleting valid cached emails.
    func cacheEmails(_ emails: [EmailDTO], isFullInboxFetch: Bool = false) {
        if modelContext == nil {
            configureIfNeeded()
        }
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
                existing.subject = email.subject
                existing.from = email.from
                existing.date = email.date
                existing.hasAttachments = email.hasAttachments
                existing.messagesCount = email.messagesCount
                existing.accountEmail = email.accountEmail
                existing.listUnsubscribe = email.listUnsubscribe
                existing.listId = email.listId
                existing.precedence = email.precedence
                existing.autoSubmitted = email.autoSubmitted
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
            let accountEmail = emails.compactMap(\.accountEmail).first
            AccountDefaults.setDate(Date(), for: "lastEmailSync", accountEmail: accountEmail)
            updateCacheStats()
            logger.info("Cached \(emails.count) emails")
            Task {
                await SearchIndexManager.shared.index(emails: emails)
            }
        } catch {
            logger.error("Failed to cache emails: \(error.localizedDescription)")
        }

        // Cleanup: Only remove stale emails for FULL inbox fetches (not filtered/search/paginated)
        // This prevents incorrectly deleting valid cached emails when fetch returns partial results
        if isFullInboxFetch, let oldestDate = oldestFetchedDate, !fetchedIds.isEmpty {
            let accountEmail = emails.compactMap(\.accountEmail).first
            removeStaleInboxEmails(fetchedIds: fetchedIds, since: oldestDate, accountEmail: accountEmail)
        }
    }

    // MARK: - Load Cached Emails

    func loadCachedEmails(mailbox: Mailbox = .inbox, limit: Int = 100, accountEmail: String? = nil) -> [Email] {
        if modelContext == nil {
            configureIfNeeded()
        }
        guard let context = modelContext else {
            logger.warning("ModelContext not available for loadCachedEmails")
            return []
        }

        let labelIds = labelIdsForMailbox(mailbox)

        let descriptor = FetchDescriptor<Email>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )

        do {
            var results = try context.fetch(descriptor)

            // Filter by mailbox in Swift to avoid predicate crashes
            switch mailbox {
            case .archive:
                results = results.filter { email in
                    !email.labelIds.contains("INBOX") &&
                    !email.labelIds.contains("TRASH") &&
                    !email.labelIds.contains("SPAM")
                }
            default:
                if let labelId = labelIds.first {
                    results = results.filter { $0.labelIds.contains(labelId) }
                }
            }

            // Filter by account
            if let accountEmail = accountEmail?.lowercased() {
                results = results.filter { $0.accountEmail?.lowercased() == accountEmail }
            }

            // Apply limit
            return Array(results.prefix(limit))
        } catch {
            logger.error("Failed to load cached emails: \(error.localizedDescription), mailbox: \(mailbox.rawValue)")
            return []
        }
    }

    func loadCachedEmailsPage(
        mailbox: Mailbox = .inbox,
        limit: Int = 100,
        accountEmail: String? = nil,
        beforeDate: Date? = nil
    ) -> [Email] {
        if modelContext == nil {
            configureIfNeeded()
        }
        guard let context = modelContext else {
            logger.warning("ModelContext not available for loadCachedEmailsPage")
            return []
        }

        let labelIds = labelIdsForMailbox(mailbox)
        let batchSize = max(limit * 3, 150)

        var collected: [Email] = []
        var offset = 0

        while collected.count < limit {
            var descriptor = FetchDescriptor<Email>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            if let beforeDate {
                descriptor.predicate = #Predicate<Email> { email in
                    email.date < beforeDate
                }
            }
            descriptor.fetchLimit = batchSize
            descriptor.fetchOffset = offset

            let results: [Email]
            do {
                results = try context.fetch(descriptor)
            } catch {
                logger.error("Failed to fetch cached emails page: \(error.localizedDescription)")
                return []
            }

            if results.isEmpty {
                break
            }

            var filtered = results
            // Filter by mailbox in Swift to avoid predicate crashes
            switch mailbox {
            case .archive:
                filtered = filtered.filter { email in
                    !email.labelIds.contains("INBOX") &&
                    !email.labelIds.contains("TRASH") &&
                    !email.labelIds.contains("SPAM")
                }
            default:
                if let labelId = labelIds.first {
                    filtered = filtered.filter { $0.labelIds.contains(labelId) }
                }
            }

            if let accountEmail = accountEmail?.lowercased() {
                filtered = filtered.filter { $0.accountEmail?.lowercased() == accountEmail }
            }

            collected.append(contentsOf: filtered)
            if results.count < batchSize {
                break
            }
            offset += batchSize
        }

        return Array(collected.prefix(limit))
    }

    // MARK: - Search Cached Emails

    func searchCachedEmails(query: String, accountEmail: String? = nil) -> [Email] {
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
            let results = try context.fetch(descriptor)
            if let accountEmail = accountEmail?.lowercased() {
                return results.filter { $0.accountEmail == accountEmail }
            }
            return results
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
        if modelContext == nil {
            configureIfNeeded()
        }
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

    func deleteEmails(ids: [String], accountEmail: String?) {
        if modelContext == nil {
            configureIfNeeded()
        }
        guard let context = modelContext else { return }
        guard !ids.isEmpty else { return }

        let idSet = Set(ids)
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                idSet.contains(email.id)
            }
        )

        do {
            let cached = try context.fetch(descriptor)
            for email in cached {
                if let accountEmail = accountEmail?.lowercased(),
                   email.accountEmail?.lowercased() != accountEmail {
                    continue
                }
                context.delete(email)
            }
            try context.save()
            updateCacheStats()
            Task {
                await SearchIndexManager.shared.remove(ids: ids, accountEmail: accountEmail)
            }
        } catch {
            logger.error("Failed to delete emails: \(error.localizedDescription)")
        }
    }

    func loadCachedEmails(by ids: [String], accountEmail: String?) -> [Email] {
        guard let context = modelContext else { return [] }
        guard !ids.isEmpty else { return [] }

        let idSet = Set(ids)
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                idSet.contains(email.id)
            }
        )

        do {
            let results = try context.fetch(descriptor)
            let filtered = accountEmail == nil ? results : results.filter { $0.accountEmail?.lowercased() == accountEmail?.lowercased() }
            let lookup = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
            return ids.compactMap { lookup[$0] }
        } catch {
            logger.error("Failed to load cached emails by ids: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Cleanup Helpers

    private func removeStaleInboxEmails(fetchedIds: Set<String>, since oldestDate: Date, accountEmail: String?) {
        if modelContext == nil {
            configureIfNeeded()
        }
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.labelIds.contains("INBOX") && email.date >= oldestDate
            }
        )

        do {
            let cached = try context.fetch(descriptor)
            for email in cached where !fetchedIds.contains(email.id) {
                if let accountEmail = accountEmail?.lowercased(),
                   email.accountEmail?.lowercased() != accountEmail {
                    continue
                }
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
        if modelContext == nil {
            configureIfNeeded()
        }
        guard let context = modelContext else { return }

        do {
            try context.delete(model: Email.self)
            try context.delete(model: EmailDetail.self)
            try context.save()
            updateCacheStats()
            logger.info("Cache cleared")
            Task {
                await SearchIndexManager.shared.clearIndex(accountEmail: nil)
            }
            AccountSnapshotStore.shared.clear(accountEmail: nil)
        } catch {
            logger.error("Failed to clear cache: \(error.localizedDescription)")
        }
    }

    /// Clear cache for a specific account only
    func clearCache(accountEmail: String?) {
        if modelContext == nil {
            configureIfNeeded()
        }
        guard let context = modelContext else { return }
        guard let email = accountEmail?.lowercased() else {
            // If no account specified, clear all
            clearCache()
            return
        }

        do {
            // Delete emails for this account
            let emailDescriptor = FetchDescriptor<Email>(
                predicate: #Predicate { $0.accountEmail == email }
            )
            let emails = try context.fetch(emailDescriptor)
            for e in emails {
                context.delete(e)
            }

            // Delete email details for this account
            let detailDescriptor = FetchDescriptor<EmailDetail>(
                predicate: #Predicate { $0.accountEmail == email }
            )
            let details = try context.fetch(detailDescriptor)
            for detail in details {
                context.delete(detail)
            }

            try context.save()
            updateCacheStats()
            logger.info("Cache cleared for account: \(email)")
            Task {
                await SearchIndexManager.shared.clearIndex(accountEmail: email)
            }
            AccountSnapshotStore.shared.clear(accountEmail: email)
        } catch {
            logger.error("Failed to clear cache for account: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache Email Detail

    func cacheEmailDetail(_ detail: EmailDetail) {
        if modelContext == nil {
            configureIfNeeded()
        }
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
                existing.accountEmail = detail.accountEmail
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
                    cc: detail.cc,
                    accountEmail: detail.accountEmail
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
        if modelContext == nil {
            configureIfNeeded()
        }
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
        case .allInboxes: return ["INBOX"]  // Unified inbox shows INBOX from all accounts
        case .inbox: return ["INBOX"]
        case .sent: return ["SENT"]
        case .archive: return []
        case .trash: return ["TRASH"]
        case .drafts: return ["DRAFT"]
        case .starred: return ["STARRED"]
        }
    }

    // MARK: - Email Detail Caching (for Offline Support)

    /// Check if email detail (body) is cached
    func hasDetailCached(emailId: String) -> Bool {
        guard let context = modelContext else { return false }

        let id = emailId  // Capture in local variable for predicate
        let descriptor = FetchDescriptor<EmailDetail>(
            predicate: #Predicate<EmailDetail> { detail in
                detail.id == id
            }
        )

        return (try? context.fetchCount(descriptor)) ?? 0 > 0
    }

    /// Cache email detail (body)
    func cacheEmailDetail(_ dto: EmailDetailDTO) {
        guard let context = modelContext else { return }

        // Check if already cached
        let id = dto.id  // Capture in local variable for predicate
        let descriptor = FetchDescriptor<EmailDetail>(
            predicate: #Predicate<EmailDetail> { detail in
                detail.id == id
            }
        )

        if let existing = try? context.fetch(descriptor).first {
            // Update existing
            existing.body = dto.body
            existing.to = dto.to
            existing.cc = dto.cc
        } else {
            // Insert new
            let detail = EmailDetail(dto: dto)
            context.insert(detail)
        }

        try? context.save()
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
