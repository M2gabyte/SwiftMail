import Foundation
import SwiftUI
import SwiftData
import OSLog

// MARK: - Inbox ViewModel

private let logger = Logger(subsystem: "com.simplemail.app", category: "InboxViewModel")

// Notification for when blocked senders list changes
extension Notification.Name {
    static let blockedSendersDidChange = Notification.Name("blockedSendersDidChange")
    static let cachesDidClear = Notification.Name("cachesDidClear")
    static let archiveThreadRequested = Notification.Name("archiveThreadRequested")
    static let trashThreadRequested = Notification.Name("trashThreadRequested")
}

@MainActor
@Observable
final class InboxViewModel {
    // MARK: - State

    var emails: [Email] = [] {
        didSet {
            scheduleRecompute()
        }
    }
    var currentTab: InboxTab = .all {
        didSet {
            scheduleRecompute()
        }
    }
    var pinnedTabOption: PinnedTabOption = .other {
        didSet {
            scheduleRecompute()
        }
    }
    var activeFilter: InboxFilter? = nil {
        didSet {
            scheduleRecompute()
        }
    }
    var currentMailbox: Mailbox = .inbox
    var isLoading = false
    var isLoadingMore = false
    var error: Error?

    // Threading control - when false, shows all messages individually
    var conversationThreading: Bool = true

    // Increment to force re-filter (e.g., when blocked senders change)
    private var filterVersion = 0 {
        didSet {
            scheduleRecompute()
        }
    }

    // MARK: - Search State

    var isSearchActive = false
    var searchResults: [Email] = []
    var isSearching = false
    var currentSearchQuery = ""
    var localSearchResults: [Email] = []

    // MARK: - Bulk Actions Toast

    var bulkToastMessage: String?
    var bulkToastIsError = false
    var bulkToastShowsRetry = false

    // MARK: - Navigation

    var selectedEmail: Email?
    var showingEmailDetail = false

    // MARK: - View State

    var viewState = InboxViewState()

    // MARK: - Filter Counts

    var filterCounts: [InboxFilter: Int] { viewState.filterCounts }

    var alwaysPrimarySenders: [String] {
        get {
            AccountDefaults.stringArray(for: "alwaysPrimarySenders", accountEmail: AuthService.shared.currentAccount?.email)
        }
        set {
            AccountDefaults.setStringArray(newValue, for: "alwaysPrimarySenders", accountEmail: AuthService.shared.currentAccount?.email)
        }
    }

    var alwaysOtherSenders: [String] {
        get {
            AccountDefaults.stringArray(for: "alwaysOtherSenders", accountEmail: AuthService.shared.currentAccount?.email)
        }
        set {
            AccountDefaults.setStringArray(newValue, for: "alwaysOtherSenders", accountEmail: AuthService.shared.currentAccount?.email)
        }
    }

    // MARK: - Pagination

    private var nextPageToken: String?
    var hasMoreEmails: Bool { nextPageToken != nil }

    // MARK: - Undo Toast State

    var showingUndoToast = false
    var undoToastMessage = ""
    var undoRemainingSeconds = 0
    private var pendingArchive: PendingArchive?
    private var undoTask: Task<Void, Never>?
    private var undoCountdownTask: Task<Void, Never>?

    private struct PendingBulkItem {
        let email: Email
        let index: Int
    }

    private enum PendingBulkActionType {
        case archive
        case trash
    }

    private struct PendingBulkAction {
        let items: [PendingBulkItem]
        let action: PendingBulkActionType
    }

    private var pendingBulkAction: PendingBulkAction?

    struct PendingArchive {
        let email: Email
        let index: Int
    }

    // MARK: - Notification Observer
    @ObservationIgnored private var blockedSendersObserver: NSObjectProtocol?
    @ObservationIgnored private var accountChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var archiveThreadObserver: NSObjectProtocol?
    @ObservationIgnored private var trashThreadObserver: NSObjectProtocol?
    @ObservationIgnored private var inboxPreferencesObserver: NSObjectProtocol?
    @ObservationIgnored private let inboxWorker = InboxStoreWorker()
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    @ObservationIgnored private var currentAccountEmail: String?
    @ObservationIgnored private var cachePagingState = CachePagingState()

    private struct CachePagingState {
        var oldestLoadedDate: Date?
        var isExhausted = false
    }
    private let cachePageSize = 120
    private var lastFallbackFetchBefore: Date?
    private var pageTokenStallCount = 0
    private var fallbackEmptyCount = 0

    struct PagingDebugState {
        var path: String = "idle"
        var action: String = "-"
        var fetched: Int = 0
        var appended: Int = 0
        var oldestLoadedDate: Date?
        var nextPageTokenPresent = false
        var cacheExhausted = false
        var timestamp = Date()
    }

    var pagingDebug = PagingDebugState()

    // MARK: - Computed Properties

    var emailSections: [EmailSection] {
        viewState.sections
    }

    /// Last visible email after filtering (for pagination trigger)
    private var lastVisibleEmailId: String? {
        emailSections.last?.emails.last?.id
    }

    private func accountForEmail(_ email: Email) -> AuthService.Account? {
        if let accountEmail = email.accountEmail?.lowercased() {
            return AuthService.shared.accounts.first { $0.email.lowercased() == accountEmail }
        }
        return AuthService.shared.currentAccount
    }

    private func animate(_ animation: Animation? = .default, _ body: () -> Void) {
        withAnimation(animation, body)
    }

    private func scheduleRecompute() {
        let emailsSnapshot = emails
        let currentTabSnapshot = currentTab
        let pinnedSnapshot = pinnedTabOption
        let activeFilterSnapshot = activeFilter
        let accountSnapshot = currentAccountEmail
        let mailboxSnapshot = currentMailbox
        let nextTokenSnapshot = nextPageToken
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            guard let self else { return }
            let state = await inboxWorker.computeState(
                emails: emailsSnapshot,
                currentTab: currentTabSnapshot,
                pinnedTabOption: pinnedSnapshot,
                activeFilter: activeFilterSnapshot,
                currentAccountEmail: accountSnapshot
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                viewState = state
                saveSnapshotIfNeeded(
                    emails: emailsSnapshot,
                    viewState: state,
                    currentTab: currentTabSnapshot,
                    pinnedTabOption: pinnedSnapshot,
                    activeFilter: activeFilterSnapshot,
                    mailbox: mailboxSnapshot,
                    nextPageToken: nextTokenSnapshot
                )
            }
        }
    }

    private func updatePagingDebug(
        path: String,
        action: String,
        fetched: Int = 0,
        appended: Int = 0
    ) {
        pagingDebug = PagingDebugState(
            path: path,
            action: action,
            fetched: fetched,
            appended: appended,
            oldestLoadedDate: cachePagingState.oldestLoadedDate,
            nextPageTokenPresent: nextPageToken != nil,
            cacheExhausted: cachePagingState.isExhausted,
            timestamp: Date()
        )
        logger.info("PagingDebug path=\(path) action=\(action) fetched=\(fetched) appended=\(appended) oldest=\(self.cachePagingState.oldestLoadedDate?.description ?? "nil") nextToken=\(self.nextPageToken != nil) exhausted=\(self.cachePagingState.isExhausted)")
    }

    // MARK: - Init

    init() {
        InboxPreferences.ensureDefaultsInitialized()
        pinnedTabOption = InboxPreferences.getPinnedTabOption()
        currentAccountEmail = AuthService.shared.currentAccount?.email
        scheduleRecompute()

        // Listen for blocked senders changes from EmailDetailView
        blockedSendersObserver = NotificationCenter.default.addObserver(
            forName: .blockedSendersDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.filterVersion += 1
                self?.updateFilterCounts()
            }
        }

        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .accountDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let newAccountEmail = AuthService.shared.currentAccount?.email
                let normalizedNew = newAccountEmail?.lowercased()
                let normalizedCurrent = self.currentAccountEmail?.lowercased()
                guard normalizedNew != normalizedCurrent else {
                    return
                }
                self.currentAccountEmail = newAccountEmail
                self.applySnapshotOrCachedEmails()
                self.scheduleRecompute()
                Task {
                    await self.loadEmails(showLoading: false, deferHeavyWork: true)
                }
            }
        }

        inboxPreferencesObserver = NotificationCenter.default.addObserver(
            forName: .inboxPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                pinnedTabOption = InboxPreferences.getPinnedTabOption()
                filterVersion += 1
                updateFilterCounts()
            }
        }

        archiveThreadObserver = NotificationCenter.default.addObserver(
            forName: .archiveThreadRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let threadId = notification.userInfo?["threadId"] as? String else { return }
                performUndoableBulkAction(threadIds: [threadId], action: .archive)
            }
        }

        trashThreadObserver = NotificationCenter.default.addObserver(
            forName: .trashThreadRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let threadId = notification.userInfo?["threadId"] as? String else { return }
                performUndoableBulkAction(threadIds: [threadId], action: .trash)
            }
        }

        Task {
            await loadEmails()
        }
    }

    deinit {
        if let observer = blockedSendersObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = accountChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = archiveThreadObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = trashThreadObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = inboxPreferencesObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Load Real Emails

    func loadEmails(showLoading: Bool = true, deferHeavyWork: Bool = false) async {
        if showLoading {
            isLoading = true
        }
        nextPageToken = nil
        defer {
            if showLoading {
                isLoading = false
            }
            updateFilterCounts()
        }

        do {
            if currentMailbox == .allInboxes {
                let accounts = AuthService.shared.accounts
                let query = mailboxQuery(for: currentMailbox)
                let labelIds = labelIdsForMailbox(currentMailbox)
                let fetchedEmails = try await fetchUnifiedInbox(
                    accounts: accounts,
                    query: query,
                    labelIds: labelIds
                )
                let emailModels = fetchedEmails.map(Email.init(dto:))
                self.emails = dedupeByThread(emailModels)
                self.nextPageToken = nil
                updateCachePagingAnchor()
                EmailCacheManager.shared.cacheEmails(fetchedEmails, isFullInboxFetch: false)
                scheduleSummaryCandidates(for: emails, deferHeavyWork: deferHeavyWork)
            } else {
                let labelIds = labelIdsForMailbox(currentMailbox)
                let query = mailboxQuery(for: currentMailbox)
                let (fetchedEmails, pageToken) = try await GmailService.shared.fetchInbox(
                    query: query,
                    maxResults: 50,
                    labelIds: labelIds
                )
                let emailModels = fetchedEmails.map(Email.init(dto:))
                self.emails = dedupeByThread(emailModels)
                self.nextPageToken = pageToken
                updateCachePagingAnchor()
                EmailCacheManager.shared.cacheEmails(
                    fetchedEmails,
                    isFullInboxFetch: currentMailbox == .inbox && pageToken == nil
                )
                scheduleSummaryCandidates(for: emails, deferHeavyWork: deferHeavyWork)
            }
        } catch {
            logger.error("Failed to fetch emails: \(error.localizedDescription)")
            self.error = error
            // Do NOT load mock data - show empty state with error instead
        }
    }

    // MARK: - Load More (Pagination)

    func loadMoreIfNeeded(currentEmail: Email) async {
        // Check against the last VISIBLE email (after filtering), not the last raw email
        // This ensures pagination triggers correctly when tab filtering reduces the list
        guard let lastVisibleId = lastVisibleEmailId,
              lastVisibleId == currentEmail.id,
              !isLoadingMore else {
            return
        }

        if await loadMoreFromCacheIfAvailable() {
            return
        }

        if hasMoreEmails {
            let didAppend = await loadMoreEmails()
            if didAppend {
                return
            }
        }

        if let oldestDate = cachePagingState.oldestLoadedDate {
            _ = await loadMoreFromNetworkByDate(before: oldestDate)
        }
    }

    @discardableResult
    func loadMoreEmails() async -> Bool {
        if currentMailbox == .allInboxes {
            await loadMoreUnifiedByDate()
            return false
        }

        guard var pageToken = nextPageToken, !isLoadingMore else { return false }

        isLoadingMore = true
        defer { isLoadingMore = false }
        updatePagingDebug(path: "pageToken", action: "start")

        do {
            let labelIds = labelIdsForMailbox(currentMailbox)
            let query = mailboxQuery(for: currentMailbox)
            var accumulatedOldest: Date?
            var uniqueNewEmails: [Email] = []
            var fetched: [EmailDTO] = []
            var attempts = 0

            while attempts < 4, !pageToken.isEmpty, uniqueNewEmails.isEmpty {
                attempts += 1
                let (moreEmails, newPageToken) = try await GmailService.shared.fetchInbox(
                    query: query,
                    maxResults: 50,
                    pageToken: pageToken,
                    labelIds: labelIds
                )
                fetched = moreEmails
                updatePagingDebug(path: "pageToken", action: "fetched", fetched: moreEmails.count)
                if let oldest = moreEmails.map(\.date).min() {
                    accumulatedOldest = min(accumulatedOldest ?? oldest, oldest)
                }

                let moreEmailModels = moreEmails.map(Email.init(dto:))
                if conversationThreading {
                    let existingThreadIds = Set(emails.map { $0.threadId })
                    uniqueNewEmails = moreEmailModels.filter { !existingThreadIds.contains($0.threadId) }
                } else {
                    let existingIds = Set(emails.map { $0.id })
                    uniqueNewEmails = moreEmailModels.filter { !existingIds.contains($0.id) }
                }

                pageToken = newPageToken ?? ""
                nextPageToken = newPageToken

                if !moreEmails.isEmpty {
                    EmailCacheManager.shared.cacheEmails(moreEmails, isFullInboxFetch: false)
                }

                if moreEmails.isEmpty || newPageToken == nil {
                    break
                }
            }

            if !uniqueNewEmails.isEmpty {
                emails.append(contentsOf: uniqueNewEmails)
                cachePagingState.oldestLoadedDate = emails.map(\.date).min()
                cachePagingState.isExhausted = false
                updateFilterCounts()
                logger.info("Loaded \(uniqueNewEmails.count) more emails")
                pageTokenStallCount = 0
                updatePagingDebug(path: "pageToken", action: "appended", fetched: fetched.count, appended: uniqueNewEmails.count)
                return true
            }

            if let accumulatedOldest {
                cachePagingState.oldestLoadedDate = accumulatedOldest
                lastFallbackFetchBefore = accumulatedOldest
            }
            pageTokenStallCount += 1
            if pageTokenStallCount >= 2 {
                nextPageToken = nil
                updatePagingDebug(path: "pageToken", action: "stall-reset", fetched: fetched.count)
            } else {
                updatePagingDebug(path: "pageToken", action: "duplicates", fetched: fetched.count)
            }
            return false
        } catch {
            logger.error("Failed to load more emails: \(error.localizedDescription)")
            self.error = error
            updatePagingDebug(path: "pageToken", action: "error")
            return false
        }
    }

    private func labelIdsForMailbox(_ mailbox: Mailbox) -> [String] {
        switch mailbox {
        case .allInboxes: return ["INBOX"]
        case .inbox: return ["INBOX"]
        case .sent: return ["SENT"]
        case .archive: return []
        case .trash: return ["TRASH"]
        case .drafts: return ["DRAFT"]
        case .starred: return ["STARRED"]
        }
    }

    private func mailboxQuery(for mailbox: Mailbox) -> String? {
        switch mailbox {
        case .archive:
            return "-in:inbox -in:trash -in:spam"
        case .allInboxes:
            return nil
        default:
            return nil
        }
    }

    private func dedupeByThread(_ emails: [Email]) -> [Email] {
        // When threading is off, don't dedupe - show all messages individually
        guard conversationThreading else {
            return emails
        }

        var seen = Set<String>()
        var deduped: [Email] = []
        for email in emails {
            let accountKey = email.accountEmail?.lowercased() ?? "unknown"
            let key = "\(accountKey)::\(email.threadId)"
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            deduped.append(email)
        }
        return deduped
    }

    // MARK: - Filter Counts

    private func updateFilterCounts() {
        scheduleRecompute()
    }

#if DEBUG
    func refreshViewStateForTests() async -> InboxViewState {
        let state = await inboxWorker.computeState(
            emails: emails,
            currentTab: currentTab,
            pinnedTabOption: pinnedTabOption,
            activeFilter: activeFilter,
            currentAccountEmail: currentAccountEmail
        )
        viewState = state
        return state
    }
#endif

    // MARK: - Actions

    func refresh() async {
        await loadEmails()
    }

    func preloadCachedEmails(mailbox: Mailbox, accountEmail: String?) {
        guard emails.isEmpty else { return }
        let cached = EmailCacheManager.shared.loadCachedEmails(
            mailbox: mailbox,
            limit: 60,
            accountEmail: accountEmail
        )
        guard !cached.isEmpty else { return }
        emails = dedupeByThread(cached)
        updateCachePagingAnchor()
        updateFilterCounts()
    }

    private func updateCachePagingAnchor() {
        cachePagingState.oldestLoadedDate = emails.map(\.date).min()
        cachePagingState.isExhausted = false
        lastFallbackFetchBefore = nil
        fallbackEmptyCount = 0
        updatePagingDebug(path: "anchor", action: "reset")
    }

    private func loadMoreFromCacheIfAvailable() async -> Bool {
        if cachePagingState.isExhausted {
            updatePagingDebug(path: "cache", action: "exhausted")
            return false
        }
        updatePagingDebug(path: "cache", action: "start")
        let accountEmail = currentMailbox == .allInboxes
            ? nil
            : currentAccountEmail?.lowercased()
        let cached = EmailCacheManager.shared.loadCachedEmailsPage(
            mailbox: currentMailbox,
            limit: cachePageSize,
            accountEmail: accountEmail,
            beforeDate: cachePagingState.oldestLoadedDate
        )
        guard !cached.isEmpty else {
            cachePagingState.isExhausted = true
            updatePagingDebug(path: "cache", action: "empty")
            return false
        }

        let uniqueNewEmails: [Email]
        if conversationThreading {
            let existingThreadIds = Set(emails.map { $0.threadId })
            uniqueNewEmails = cached.filter { !existingThreadIds.contains($0.threadId) }
        } else {
            let existingIds = Set(emails.map { $0.id })
            uniqueNewEmails = cached.filter { !existingIds.contains($0.id) }
        }

        if uniqueNewEmails.isEmpty {
            cachePagingState.oldestLoadedDate = cached.map(\.date).min()
            updatePagingDebug(path: "cache", action: "duplicates", fetched: cached.count)
            return false
        }

        emails.append(contentsOf: uniqueNewEmails)
        cachePagingState.oldestLoadedDate = emails.map(\.date).min()
        updateFilterCounts()
        fallbackEmptyCount = 0
        updatePagingDebug(path: "cache", action: "appended", fetched: cached.count, appended: uniqueNewEmails.count)
        return true
    }

    private func loadMoreFromNetworkByDate(before date: Date) async -> Bool {
        if lastFallbackFetchBefore == date {
            updatePagingDebug(path: "date", action: "same-date-skip")
            return false
        }
        lastFallbackFetchBefore = date
        updatePagingDebug(path: "date", action: "start")

        if currentMailbox == .allInboxes {
            await loadMoreUnifiedByDate()
            return true
        }

        let dateQuery = formatBeforeQuery(date)
        let mailboxQuery = mailboxQuery(for: currentMailbox)
        let combinedQuery: String? = {
            guard let mailboxQuery, !mailboxQuery.isEmpty else { return dateQuery }
            return "\(mailboxQuery) \(dateQuery)"
        }()

        guard !isLoadingMore else { return false }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let labelIds = labelIdsForMailbox(currentMailbox)
            let (moreEmails, _) = try await GmailService.shared.fetchInbox(
                query: combinedQuery,
                maxResults: 50,
                labelIds: labelIds
            )
            guard !moreEmails.isEmpty else {
                cachePagingState.isExhausted = true
                updatePagingDebug(path: "date", action: "empty")
                return false
            }
            let moreEmailModels = moreEmails.map(Email.init(dto:))
            let uniqueNewEmails: [Email]
            if conversationThreading {
                let existingThreadIds = Set(emails.map { $0.threadId })
                uniqueNewEmails = moreEmailModels.filter { !existingThreadIds.contains($0.threadId) }
            } else {
                let existingIds = Set(emails.map { $0.id })
                uniqueNewEmails = moreEmailModels.filter { !existingIds.contains($0.id) }
            }
            let fetchedOldest = moreEmails.map(\.date).min()
            if !uniqueNewEmails.isEmpty {
                emails.append(contentsOf: uniqueNewEmails)
                cachePagingState.oldestLoadedDate = emails.map(\.date).min()
                EmailCacheManager.shared.cacheEmails(moreEmails, isFullInboxFetch: false)
                updateFilterCounts()
                fallbackEmptyCount = 0
                updatePagingDebug(path: "date", action: "appended", fetched: moreEmails.count, appended: uniqueNewEmails.count)
                return true
            }

            if let fetchedOldest, fetchedOldest < date {
                cachePagingState.oldestLoadedDate = fetchedOldest
                lastFallbackFetchBefore = fetchedOldest
                fallbackEmptyCount = 0
                updatePagingDebug(path: "date", action: "duplicates-advance", fetched: moreEmails.count)
            } else {
                fallbackEmptyCount += 1
                if fallbackEmptyCount <= 3 {
                    let calendar = Calendar.current
                    if let stepped = calendar.date(byAdding: .day, value: -1, to: date) {
                        cachePagingState.oldestLoadedDate = calendar.startOfDay(for: stepped)
                        lastFallbackFetchBefore = cachePagingState.oldestLoadedDate
                        updatePagingDebug(path: "date", action: "step-back", fetched: moreEmails.count)
                    }
                } else {
                    cachePagingState.isExhausted = true
                    updatePagingDebug(path: "date", action: "exhausted", fetched: moreEmails.count)
                }
            }
            return false
        } catch {
            logger.error("Failed to load more emails by date: \(error.localizedDescription)")
            self.error = error
            updatePagingDebug(path: "date", action: "error")
            return false
        }
    }

    private func loadMoreUnifiedByDate() async {
        guard !isLoadingMore else { return }
        guard let oldestDate = cachePagingState.oldestLoadedDate else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        updatePagingDebug(path: "unified-date", action: "start")

        let dateQuery = formatBeforeQuery(oldestDate)
        let mailboxQuery = mailboxQuery(for: currentMailbox)
        let combinedQuery: String? = {
            guard let mailboxQuery, !mailboxQuery.isEmpty else { return dateQuery }
            return "\(mailboxQuery) \(dateQuery)"
        }()

        let accounts = AuthService.shared.accounts
        guard !accounts.isEmpty else { return }

        var fetched: [EmailDTO] = []
        await withTaskGroup(of: [EmailDTO].self) { group in
            for account in accounts {
                group.addTask {
                    do {
                        let (emails, _) = try await GmailService.shared.fetchInbox(
                            for: account,
                            query: combinedQuery,
                            maxResults: 50,
                            labelIds: ["INBOX"]
                        )
                        return emails
                    } catch {
                        logger.error("Unified inbox backfill failed for \(account.email): \(error.localizedDescription)")
                        return []
                    }
                }
            }
            for await emails in group {
                fetched.append(contentsOf: emails)
            }
        }

        guard !fetched.isEmpty else {
            cachePagingState.isExhausted = true
            updatePagingDebug(path: "unified-date", action: "empty")
            return
        }

        let moreEmailModels = fetched.map(Email.init(dto:))
        let uniqueNewEmails: [Email]
        if conversationThreading {
            let existingThreadIds = Set(emails.map { $0.threadId })
            uniqueNewEmails = moreEmailModels.filter { !existingThreadIds.contains($0.threadId) }
        } else {
            let existingIds = Set(emails.map { $0.id })
            uniqueNewEmails = moreEmailModels.filter { !existingIds.contains($0.id) }
        }

        let fetchedOldest = fetched.map(\.date).min()
        if !uniqueNewEmails.isEmpty {
            emails.append(contentsOf: uniqueNewEmails)
            cachePagingState.oldestLoadedDate = emails.map(\.date).min()
            EmailCacheManager.shared.cacheEmails(fetched, isFullInboxFetch: false)
            updateFilterCounts()
            fallbackEmptyCount = 0
            updatePagingDebug(path: "unified-date", action: "appended", fetched: fetched.count, appended: uniqueNewEmails.count)
            return
        }

        if let fetchedOldest, fetchedOldest < oldestDate {
            cachePagingState.oldestLoadedDate = fetchedOldest
            lastFallbackFetchBefore = fetchedOldest
            fallbackEmptyCount = 0
            updatePagingDebug(path: "unified-date", action: "duplicates-advance", fetched: fetched.count)
        } else {
            fallbackEmptyCount += 1
            if fallbackEmptyCount <= 3 {
                let calendar = Calendar.current
                if let stepped = calendar.date(byAdding: .day, value: -1, to: oldestDate) {
                    cachePagingState.oldestLoadedDate = calendar.startOfDay(for: stepped)
                    lastFallbackFetchBefore = cachePagingState.oldestLoadedDate
                    updatePagingDebug(path: "unified-date", action: "step-back", fetched: fetched.count)
                }
            } else {
                cachePagingState.isExhausted = true
                updatePagingDebug(path: "unified-date", action: "exhausted", fetched: fetched.count)
            }
        }
    }

    private func formatBeforeQuery(_ date: Date) -> String {
        // Gmail interprets date-only queries in the user's local timezone.
        // Use the local day boundary to avoid getting "stuck" on the same day.
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        return "before:\(formatter.string(from: startOfDay))"
    }

    private func applySnapshotOrCachedEmails() {
        let accountEmail = currentMailbox == .allInboxes
            ? nil
            : currentAccountEmail?.lowercased()
        if let snapshot = AccountSnapshotStore.shared.snapshot(
            accountEmail: accountEmail,
            mailbox: currentMailbox
        ) {
            if snapshot.matches(
                currentTab: currentTab,
                pinnedTabOption: pinnedTabOption,
                activeFilter: activeFilter
            ) {
                emails = snapshot.emails
                viewState = snapshot.viewState
                nextPageToken = snapshot.nextPageToken
                updateCachePagingAnchor()
                return
            }
        }

        let cached = EmailCacheManager.shared.loadCachedEmails(
            mailbox: currentMailbox,
            limit: 100,
            accountEmail: currentMailbox == .allInboxes ? nil : accountEmail
        )
        if !cached.isEmpty {
            emails = dedupeByThread(cached)
            nextPageToken = nil
            updateCachePagingAnchor()
        }
    }

    private func saveSnapshotIfNeeded(
        emails: [Email],
        viewState: InboxViewState,
        currentTab: InboxTab,
        pinnedTabOption: PinnedTabOption,
        activeFilter: InboxFilter?,
        mailbox: Mailbox,
        nextPageToken: String?
    ) {
        let accountEmail = mailbox == .allInboxes
            ? nil
            : currentAccountEmail?.lowercased()
        AccountSnapshotStore.shared.saveSnapshot(
            accountEmail: accountEmail,
            mailbox: mailbox,
            currentTab: currentTab,
            pinnedTabOption: pinnedTabOption,
            activeFilter: activeFilter,
            emails: emails,
            viewState: viewState,
            nextPageToken: nextPageToken
        )
    }

    private func scheduleSummaryCandidates(for emails: [Email], deferHeavyWork: Bool) {
        Task.detached(priority: .utility) {
            let delay: Duration = deferHeavyWork ? .seconds(1) : .milliseconds(350)
            try? await Task.sleep(for: delay)
            let candidates = emails.compactMap { email -> SummaryQueue.Candidate? in
                guard let accountEmail = email.accountEmail else { return nil }
                return SummaryQueue.Candidate(
                    emailId: email.id,
                    threadId: email.threadId,
                    accountEmail: accountEmail,
                    subject: email.subject,
                    from: email.from,
                    snippet: email.snippet,
                    date: email.date,
                    isUnread: email.isUnread,
                    isStarred: email.isStarred,
                    listUnsubscribe: email.listUnsubscribe
                )
            }
            await SummaryQueue.shared.enqueueCandidates(candidates)
        }
    }

    func archiveEmail(_ email: Email) {
        // Cancel any existing undo task and finalize it
        if let pendingArchive {
            undoTask?.cancel()
            finalizeArchive(pendingArchive.email)
        }
        if let pendingBulkAction {
            undoTask?.cancel()
            finalizeBulkAction(pendingBulkAction)
        }

        // Find the email's current index before removing
        guard let index = emails.firstIndex(where: { $0.id == email.id }) else { return }

        // Store pending archive for potential undo
        pendingArchive = PendingArchive(email: email, index: index)

        // Optimistic update - remove from list immediately
        animate(.easeOut(duration: 0.25)) {
            emails.remove(at: index)
        }
        updateFilterCounts()
        HapticFeedback.medium()

        // Show undo toast
        undoToastMessage = "Email Archived"
        animate(.spring(response: 0.3, dampingFraction: 0.8)) {
            showingUndoToast = true
        }

        let delaySeconds = undoDelaySeconds()
        startUndoCountdown(seconds: delaySeconds)

        // Start countdown to finalize
        let emailId = email.id
        undoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))

            // Check if task was cancelled (user tapped undo)
            guard !Task.isCancelled else { return }

            // Finalize the archive
            guard let self else { return }
            if let pendingArchive, pendingArchive.email.id == emailId {
                finalizeArchive(pendingArchive.email)
            }
        }
    }

    func undoArchive() {
        // Cancel the pending archive task
        clearUndoState()

        if let pendingBulkAction {
            restoreBulkAction(pendingBulkAction)
        } else if let pendingArchive {
            animate(.spring(response: 0.3, dampingFraction: 0.8)) {
                let insertIndex = min(pendingArchive.index, emails.count)
                emails.insert(pendingArchive.email, at: insertIndex)
                showingUndoToast = false
            }
            self.pendingArchive = nil
        }

        updateFilterCounts()
        HapticFeedback.light()
    }

    private func finalizeArchive(_ email: Email) {
        clearUndoState()
        pendingArchive = nil

        // Call Gmail API to actually archive
        let messageId = email.id
        let account = accountForEmail(email)
        Task {
            do {
                if let account {
                    try await GmailService.shared.archive(messageId: messageId, account: account)
                } else {
                    try await GmailService.shared.archive(messageId: messageId)
                }
                logger.info("Email archived: \(messageId)")
            } catch {
                // Rollback on failure - reload emails
                logger.error("Failed to archive email: \(error.localizedDescription)")
                self.error = error
                await loadEmails()
            }
        }
    }

    func trashEmail(_ email: Email) {
        animate {
            emails.removeAll { $0.id == email.id }
        }
        updateFilterCounts()
        HapticFeedback.medium()

        let messageId = email.id
        let account = accountForEmail(email)
        Task {
            do {
                if let account {
                    try await GmailService.shared.trash(messageId: messageId, account: account)
                } else {
                    try await GmailService.shared.trash(messageId: messageId)
                }
            } catch {
                self.error = error
                await loadEmails()
            }
        }
    }

    func starEmail(_ email: Email) {
        if let index = emails.firstIndex(where: { $0.id == email.id }) {
            let wasStarred = emails[index].isStarred
            emails[index].isStarred.toggle()
            HapticFeedback.light()

            let messageId = email.id
            let account = accountForEmail(email)
            Task {
                do {
                    if wasStarred {
                        if let account {
                            try await GmailService.shared.unstar(messageId: messageId, account: account)
                        } else {
                            try await GmailService.shared.unstar(messageId: messageId)
                        }
                    } else {
                        if let account {
                            try await GmailService.shared.star(messageId: messageId, account: account)
                        } else {
                            try await GmailService.shared.star(messageId: messageId)
                        }
                    }
                } catch {
                    // Rollback
                    if let idx = emails.firstIndex(where: { $0.id == messageId }) {
                        emails[idx].isStarred = wasStarred
                    }
                    self.error = error
                }
            }
        }
    }

    func snoozeEmail(_ email: Email, until date: Date) {
        // Archive the email optimistically
        animate {
            emails.removeAll { $0.id == email.id }
        }
        updateFilterCounts()
        HapticFeedback.medium()

        let messageId = email.id
        let account = accountForEmail(email)
        let emailDTO = email.toDTO()
        Task {
            do {
                // Archive via Gmail
                if let account {
                    try await GmailService.shared.archive(messageId: messageId, account: account)
                } else {
                    try await GmailService.shared.archive(messageId: messageId)
                }

                // Save snooze to local database for unsnoozing later
                await SnoozeManager.shared.snoozeEmail(emailDTO, until: date)
            } catch {
                self.error = error
                await loadEmails()
            }
        }
    }

    func toggleRead(_ email: Email) {
        if let index = emails.firstIndex(where: { $0.id == email.id }) {
            let wasUnread = emails[index].isUnread
            emails[index].isUnread.toggle()
            updateFilterCounts()
            HapticFeedback.light()

            let messageId = email.id
            let account = accountForEmail(email)
            Task {
                do {
                    if wasUnread {
                        if let account {
                            try await GmailService.shared.markAsRead(messageId: messageId, account: account)
                        } else {
                            try await GmailService.shared.markAsRead(messageId: messageId)
                        }
                    } else {
                        if let account {
                            try await GmailService.shared.markAsUnread(messageId: messageId, account: account)
                        } else {
                            try await GmailService.shared.markAsUnread(messageId: messageId)
                        }
                    }
                } catch {
                    // Rollback
                    if let idx = emails.firstIndex(where: { $0.id == messageId }) {
                        emails[idx].isUnread = wasUnread
                    }
                    updateFilterCounts()
                    self.error = error
                }
            }
        }
    }

    func blockSender(_ email: Email) {
        let senderEmail = email.senderEmail.lowercased()

        // Add to blocked senders list
        let accountEmail = email.accountEmail ?? AuthService.shared.currentAccount?.email
        var blockedSenders = AccountDefaults.stringArray(for: "blockedSenders", accountEmail: accountEmail)
        if !blockedSenders.contains(senderEmail) {
            blockedSenders.append(senderEmail)
            AccountDefaults.setStringArray(blockedSenders, for: "blockedSenders", accountEmail: accountEmail)
        }

        // Force re-filter to hide emails from this sender
        filterVersion += 1

        // Also trash the email
        trashEmail(email)
        HapticFeedback.success()
    }

    func reportSpam(_ email: Email) {
        animate {
            emails.removeAll { $0.id == email.id }
        }
        updateFilterCounts()
        HapticFeedback.medium()

        let messageId = email.id
        let account = accountForEmail(email)
        Task {
            do {
                if let account {
                    try await GmailService.shared.reportSpam(messageId: messageId, account: account)
                } else {
                    try await GmailService.shared.reportSpam(messageId: messageId)
                }
            } catch {
                self.error = error
                await loadEmails()
            }
        }
    }

    // MARK: - Unified Inbox

    private func fetchUnifiedInbox(
        accounts: [AuthService.Account],
        query: String?,
        labelIds: [String]
    ) async throws -> [EmailDTO] {
        guard !accounts.isEmpty else { return [] }

        var allEmails: [EmailDTO] = []
        await withTaskGroup(of: [EmailDTO].self) { group in
            for account in accounts {
                group.addTask {
                    do {
                        let (emails, _) = try await GmailService.shared.fetchInbox(
                            for: account,
                            query: query,
                            maxResults: 50,
                            labelIds: labelIds
                        )
                        return emails
                    } catch {
                        logger.error("Unified inbox fetch failed for \(account.email): \(error.localizedDescription)")
                        return []
                    }
                }
            }

            for await emails in group {
                allEmails.append(contentsOf: emails)
            }
        }

        return allEmails
    }

    func selectMailbox(_ mailbox: Mailbox) {
        guard mailbox != currentMailbox else { return }
        currentMailbox = mailbox
        emails = []
        Task {
            await loadEmails()
        }
    }

    func openEmail(_ email: Email) {
        selectedEmail = email
        showingEmailDetail = true

        // Mark as read when opening
        if email.isUnread {
            if let index = emails.firstIndex(where: { $0.id == email.id }) {
                emails[index].isUnread = false
                updateFilterCounts()
            }
            let messageId = email.id
            let account = accountForEmail(email)
            Task {
                do {
                    if let account {
                        try await GmailService.shared.markAsRead(messageId: messageId, account: account)
                    } else {
                        try await GmailService.shared.markAsRead(messageId: messageId)
                    }
                } catch {
                    logger.error("Failed to mark email as read: \(error.localizedDescription)")
                }
            }
        }
    }

    func openSearch() {
        // Handled by navigation in InboxView
    }

    func openCompose() {
        // Handled by navigation in InboxView
    }

    func openSettings() {
        // Handled by navigation in InboxView
    }

    // MARK: - Search

    func performSearch(query: String) async {
        guard !query.isEmpty else {
            clearSearch()
            return
        }

        isSearching = true
        currentSearchQuery = query

        do {
            // Perform search via Gmail API
            let account = AuthService.shared.currentAccount
            let results = try await GmailService.shared.search(
                query: query,
                maxResults: 50
            )
            searchResults = results.map { dto in
                let email = Email(dto: dto)
                email.accountEmail = account?.email ?? ""
                return email
            }
            isSearchActive = true
        } catch {
            logger.error("Search failed: \(error.localizedDescription)")
            self.error = error
        }

        isSearching = false
    }

    func clearSearch() {
        isSearchActive = false
        searchResults = []
        currentSearchQuery = ""
        isSearching = false
        localSearchResults = []
    }

    func performLocalSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            localSearchResults = []
            return
        }

        let accountEmail = currentMailbox == .allInboxes
            ? nil
            : AuthService.shared.currentAccount?.email.lowercased()
        do {
            let ids = try await SearchIndexManager.shared.search(
                query: trimmed,
                accountEmail: accountEmail
            )
            localSearchResults = EmailCacheManager.shared.loadCachedEmails(
                by: ids,
                accountEmail: accountEmail
            )
        } catch {
            logger.error("Local search failed: \(error.localizedDescription)")
            localSearchResults = []
        }
    }

    // MARK: - Bulk Actions

    func bulkArchive(threadIds: Set<String>) {
        performUndoableBulkAction(threadIds: threadIds, action: .archive)
    }

    func bulkTrash(threadIds: Set<String>) {
        performUndoableBulkAction(threadIds: threadIds, action: .trash)
    }

    func bulkMarkRead(threadIds: Set<String>) {
        performBulkAction(threadIds: threadIds, action: "Mark as read") { email, account in
            try await GmailService.shared.markAsRead(messageId: email.id, account: account)
        }
    }

    func bulkMarkUnread(threadIds: Set<String>) {
        performBulkAction(threadIds: threadIds, action: "Mark as unread") { email, account in
            try await GmailService.shared.markAsUnread(messageId: email.id, account: account)
        }
    }

    func bulkStar(threadIds: Set<String>) {
        performBulkAction(threadIds: threadIds, action: "Star") { email, account in
            try await GmailService.shared.star(messageId: email.id, account: account)
        }
    }

    func bulkUnstar(threadIds: Set<String>) {
        performBulkAction(threadIds: threadIds, action: "Unstar") { email, account in
            try await GmailService.shared.unstar(messageId: email.id, account: account)
        }
    }

    func bulkMoveToInbox(threadIds: Set<String>) {
        performBulkAction(threadIds: threadIds, action: "Move to inbox") { email, account in
            try await GmailService.shared.unarchive(messageId: email.id, account: account)
        }
    }

    func bulkSnooze(threadIds: Set<String>, until date: Date) {
        performBulkAction(threadIds: threadIds, action: "Snooze") { email, account in
            try await GmailService.shared.archive(messageId: email.id, account: account)
            await SnoozeManager.shared.snoozeEmail(email.toDTO(), until: date)
        }
    }

    func retryPendingMutations() {
        // Placeholder for retry logic
        bulkToastMessage = nil
    }

    private func performBulkAction(
        threadIds: Set<String>,
        action: String,
        operation: @escaping (Email, AuthService.Account) async throws -> Void
    ) {
        let affectedEmails = emails.filter { threadIds.contains($0.threadId) }
        guard !affectedEmails.isEmpty else { return }

        // Remove from UI optimistically
        animate {
            emails.removeAll { threadIds.contains($0.threadId) }
        }
        updateFilterCounts()

        Task {
            var failedCount = 0

            for email in affectedEmails {
                guard let account = accountForEmail(email) else {
                    failedCount += 1
                    continue
                }

                do {
                    try await operation(email, account)
                } catch {
                    logger.error("Bulk action failed for \(email.id): \(error.localizedDescription)")
                    failedCount += 1
                }
            }

            if failedCount > 0 {
                bulkToastMessage = "\(action) failed for \(failedCount) email(s)"
                bulkToastIsError = true
                bulkToastShowsRetry = true
            } else {
                bulkToastMessage = "\(action) successful (\(affectedEmails.count) email(s))"
                bulkToastIsError = false
                bulkToastShowsRetry = false
            }

            // Clear toast after 3 seconds
            try? await Task.sleep(for: .seconds(3))
            bulkToastMessage = nil
        }
    }

    private func performUndoableBulkAction(threadIds: Set<String>, action: PendingBulkActionType) {
        let pendingItems = emails.enumerated().compactMap { index, email in
            threadIds.contains(email.threadId) ? PendingBulkItem(email: email, index: index) : nil
        }
        guard !pendingItems.isEmpty else { return }

        if let pendingArchive {
            undoTask?.cancel()
            finalizeArchive(pendingArchive.email)
        }
        if let pendingBulkAction {
            undoTask?.cancel()
            finalizeBulkAction(pendingBulkAction)
        }

        animate {
            emails.removeAll { threadIds.contains($0.threadId) }
        }
        updateFilterCounts()

        pendingBulkAction = PendingBulkAction(items: pendingItems, action: action)
        undoToastMessage = action == .archive ? "Archived" : "Moved to Trash"
        animate(.spring(response: 0.3, dampingFraction: 0.8)) {
            showingUndoToast = true
        }

        let delaySeconds = undoDelaySeconds()
        startUndoCountdown(seconds: delaySeconds)

        undoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            guard let self, let pending = self.pendingBulkAction else { return }
            self.finalizeBulkAction(pending)
        }
    }

    private func restoreBulkAction(_ pending: PendingBulkAction) {
        let sorted = pending.items.sorted { $0.index < $1.index }
        animate(.spring(response: 0.3, dampingFraction: 0.8)) {
            for item in sorted {
                let insertIndex = min(item.index, emails.count)
                emails.insert(item.email, at: insertIndex)
            }
            showingUndoToast = false
        }
        pendingBulkAction = nil
    }

    private func finalizeBulkAction(_ pending: PendingBulkAction) {
        clearUndoState()
        pendingBulkAction = nil

        Task {
            var failedCount = 0

            for item in pending.items {
                guard let account = accountForEmail(item.email) else {
                    failedCount += 1
                    continue
                }

                do {
                    switch pending.action {
                    case .archive:
                        try await GmailService.shared.archive(messageId: item.email.id, account: account)
                    case .trash:
                        try await GmailService.shared.trash(messageId: item.email.id, account: account)
                    }
                } catch {
                    logger.error("Bulk action failed for \(item.email.id): \(error.localizedDescription)")
                    failedCount += 1
                }
            }

            if failedCount > 0 {
                bulkToastMessage = "Action failed for \(failedCount) email(s)"
                bulkToastIsError = true
                bulkToastShowsRetry = true
                try? await Task.sleep(for: .seconds(3))
                bulkToastMessage = nil
            }
        }
    }

    private func undoDelaySeconds() -> Int {
        let accountEmail = AuthService.shared.currentAccount?.email
        if let data = AccountDefaults.data(for: "appSettings", accountEmail: accountEmail),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings.undoSendDelaySeconds
        }
        return 5
    }

    private func startUndoCountdown(seconds: Int) {
        undoCountdownTask?.cancel()
        undoRemainingSeconds = seconds
        guard seconds > 0 else { return }
        undoCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: seconds, through: 1, by: -1) {
                self.undoRemainingSeconds = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self.undoRemainingSeconds = 0
        }
    }

    private func clearUndoState() {
        undoTask?.cancel()
        undoTask = nil
        undoCountdownTask?.cancel()
        undoCountdownTask = nil
        undoRemainingSeconds = 0
        animate(.easeOut(duration: 0.2)) {
            showingUndoToast = false
        }
    }

#if DEBUG
    func refreshFiltersForTest() {
        filterVersion += 1
        updateFilterCounts()
    }
#endif

}
