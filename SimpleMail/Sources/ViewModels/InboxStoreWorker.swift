import Foundation

actor InboxStoreWorker {
    private var classificationCache: [String: InboxFilterEngine.CacheEntry] = [:]

    func computeState(
        emails: [Email],
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
