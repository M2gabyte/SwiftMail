import Foundation

@MainActor
final class InboxStore {
    private var emails: [Email] = []
    private var currentTab: InboxTab = .all
    private var pinnedTabOption: PinnedTabOption = .other
    private var activeFilter: InboxFilter?
    private var filterVersion = 0
    private var currentAccountEmail: String?

    private var sectionsDirty = true
    private var cachedSections: [EmailSection] = []
    private var filterCounts: [InboxFilter: Int] = [:]

    func setEmails(_ emails: [Email]) {
        self.emails = emails
        sectionsDirty = true
    }

    func setCurrentTab(_ tab: InboxTab) {
        currentTab = tab
        sectionsDirty = true
        recomputeFilterCounts()
    }

    func setPinnedTabOption(_ option: PinnedTabOption) {
        pinnedTabOption = option
        sectionsDirty = true
        recomputeFilterCounts()
    }

    func setActiveFilter(_ filter: InboxFilter?) {
        activeFilter = filter
        sectionsDirty = true
    }

    func setCurrentAccountEmail(_ email: String?) {
        currentAccountEmail = email
        sectionsDirty = true
        recomputeFilterCounts()
    }

    func bumpFilterVersion() {
        filterVersion += 1
        sectionsDirty = true
        recomputeFilterCounts()
    }

    var sections: [EmailSection] {
        if sectionsDirty {
            cachedSections = recomputeSections()
            sectionsDirty = false
        }
        return cachedSections
    }

    var counts: [InboxFilter: Int] {
        filterCounts
    }

    func recomputeFilterCounts() {
        filterCounts = InboxFilterEngine.recomputeFilterCounts(
            from: emails,
            currentTab: currentTab,
            pinnedTabOption: pinnedTabOption,
            currentAccountEmail: currentAccountEmail
        )
    }

    private func recomputeSections() -> [EmailSection] {
        let filteredEmails = InboxFilterEngine.applyFilters(
            emails,
            currentTab: currentTab,
            pinnedTabOption: pinnedTabOption,
            activeFilter: activeFilter,
            currentAccountEmail: currentAccountEmail
        )
        return InboxFilterEngine.groupEmailsByDate(filteredEmails)
    }
}
