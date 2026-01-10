import Foundation

/// Minimal raw email data passed from main thread (no regex computation)
struct RawEmailData: Sendable {
    let id: String
    let threadId: String
    let date: Date
    let subject: String
    let snippet: String
    let from: String  // Raw - senderEmail/senderName computed on actor
    let isUnread: Bool
    let isStarred: Bool
    let hasAttachments: Bool
    let accountEmail: String?
    let labelIdsKey: String
    let listUnsubscribe: String?
    let listId: String?
    let precedence: String?
    let autoSubmitted: String?
    let messagesCount: Int
}

actor InboxStoreWorker {
    private var classificationCache: [String: InboxFilterEngine.CacheEntry] = [:]

    /// Compute inbox view state from raw email data.
    /// Converts raw data to EmailSnapshot (with regex parsing) on this actor to avoid main thread stalls.
    func computeStateFromRaw(
        rawEmails: [RawEmailData],
        currentTab: InboxTab,
        pinnedTabOption: PinnedTabOption,
        activeFilter: InboxFilter?,
        currentAccountEmail: String?,
        searchFilter: SearchFilter?
    ) -> InboxViewState {
        // Convert raw data to snapshots here (regex parsing off main thread)
        let emails = rawEmails.map { raw in
            EmailSnapshot(
                id: raw.id,
                threadId: raw.threadId,
                date: raw.date,
                subject: raw.subject,
                snippet: raw.snippet,
                senderEmail: EmailParser.extractSenderEmail(from: raw.from),
                senderName: EmailParser.extractSenderName(from: raw.from),
                isUnread: raw.isUnread,
                isStarred: raw.isStarred,
                hasAttachments: raw.hasAttachments,
                accountEmail: raw.accountEmail,
                labelIdsKey: raw.labelIdsKey,
                listUnsubscribe: raw.listUnsubscribe,
                listId: raw.listId,
                precedence: raw.precedence,
                autoSubmitted: raw.autoSubmitted,
                messagesCount: raw.messagesCount
            )
        }
        return computeState(
            emails: emails,
            currentTab: currentTab,
            pinnedTabOption: pinnedTabOption,
            activeFilter: activeFilter,
            currentAccountEmail: currentAccountEmail,
            searchFilter: searchFilter
        )
    }

    /// Compute inbox view state from EmailSnapshot value types.
    /// IMPORTANT: Takes EmailSnapshot (pure value type, Sendable) instead of Email (SwiftData model)
    /// to avoid cross-actor SwiftData access issues that cause main thread stalls.
    func computeState(
        emails: [EmailSnapshot],
        currentTab: InboxTab,
        pinnedTabOption: PinnedTabOption,
        activeFilter: InboxFilter?,
        currentAccountEmail: String?,
        searchFilter: SearchFilter?
    ) -> InboxViewState {
        let cacheResult = InboxFilterEngine.buildClassificationCache(
            emails: emails,
            existingCache: classificationCache,
            currentAccountEmail: currentAccountEmail
        )
        classificationCache = cacheResult.cache

        let filtered = InboxFilterEngine.applyFilters(
            emails,
            currentTab: currentTab,
            pinnedTabOption: pinnedTabOption,
            activeFilter: activeFilter,
            currentAccountEmail: currentAccountEmail,
            classifications: cacheResult.classifications
        )

        // Apply search filter (local search) if present
        let searchFiltered = searchFilter.map { filter in
            filtered.filter { filter.matches($0) }
        } ?? filtered

        // Convert snapshots to DTOs once (pure value type conversion)
        let dtos = searchFiltered.map { $0.toDTO() }
        let sections = InboxFilterEngine.groupEmailsByDate(dtos)
        let counts = InboxFilterEngine.recomputeFilterCounts(
            from: emails,
            currentTab: currentTab,
            pinnedTabOption: pinnedTabOption,
            currentAccountEmail: currentAccountEmail,
            classifications: cacheResult.classifications
        )
        return InboxViewState(sections: sections, filterCounts: counts)
    }
}
