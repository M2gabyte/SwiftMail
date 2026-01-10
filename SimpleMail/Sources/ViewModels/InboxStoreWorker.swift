import Foundation

actor InboxStoreWorker {
    private var classificationCache: [String: InboxFilterEngine.CacheEntry] = [:]

    /// Compute inbox view state from EmailDTO snapshots.
    /// IMPORTANT: Takes EmailDTO (Sendable) instead of Email (SwiftData model)
    /// to avoid cross-actor SwiftData access issues that cause main thread stalls.
    func computeState(
        emails: [EmailDTO],
        currentTab: InboxTab,
        pinnedTabOption: PinnedTabOption,
        activeFilter: InboxFilter?,
        currentAccountEmail: String?
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
        let sections = InboxFilterEngine.groupEmailsByDate(filtered)
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
