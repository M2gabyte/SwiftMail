import Foundation
import SwiftUI
import SwiftData
import OSLog
import Combine
import Foundation

// Background helper to keep network + parsing off the main actor.
actor InboxFetchWorker {
    func fetchPage(
        query: String?,
        pageToken: String?,
        pageSize: Int,
        labelIds: [String]
    ) async throws -> ([EmailDTO], String?) {
        try await GmailService.shared.fetchInbox(
            query: query,
            maxResults: pageSize,
            pageToken: pageToken,
            labelIds: labelIds
        )
    }
}

// MARK: - Inbox ViewModel

private let logger = Logger(subsystem: "com.simplemail.app", category: "InboxViewModel")

// Notification for when blocked senders list changes
extension Notification.Name {
    static let blockedSendersDidChange = Notification.Name("blockedSendersDidChange")
    static let cachesDidClear = Notification.Name("cachesDidClear")
    static let archiveThreadRequested = Notification.Name("archiveThreadRequested")
    static let trashThreadRequested = Notification.Name("trashThreadRequested")
    static let archiveMessageRequested = Notification.Name("archiveMessageRequested")
    static let trashMessageRequested = Notification.Name("trashMessageRequested")
    static let emailArchivedFromDetail = Notification.Name("emailArchivedFromDetail")
    static let emailTrashedFromDetail = Notification.Name("emailTrashedFromDetail")
    static let singleMessageActionUndone = Notification.Name("singleMessageActionUndone")
    static let movedToPrimaryRequested = Notification.Name("movedToPrimaryRequested")
    static let senderBlocked = Notification.Name("senderBlocked")
    static let spamReported = Notification.Name("spamReported")
    static let unsubscribed = Notification.Name("unsubscribed")
}

@MainActor
@Observable
final class InboxViewModel: ObservableObject {
    // MARK: - Shared Instance

    /// Singleton instance to prevent multiple ViewModels from being created
    /// and each starting their own prefetch loops
    nonisolated(unsafe) private static var _shared: InboxViewModel?

    static var shared: InboxViewModel {
        if let existing = _shared {
            return existing
        }
        let instance = InboxViewModel()
        _shared = instance
        return instance
    }

    /// Reset all state - call on sign out to clear cached data
    func reset() {
        emails = []
        viewState = InboxViewState()
        pendingState = nil
        isBootstrapping = true  // Re-enable bootstrap batching for next sign-in
        currentTab = .all
        activeFilter = nil
        viewingCategory = nil
        currentMailbox = .inbox
        isLoading = false
        isLoadingMore = false
        error = nil
        selectedEmail = nil
        showingEmailDetail = false
        searchResults = []
        isSearchActive = false
        isSearching = false
        currentSearchQuery = ""
        localSearchResults = []
        searchFilter = nil
        nextPageToken = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        preloadTask?.cancel()
        preloadTask = nil
        localSearchTask?.cancel()
        localSearchTask = nil
        didPreloadCache = false
        isLoadInProgress = false
        hasCompletedInitialLoad = false
        currentAccountEmail = nil
        logger.info("InboxViewModel reset")
    }

    // MARK: - Swipe Lifecycle

    /// Call when a swipe gesture begins to pause list mutations
    func swipeDidBegin() {
        isSwipeActive = true
        // Cancel background prefetch during swipe to avoid competing mutations
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    /// Call when a swipe gesture ends to apply any deferred mutations
    func swipeDidEnd() {
        isSwipeActive = false
        if let pending = deferredEmails {
            deferredEmails = nil
            applyEmailUpdate(pending)
        }
    }

    /// Apply email update, deferring if a swipe is active
    private func applyEmailUpdate(_ newEmails: [Email]) {
        if isSwipeActive {
            deferredEmails = newEmails
            return
        }
        StallLogger.mark("applyEmailUpdate.start count=\(newEmails.count)")
        emails = newEmails
        StallLogger.mark("applyEmailUpdate.end")
    }

    /// Flag to suppress scheduleRecompute during batched updates
    @ObservationIgnored private var isBatchingUpdates = false

    /// Apply email update without animation (for staged batch updates)
    /// When isFinal=false, skips scheduleRecompute to avoid redundant work
    private func applyEmailUpdateNoAnim(_ newEmails: [Email], isFinal: Bool = false) {
        var txn = Transaction()
        txn.disablesAnimations = true
        if !isFinal {
            isBatchingUpdates = true
        }
        withTransaction(txn) {
            applyEmailUpdate(newEmails)
        }
        if !isFinal {
            isBatchingUpdates = false
        }
    }

    // MARK: - State

    var emails: [Email] = [] {
        didSet {
            scheduleRecompute()
        }
    }
    var currentTab: InboxTab = .all {
        didSet {
            // Clear category drill-down when switching tabs
            if viewingCategory != nil {
                viewingCategory = nil
            }
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
    /// When set, shows only emails from this Gmail category (drill-down from bundle tap)
    var viewingCategory: GmailCategory? = nil {
        didSet {
            scheduleRecompute()
        }
    }
    var currentMailbox: Mailbox = .inbox
    var isLoading = false
    var isLoadingMore = false
    var hasCompletedInitialLoad = false
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
    var searchResults: [EmailDTO] = []
    var isSearching = false
    var currentSearchQuery = ""
    var localSearchResults: [EmailDTO] = []

    /// Parsed search filter for local filtering (computed in background worker)
    var searchFilter: SearchFilter? = nil {
        didSet {
            scheduleRecompute()
        }
    }

    // MARK: - Bulk Actions Toast

    var bulkToastMessage: String?
    var bulkToastIsError = false
    var bulkToastShowsRetry = false

    // MARK: - Navigation

    var selectedEmail: Email?
    var showingEmailDetail = false

    // MARK: - View State

    var viewState = InboxViewState()

    // MARK: - Bootstrap State Batching
    // During startup, buffer state changes to avoid multiple SwiftUI rebuilds.
    // Only publish once when bootstrap completes (preload or first network fetch).

    @ObservationIgnored private var pendingState: InboxViewState?
    @ObservationIgnored private var isBootstrapping = true

    /// Buffer state during bootstrap, publish immediately after.
    private func applyState(_ state: InboxViewState) {
        if isBootstrapping {
            pendingState = state
        } else {
            viewState = state
        }
    }

    /// End bootstrap phase and publish any buffered state.
    func finishBootstrapIfNeeded() {
        guard isBootstrapping else { return }
        StallLogger.mark("finishBootstrap.start hasPending=\(pendingState != nil)")
        isBootstrapping = false
        if let pending = pendingState {
            viewState = pending
            pendingState = nil
        }
        StallLogger.mark("finishBootstrap.end")
    }

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
    //
    // Uses Gmail Threads API with pageToken pagination when threading is enabled.
    // Each page returns unique threads - no deduplication needed, pagination just works.

    /// pageToken from Gmail API for fetching next page
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

    // Pending single message action (from detail view)
    private struct PendingSingleMessageAction {
        let messageId: String
        let threadId: String
        let accountEmail: String?
        let action: PendingBulkActionType
    }
    private var pendingSingleMessageAction: PendingSingleMessageAction?

    struct PendingArchive {
        let email: Email
        let index: Int
    }

    // Pending block/spam action for undo
    private enum BlockSpamActionType { case block, spam }
    private struct PendingBlockSpamAction {
        let email: Email
        let index: Int
        let senderEmail: String
        let senderName: String
        let actionType: BlockSpamActionType
    }
    private var pendingBlockSpamAction: PendingBlockSpamAction?

    // MARK: - Notification Observer
    @ObservationIgnored private var senderBlockedObserver: NSObjectProtocol?
    @ObservationIgnored private var spamReportedObserver: NSObjectProtocol?
    @ObservationIgnored private var blockedSendersObserver: NSObjectProtocol?
    @ObservationIgnored private var accountChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var archiveThreadObserver: NSObjectProtocol?
    @ObservationIgnored private var trashThreadObserver: NSObjectProtocol?
    @ObservationIgnored private var archiveMessageObserver: NSObjectProtocol?
    @ObservationIgnored private var trashMessageObserver: NSObjectProtocol?
    @ObservationIgnored private var emailArchivedFromDetailObserver: NSObjectProtocol?
    @ObservationIgnored private var emailTrashedFromDetailObserver: NSObjectProtocol?
    @ObservationIgnored private var movedToPrimaryObserver: NSObjectProtocol?
    @ObservationIgnored private var inboxPreferencesObserver: NSObjectProtocol?
    @ObservationIgnored private let inboxWorker = InboxStoreWorker()
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var preferredPageSizeCache: Int?
    @ObservationIgnored private var currentAccountEmail: String?
    @ObservationIgnored private var cachePagingState = CachePagingState()
    @ObservationIgnored private var didPreloadCache = false
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private var localSearchTask: Task<Void, Never>?
    @ObservationIgnored private var recomputeGeneration: Int = 0

    // MARK: - Swipe Mutation Protection
    @ObservationIgnored private var isSwipeActive = false
    @ObservationIgnored private var deferredEmails: [Email]?

    private struct CachePagingState {
        var oldestLoadedDate: Date?
        var isExhausted = false
    }

    private let cachePageSize = 120
    private var lastFooterTrigger: Date?
    private let visibleWindowSize = 600
    private let fetchWorker = InboxFetchWorker()

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

    private func preferredPageSize() -> Int {
        if let cached = preferredPageSizeCache { return cached }
        let size: Int
        // Favor smaller pages to reduce main-thread work; networking handles batching.
        size = 50
        preferredPageSizeCache = size
        return size
    }

    // MARK: - Computed Properties

    var emailSections: [EmailSection] {
        viewState.sections
    }

    var categoryBundles: [CategoryBundle] {
        viewState.categoryBundles.sorted { lhs, rhs in
            let lDate = lhs.latestEmail?.date ?? .distantPast
            let rDate = rhs.latestEmail?.date ?? .distantPast
            return lDate > rDate
        }
    }

    /// Gmail-style inline bucket rows (Promotions/Updates/Social) based on unseen mail.
    var bucketRows: [BucketRowModel] {
        guard currentTab == .primary, viewingCategory == nil else { return [] }
        guard currentMailbox == .inbox || currentMailbox == .allInboxes else { return [] }
        let rows = GmailBucket.allCases.compactMap { bucketRowModelIfNeeded(bucket: $0) }
        return rows.sorted { ($0.latestDate ?? .distantPast) > ($1.latestDate ?? .distantPast) }
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
        // Skip during batched updates - only final batch triggers recompute
        guard !isBatchingUpdates else { return }

        StallLogger.mark("scheduleRecompute.start emailCount=\(emails.count)")
        recomputeGeneration += 1
        let generation = recomputeGeneration

        // Capture ONLY raw SwiftData fields on main thread (no regex computation)
        let models = emails

        let mapStart = CFAbsoluteTimeGetCurrent()
        let rawData: [RawEmailData] = models.map { email in
            let labelKey = email.labelIds.sorted().joined(separator: "|")
            return RawEmailData(
                id: email.id,
                threadId: email.threadId,
                date: email.date,
                subject: email.subject,
                snippet: email.snippet,
                from: email.from,
                isUnread: email.isUnread,
                isStarred: email.isStarred,
                hasAttachments: email.hasAttachments,
                accountEmail: email.accountEmail,
                labelIdsKey: labelKey,
                listUnsubscribe: email.listUnsubscribe,
                listId: email.listId,
                precedence: email.precedence,
                autoSubmitted: email.autoSubmitted,
                messagesCount: email.messagesCount
            )
        }
        let mapDuration = (CFAbsoluteTimeGetCurrent() - mapStart) * 1000
        StallLogger.mark("scheduleRecompute.mapped \(rawData.count) emails in \(String(format: "%.1f", mapDuration))ms")

        let currentTabSnapshot = currentTab
        let pinnedSnapshot = pinnedTabOption
        let searchFilterSnapshot = searchFilter
        let activeFilterSnapshot = activeFilter
        let viewingCategorySnapshot = viewingCategory
        let accountSnapshot = currentAccountEmail
        let mailboxSnapshot = currentMailbox
        let pageTokenSnapshot = nextPageToken

        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            guard let self else { return }

            // Debounce/coalesce: let rapid mutations collapse into one recompute.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            guard generation == self.recomputeGeneration else { return }

            StallLogger.mark("InboxViewModel.computeState.start")
            // Regex parsing happens on the actor (off main thread)
            let state = await self.inboxWorker.computeStateFromRaw(
                rawEmails: rawData,
                currentTab: currentTabSnapshot,
                pinnedTabOption: pinnedSnapshot,
                activeFilter: activeFilterSnapshot,
                currentAccountEmail: accountSnapshot,
                searchFilter: searchFilterSnapshot,
                viewingCategory: viewingCategorySnapshot
            )
            StallLogger.mark("InboxViewModel.computeState.end")

            guard !Task.isCancelled else { return }
            guard generation == self.recomputeGeneration else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                StallLogger.mark("scheduleRecompute.applyState.start sections=\(state.sections.count)")
                self.applyState(state)
                StallLogger.mark("scheduleRecompute.applyState.end")
                StallLogger.mark("scheduleRecompute.saveSnapshot.start")
                self.saveSnapshotIfNeeded(
                    emails: models,
                    viewState: state,
                    currentTab: currentTabSnapshot,
                    pinnedTabOption: pinnedSnapshot,
                    activeFilter: activeFilterSnapshot,
                    mailbox: mailboxSnapshot,
                    nextPageToken: pageTokenSnapshot
                )
                StallLogger.mark("scheduleRecompute.saveSnapshot.end")
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
            cacheExhausted: !hasMoreEmails,
            timestamp: Date()
        )
        logger.info("PagingDebug path=\(path) action=\(action) fetched=\(fetched) appended=\(appended) hasMore=\(self.hasMoreEmails)")
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

        archiveMessageObserver = NotificationCenter.default.addObserver(
            forName: .archiveMessageRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let messageId = notification.userInfo?["messageId"] as? String,
                      let threadId = notification.userInfo?["threadId"] as? String else { return }
                let accountEmail = notification.userInfo?["accountEmail"] as? String
                self.performUndoableSingleMessageAction(
                    messageId: messageId,
                    threadId: threadId,
                    accountEmail: accountEmail,
                    action: .archive
                )
            }
        }

        trashMessageObserver = NotificationCenter.default.addObserver(
            forName: .trashMessageRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let messageId = notification.userInfo?["messageId"] as? String,
                      let threadId = notification.userInfo?["threadId"] as? String else { return }
                let accountEmail = notification.userInfo?["accountEmail"] as? String
                self.performUndoableSingleMessageAction(
                    messageId: messageId,
                    threadId: threadId,
                    accountEmail: accountEmail,
                    action: .trash
                )
            }
        }

        movedToPrimaryObserver = NotificationCenter.default.addObserver(
            forName: .movedToPrimaryRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let messageId = notification.userInfo?["messageId"] as? String else { return }
                // Update local email labels to reflect move to Primary
                updateEmailLabelsToPrimary(messageId: messageId)
            }
        }

        // Listen for block/spam actions from EmailDetailView (for undo toast)
        senderBlockedObserver = NotificationCenter.default.addObserver(
            forName: .senderBlocked,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleSenderBlockedNotification(notification)
            }
        }

        spamReportedObserver = NotificationCenter.default.addObserver(
            forName: .spamReported,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleSpamReportedNotification(notification)
            }
        }

        // Preload cached emails FIRST so we have data to show immediately
        preloadCachedEmails(mailbox: currentMailbox, accountEmail: currentAccountEmail)

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
        if let observer = archiveMessageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = trashMessageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = inboxPreferencesObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = senderBlockedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = spamReportedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Load Real Emails

    /// Set to true to force a fresh load even if we have data
    private var forceNextLoad = false

    /// Tracks if a load is currently in progress to prevent concurrent loads
    private var isLoadInProgress = false

    func loadEmails(showLoading: Bool = true, deferHeavyWork: Bool = false, force: Bool = false) async {
        // Prevent concurrent loads - if one is already in progress, skip
        guard !isLoadInProgress else {
            logger.info("Skipping loadEmails - load already in progress")
            return
        }

        // Skip reload if we already have data and are paginating (unless forced)
        // This prevents unnecessary resets during scrolling
        // But don't skip if we only have cached data (placeholder token) - we need fresh data
        let hasCachedDataOnly = nextPageToken == "cached_placeholder"
        if !force && !forceNextLoad && !emails.isEmpty && hasMoreEmails && !hasCachedDataOnly {
            logger.info("Skipping loadEmails - already have \(self.emails.count) emails and paginating")
            return
        }
        forceNextLoad = false
        isLoadInProgress = true

        if showLoading {
            isLoading = true
        }
        // Reset pagination state for fresh load
        nextPageToken = nil
        // Cancel any in-progress prefetch
        prefetchTask?.cancel()
        prefetchTask = nil

        defer {
            if showLoading {
                isLoading = false
            }
            hasCompletedInitialLoad = true
            isLoadInProgress = false
            finishBootstrapIfNeeded()  // First network fetch = bootstrap complete
            updateFilterCounts()
        }

        do {
            if currentMailbox == .allInboxes {
                // Unified inbox: fetch from all accounts
                let accounts = AuthService.shared.accounts
                let query = mailboxQuery(for: currentMailbox)
                let labelIds = labelIdsForMailbox(currentMailbox)
                let fetchedEmails = try await fetchUnifiedInbox(
                    accounts: accounts,
                    query: query,
                    labelIds: labelIds
                )
                let emailModels = fetchedEmails.map(Email.init(dto:))
                let deduped = dedupeByThread(emailModels)

                // Single update - batching causes multiple SwiftUI re-renders which is slower
                applyEmailUpdateNoAnim(deduped, isFinal: true)

                // Unified inbox uses date-based pagination, use placeholder to enable it
                let token: String? = fetchedEmails.count >= 50 ? "unified_date_cursor" : nil
                self.nextPageToken = token
                updateCachePagingAnchor()
                EmailCacheManager.shared.cacheEmails(fetchedEmails, isFullInboxFetch: false)
                scheduleSummaryCandidates(for: emails, deferHeavyWork: deferHeavyWork)
            } else {
                // Single account: simple pageToken pagination (no thread deduping = no starvation)
                let labelIds = labelIdsForMailbox(currentMailbox)
                let query = mailboxQuery(for: currentMailbox)

                let pageSize = preferredPageSize()
                let (fetchedEmails, pageToken) = try await fetchWorker.fetchPage(
                    query: query,
                    pageToken: nil,
                    pageSize: pageSize,
                    labelIds: labelIds
                )

                let emailModels = fetchedEmails.map(Email.init(dto:))
                let deduped = dedupeByThread(emailModels)

                // Single update - batching causes multiple SwiftUI re-renders which is slower
                applyEmailUpdateNoAnim(deduped, isFinal: true)

                self.nextPageToken = pageToken
                updateCachePagingAnchor()
                EmailCacheManager.shared.cacheEmails(fetchedEmails, isFullInboxFetch: currentMailbox == .inbox && pageToken == nil)
                scheduleSummaryCandidates(for: emails, deferHeavyWork: deferHeavyWork)

                // No aggressive prefetch on initial load; we page on demand.
            }
        } catch {
            logger.error("Failed to fetch emails: \(error.localizedDescription)")
            self.error = error

            // Check if this is an auth error - trigger sign out if so
            if let authError = error as? AuthError {
                switch authError {
                case .tokenRefreshFailed, .invalidRefreshToken, .refreshTokenRevoked:
                    logger.warning("Auth token expired - signing out")
                    AuthService.shared.signOut()
                default:
                    break
                }
            }
        }
    }

    // MARK: - Load More (Pagination)
    //
    // Uses Gmail Threads API with pageToken pagination.
    // Each page returns unique threads - no deduplication needed, pagination just works.

    func loadMoreIfNeeded(currentEmail: Email) async {
        await loadMoreIfNeeded(currentEmailId: currentEmail.id)
    }

    func loadMoreIfNeeded(currentEmailId: String) async {
        guard hasMoreEmails, !isLoadingMore else { return }

        // Prefetch threshold: trigger loading when within 15 items of the end
        // This prevents the "hit bottom, pause, load" pattern
        let allEmailIds = viewState.sections.flatMap(\.emails).map(\.id)
        guard let currentIndex = allEmailIds.firstIndex(of: currentEmailId) else { return }

        let remainingItems = allEmailIds.count - currentIndex - 1
        let prefetchThreshold = 15

        if remainingItems <= prefetchThreshold {
            await loadMoreEmails()
        }
    }

    func loadMoreFromFooter() async {
        guard hasMoreEmails, !isLoadingMore else { return }
        // Footer tap loads a single page; background prefetch then tops up one more page
        _ = await loadMoreEmails()
        startPrefetch()
    }

    /// Starts a single prefetch task, cancelling any existing one
    private func startPrefetch() {
        // Don't start prefetch during active swipe to avoid list mutation
        guard !isSwipeActive else { return }
        // Cancel any existing prefetch to avoid concurrent API calls
        prefetchTask?.cancel()
        prefetchTask = Task { await prefetchUntilBuffer() }
    }

    /// Keeps loading emails in background until we have a substantial buffer
    /// This prevents the "scroll to bottom, pause, load more" pattern
    /// Note: GmailService handles rate limiting, so we don't need to add delays here
    private func prefetchUntilBuffer() async {
        // Keep at most one extra page beyond what is already loaded
        let targetBuffer = emails.count + preferredPageSize()
        var consecutiveErrors = 0
        let maxErrors = 5

        while hasMoreEmails && emails.count < targetBuffer && !Task.isCancelled {
            let loaded = await loadMoreEmails()

            if !loaded {
                consecutiveErrors += 1
                if consecutiveErrors >= maxErrors {
                    logger.warning("Prefetch stopping after \(maxErrors) consecutive errors")
                    break
                }
                // Brief pause before retry
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            // Success - reset error count
            // No delay needed here - GmailService handles rate limiting
            consecutiveErrors = 0
        }

        if !Task.isCancelled {
            logger.info("Prefetch complete: \(self.emails.count) emails loaded")
        }
    }

    @discardableResult
    func loadMoreEmails() async -> Bool {
        guard !isLoadingMore else { return false }
        guard let pageToken = nextPageToken else {
            updatePagingDebug(path: "pageToken", action: "no-token")
            return false
        }

        // Special-case: cached placeholder token is NOT a real Gmail pageToken.
        // When we reach the end of cached preload, switch to a real network load.
        if pageToken == "cached_placeholder" {
            updatePagingDebug(path: "pageToken", action: "cached-placeholder->refresh")
            await loadEmails(showLoading: false, deferHeavyWork: true, force: true)
            return true
        }

        if currentMailbox == .allInboxes {
            return await loadMoreUnifiedByDate()
        }

        isLoadingMore = true
        defer { isLoadingMore = false }
        updatePagingDebug(path: "pageToken", action: "start")

        do {
            let labelIds = labelIdsForMailbox(currentMailbox)
            let query = mailboxQuery(for: currentMailbox)

            let pageSize = preferredPageSize()
            let (fetchedEmails, newPageToken) = try await fetchWorker.fetchPage(
                query: query,
                pageToken: pageToken,
                pageSize: pageSize,
                labelIds: labelIds
            )

            self.nextPageToken = newPageToken
            updatePagingDebug(path: "pageToken", action: "fetched", fetched: fetchedEmails.count)

            guard !fetchedEmails.isEmpty else {
                updatePagingDebug(path: "pageToken", action: "empty")
                return false
            }

            EmailCacheManager.shared.cacheEmails(fetchedEmails, isFullInboxFetch: false)

            let fetchedModels = fetchedEmails.map(Email.init(dto:))
            var allEmails = emails
            allEmails.append(contentsOf: fetchedModels)

            // Sort/dedupe is still needed, but avoid a single giant List rebuild
            let merged = dedupeByThread(allEmails)

            // Only apply visible window to avoid rebuilding a much larger List
            let batch1 = min(visibleWindowSize, merged.count)
            applyEmailUpdateNoAnim(Array(merged.prefix(batch1)), isFinal: true)
            trimVisibleWindow()

            cachePagingState.oldestLoadedDate = emails.map(\.date).min()
            updateFilterCounts()

            logger.info("Loaded \(fetchedModels.count) more messages")
            updatePagingDebug(path: "pageToken", action: "done", fetched: fetchedEmails.count, appended: fetchedModels.count)
            return true

        } catch {
            logger.error("Failed to load more: \(error.localizedDescription)")
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
        // Don't dedupe for inbox list - show all messages for smooth pagination
        // Threading/grouping happens in the detail view when you tap a thread
        let sorted = emails.sorted { $0.date > $1.date }

        // Remove exact duplicates (same message ID) but keep different messages from same thread
        var seenIds = Set<String>()
        var result: [Email] = []
        for email in sorted {
            if seenIds.contains(email.id) {
                continue
            }
            seenIds.insert(email.id)
            result.append(email)
        }
        return result
    }

    /// Keep only the most recent visibleWindowSize emails in-memory; older stay in cache.
    private func trimVisibleWindow() {
        guard emails.count > visibleWindowSize else { return }
        applyEmailUpdate(Array(emails.prefix(visibleWindowSize)))
    }

    // MARK: - Filter Counts

    private func updateFilterCounts() {
        scheduleRecompute()
    }

    // MARK: - Gmail Buckets

    private var currentAccountId: String? {
        currentAccountEmail?.lowercased()
    }

    /// Returns cached emails for a given Gmail bucket scoped to the current mailbox.
    private func getMessagesForBucket(_ bucket: GmailBucket) -> [Email] {
        emails.filter { email in
            email.labelIds.contains(bucket.gmailLabel)
        }
    }

    /// Computes a bucket row model if there are unseen messages newer than the last seen marker.
    func bucketRowModelIfNeeded(bucket: GmailBucket) -> BucketRowModel? {
        guard let accountId = currentAccountId else { return nil }

        let messages = getMessagesForBucket(bucket)
        guard !messages.isEmpty else { return nil }

        let totalCount = messages.count
        guard let newestDate = messages.map(\.date).max() else { return nil }
        let newestEmail = messages.max(by: { $0.date < $1.date })?.toDTO()

        let lastSeen = BucketSeenStore.shared.getLastSeenDate(accountEmail: accountId, bucket: bucket)
        let unseenCount: Int
        if let lastSeen {
            unseenCount = messages.filter { $0.date > lastSeen }.count
        } else {
            unseenCount = totalCount
        }

        guard unseenCount > 0 else { return nil }

        return BucketRowModel(
            id: "bucketRow.\(accountId).\(bucket.rawValue)",
            bucket: bucket,
            unseenCount: unseenCount,
            totalCount: totalCount,
            latestEmail: newestEmail,
            latestDate: newestDate
        )
    }

    /// Marks a bucket as seen up to its newest message.
    func markBucketSeen(_ bucket: GmailBucket) {
        guard let accountId = currentAccountId else { return }
        let messages = getMessagesForBucket(bucket)
        guard let newestDate = messages.map(\.date).max() else { return }
        BucketSeenStore.shared.setLastSeenDate(accountEmail: accountId, bucket: bucket, date: newestDate)
        scheduleRecompute()
    }

    /// Total cached messages for a bucket in the current mailbox.
    func bucketTotalCount(_ bucket: GmailBucket) -> Int {
        getMessagesForBucket(bucket).count
    }

    /// Unseen count for a bucket (messages newer than last seen marker).
    func bucketUnseenCount(_ bucket: GmailBucket) -> Int {
        guard let accountId = currentAccountId else { return 0 }
        let messages = getMessagesForBucket(bucket)
        guard !messages.isEmpty else { return 0 }
        if let lastSeen = BucketSeenStore.shared.getLastSeenDate(accountEmail: accountId, bucket: bucket) {
            return messages.filter { $0.date > lastSeen }.count
        }
        return messages.count
    }

#if DEBUG
    func refreshViewStateForTests() async -> InboxViewState {
        let snapshots: [EmailSnapshot] = emails.map { email in
            let labelKey = email.labelIds.sorted().joined(separator: "|")
            return EmailSnapshot(
                id: email.id,
                threadId: email.threadId,
                date: email.date,
                subject: email.subject,
                snippet: email.snippet,
                senderEmail: email.senderEmail,
                senderName: email.senderName,
                isUnread: email.isUnread,
                isStarred: email.isStarred,
                hasAttachments: email.hasAttachments,
                accountEmail: email.accountEmail,
                labelIdsKey: labelKey,
                listUnsubscribe: email.listUnsubscribe,
                listId: email.listId,
                precedence: email.precedence,
                autoSubmitted: email.autoSubmitted,
                messagesCount: email.messagesCount
            )
        }
        let state = await inboxWorker.computeState(
            emails: snapshots,
            currentTab: currentTab,
            pinnedTabOption: pinnedTabOption,
            activeFilter: activeFilter,
            currentAccountEmail: currentAccountEmail,
            searchFilter: searchFilter,
            viewingCategory: viewingCategory
        )
        viewState = state
        return state
    }
#endif

    // MARK: - Actions

    func refresh() async {
        await loadEmails(force: true)
    }

    func preloadCachedEmails(mailbox: Mailbox, accountEmail: String?) {
        // Gate: cache must be configured
        guard EmailCacheManager.shared.isReady else { return }
        // Gate: only run once per session
        guard !didPreloadCache else { return }
        guard emails.isEmpty else {
            didPreloadCache = true  // Mark as done if we already have data
            return
        }

        // Cancel any existing preload
        preloadTask?.cancel()
        preloadTask = Task { @MainActor in
            // Yield to let UI settle first (replaces 150ms sleep for faster startup)
            await Task.yield()
            guard !Task.isCancelled else { return }

            StallLogger.mark("InboxViewModel.preloadCachedEmails.start")

            let cached = EmailCacheManager.shared.loadCachedEmails(
                mailbox: mailbox,
                limit: 60,
                accountEmail: accountEmail
            )

            guard !Task.isCancelled else { return }

            // Mark as done AFTER we've decided what to do
            didPreloadCache = true

            guard !cached.isEmpty else { return }

            // Keep list small: dedupe early to avoid expensive downstream recompute work.
            let deduped = dedupeByThread(cached)

            StallLogger.mark("InboxViewModel.preloadCachedEmails.cacheReady")

            // Single update - batching causes more SwiftUI re-renders (each batch triggers @Observable)
            // which actually makes startup slower than a single update
            StallLogger.mark("preload.applyAll.start count=\(deduped.count)")
            applyEmailUpdateNoAnim(deduped, isFinal: true)
            StallLogger.mark("preload.applyAll.end")

            // Enable pagination until first real fetch
            nextPageToken = "cached_placeholder"

            // Update paging anchor (scheduleRecompute already triggered by emails didSet)
            updateCachePagingAnchor()

            // Cache preload complete - end bootstrap phase
            finishBootstrapIfNeeded()
        }
    }

    private func updateCachePagingAnchor() {
        cachePagingState.oldestLoadedDate = emails.map(\.date).min()
        cachePagingState.isExhausted = false
        updatePagingDebug(path: "anchor", action: "reset")
    }

    /// Unified inbox pagination - fetches from all accounts with date-based query
    @discardableResult
    private func loadMoreUnifiedByDate() async -> Bool {
        isLoadingMore = true
        defer { isLoadingMore = false }

        let accounts = AuthService.shared.accounts
        guard !accounts.isEmpty else { return false }

        let previousCount = emails.count
        var currentCursor = emails.map(\.date).min() ?? Date()

        // Keep fetching until we have new visible content or exhausted
        var attempts = 0
        while attempts < 10 {
            attempts += 1
            updatePagingDebug(path: "unified-date", action: "fetch-\(attempts)")

            let dateQuery = formatBeforeQuery(currentCursor)

            var fetched: [EmailDTO] = []
            await withTaskGroup(of: [EmailDTO].self) { group in
                for account in accounts {
                    group.addTask {
                        do {
                            let (emails, _) = try await GmailService.shared.fetchInbox(
                                for: account,
                                query: dateQuery,
                                maxResults: 100,
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
                nextPageToken = nil
                updatePagingDebug(path: "unified-date", action: "exhausted")
                break
            }

            // Cache and append
            EmailCacheManager.shared.cacheEmails(fetched, isFullInboxFetch: false)
            let fetchedModels = fetched.map(Email.init(dto:))
            var allEmails = emails
            allEmails.append(contentsOf: fetchedModels)
            applyEmailUpdate(dedupeByThread(allEmails))
            trimVisibleWindow()

            // Update cursor for next iteration
            if let oldestFetched = fetched.map(\.date).min() {
                currentCursor = oldestFetched
            }

            // Did we get new visible threads?
            if emails.count > previousCount {
                cachePagingState.oldestLoadedDate = emails.map(\.date).min()
                updateFilterCounts()
                let newCount = emails.count - previousCount
                logger.info("Unified: Loaded \(newCount) new threads after \(attempts) fetches")
                updatePagingDebug(path: "unified-date", action: "done", fetched: attempts * 50, appended: newCount)
                return true
            }

            // Continue fetching older...
        }

        cachePagingState.oldestLoadedDate = emails.map(\.date).min()
        updateFilterCounts()
        return emails.count > previousCount
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
                applyEmailUpdate(snapshot.emails)
                applyState(snapshot.viewState)
                nextPageToken = snapshot.nextPageToken
                updateCachePagingAnchor()
                finishBootstrapIfNeeded()  // Snapshot restore = bootstrap complete
                return
            }
        }

        let cached = EmailCacheManager.shared.loadCachedEmails(
            mailbox: currentMailbox,
            limit: 100,
            accountEmail: currentMailbox == .allInboxes ? nil : accountEmail
        )
        if !cached.isEmpty {
            applyEmailUpdate(dedupeByThread(cached))
            // Set placeholder to enable pagination until real fetch
            nextPageToken = "cached_placeholder"
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
        // IMPORTANT: Build candidates on main thread BEFORE detached task
        // SwiftData @Model objects must not cross actor boundaries
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

        // Now pass only value types to detached task
        Task.detached(priority: .utility) {
            let delay: Duration = deferHeavyWork ? .seconds(1) : .milliseconds(350)
            try? await Task.sleep(for: delay)
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

    /// ID-based overload for use with EmailDTO views
    func archiveEmail(id: String) {
        guard let email = emails.first(where: { $0.id == id }) else { return }
        archiveEmail(email)
    }

    func undoArchive() {
        // Cancel the pending archive task
        clearUndoState()

        // Check for block/spam undo first (different undo mechanism)
        if pendingBlockSpamAction != nil {
            undoBlockSpamAction()
            HapticFeedback.light()
            return
        }

        // Check for single message undo (from detail view)
        if let pending = pendingSingleMessageAction {
            pendingSingleMessageAction = nil
            // Notify detail view to restore the message by reloading the thread
            NotificationCenter.default.post(
                name: .singleMessageActionUndone,
                object: nil,
                userInfo: ["threadId": pending.threadId]
            )
            HapticFeedback.light()
            return
        }

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

    /// ID-based overload for use with EmailDTO views
    func toggleRead(emailId: String) {
        guard let email = emails.first(where: { $0.id == emailId }) else { return }
        toggleRead(email)
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
                            maxResults: 100,
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
        Task { await loadEmails() }
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

    /// ID-based overload for use with EmailDTO views
    func openEmail(id: String) {
        guard let email = emails.first(where: { $0.id == id }) else { return }
        openEmail(email)
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
            // Keep as DTOs for display - action handlers will look up by ID if needed
            searchResults = results.map { dto in
                // Create a new DTO with accountEmail set
                EmailDTO(
                    id: dto.id,
                    threadId: dto.threadId,
                    snippet: dto.snippet,
                    subject: dto.subject,
                    from: dto.from,
                    date: dto.date,
                    isUnread: dto.isUnread,
                    isStarred: dto.isStarred,
                    hasAttachments: dto.hasAttachments,
                    labelIds: dto.labelIds,
                    messagesCount: dto.messagesCount,
                    accountEmail: account?.email,
                    listUnsubscribe: dto.listUnsubscribe,
                    listId: dto.listId,
                    precedence: dto.precedence,
                    autoSubmitted: dto.autoSubmitted
                )
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
        searchFilter = nil  // Clear local search filter
        // Cancel any in-flight search to prevent "ghost work" during transitions
        localSearchTask?.cancel()
        localSearchTask = nil
    }

    /// Debounced local search with cancellation.
    /// NOTE: Non-async since body just spawns a task.
    func performLocalSearch(query: String) {
        // Cancel previous search first (important: do this BEFORE checking empty)
        localSearchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            localSearchTask = nil
            localSearchResults = []
            return
        }

        // Debounce: wait for user to stop typing + let UI animate
        localSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            let accountEmail = await MainActor.run {
                currentMailbox == .allInboxes ? nil : AuthService.shared.currentAccount?.email.lowercased()
            }
            do {
                let ids = try await SearchIndexManager.shared.search(
                    query: trimmed,
                    accountEmail: accountEmail
                )
                guard !Task.isCancelled else { return }

                // Cap IDs to prevent unbounded hydration if search behavior changes
                let limitedIds = Array(ids.prefix(100))

                // Hydrate on background context to avoid blocking main thread
                let dtos = await EmailCacheManager.shared.loadCachedEmailDTOs(
                    by: limitedIds,
                    accountEmail: accountEmail
                )
                guard !Task.isCancelled else { return }

                // Update UI on main
                await MainActor.run {
                    localSearchResults = dtos
                }
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Local search failed: \(error.localizedDescription)")
                await MainActor.run {
                    localSearchResults = []
                }
            }
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

    /// Archive or trash a single message from detail view (with undo support)
    /// This doesn't modify the inbox list directly - it shows an undo toast and makes the API call after delay
    private func performUndoableSingleMessageAction(
        messageId: String,
        threadId: String,
        accountEmail: String?,
        action: PendingBulkActionType
    ) {
        // Cancel any pending operations
        if let pendingArchive {
            undoTask?.cancel()
            finalizeArchive(pendingArchive.email)
        }
        if let pendingBulkAction {
            undoTask?.cancel()
            finalizeBulkAction(pendingBulkAction)
        }
        if pendingSingleMessageAction != nil {
            undoTask?.cancel()
            if let pending = pendingSingleMessageAction {
                finalizeSingleMessageAction(pending)
            }
        }

        // Store the pending action
        pendingSingleMessageAction = PendingSingleMessageAction(
            messageId: messageId,
            threadId: threadId,
            accountEmail: accountEmail,
            action: action
        )

        // Show undo toast
        undoToastMessage = action == .archive ? "Archived" : "Moved to Trash"
        animate(.spring(response: 0.3, dampingFraction: 0.8)) {
            showingUndoToast = true
        }

        let delaySeconds = undoDelaySeconds()
        startUndoCountdown(seconds: delaySeconds)

        undoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            guard let self, let pending = self.pendingSingleMessageAction else { return }
            self.finalizeSingleMessageAction(pending)
        }
    }

    private func finalizeSingleMessageAction(_ pending: PendingSingleMessageAction) {
        clearUndoState()
        pendingSingleMessageAction = nil

        Task {
            do {
                // Get the account for the API call
                let account: AuthService.Account?
                if let email = pending.accountEmail {
                    account = AuthService.shared.accounts.first { $0.email == email }
                } else {
                    account = AuthService.shared.currentAccount
                }

                guard let account else {
                    logger.error("No account found for single message action")
                    return
                }

                switch pending.action {
                case .archive:
                    try await GmailService.shared.archive(messageId: pending.messageId, account: account)
                case .trash:
                    try await GmailService.shared.trash(messageId: pending.messageId, account: account)
                }

                // Refresh inbox to reflect the change
                await refresh()
            } catch {
                logger.error("Single message action failed: \(error.localizedDescription)")
                bulkToastMessage = "Action failed"
                bulkToastIsError = true
                bulkToastShowsRetry = false
                try? await Task.sleep(for: .seconds(3))
                bulkToastMessage = nil
            }
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

    /// Update local email labels when moved to Primary (removes category labels, adds CATEGORY_PERSONAL)
    private func updateEmailLabelsToPrimary(messageId: String) {
        let categoriesToRemove: Set<String> = [
            "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS"
        ]

        // Update the email in the emails array (SwiftData model)
        if let email = emails.first(where: { $0.id == messageId }) {
            var updatedLabels = email.labelIds.filter { !categoriesToRemove.contains($0) }
            if !updatedLabels.contains("CATEGORY_PERSONAL") {
                updatedLabels.append("CATEGORY_PERSONAL")
            }
            email.labelIds = updatedLabels
        }

        // Trigger recompute so category bundles update
        scheduleRecompute()
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

    // MARK: - Block/Spam Undo Support

    private func handleSenderBlockedNotification(_ notification: Notification) {
        guard let senderName = notification.userInfo?["senderName"] as? String,
              let senderEmail = notification.userInfo?["senderEmail"] as? String,
              let threadId = notification.userInfo?["threadId"] as? String else { return }

        // Cancel any existing undo tasks (block notification supersedes trash notification)
        undoTask?.cancel()
        undoTask = nil
        undoCountdownTask?.cancel()
        undoCountdownTask = nil

        // Check if the email was already removed by the trash notification
        // If so, grab it from the pending bulk action (match by threadId)
        var email: Email?
        var idx: Int?

        if let pendingBulk = pendingBulkAction,
           let item = pendingBulk.items.first(where: { $0.email.threadId == threadId }) {
            // Email was removed by trash handler - use its data
            email = item.email
            idx = item.index
            // Clear the pending bulk action since we're taking over
            pendingBulkAction = nil
        } else if let foundIdx = emails.firstIndex(where: { $0.threadId == threadId }) {
            // Email still in list
            email = emails[foundIdx]
            idx = foundIdx
            // Remove from list
            animate {
                emails.remove(at: foundIdx)
            }
            updateFilterCounts()
        }

        guard let email, let idx else { return }

        // Cancel any existing block/spam undo
        if let pending = pendingBlockSpamAction {
            finalizeBlockSpamAction(pending)
        }

        // Store pending action for undo
        pendingBlockSpamAction = PendingBlockSpamAction(
            email: email,
            index: idx,
            senderEmail: senderEmail,
            senderName: senderName,
            actionType: .block
        )

        // Show undo toast
        undoToastMessage = "\(senderName) blocked"
        animate(.spring(response: 0.3, dampingFraction: 0.8)) {
            showingUndoToast = true
        }

        let delaySeconds = undoDelaySeconds()
        startUndoCountdown(seconds: delaySeconds)

        undoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            guard let self, let pending = self.pendingBlockSpamAction else { return }
            self.finalizeBlockSpamAction(pending)
        }
    }

    private func handleSpamReportedNotification(_ notification: Notification) {
        guard let senderName = notification.userInfo?["senderName"] as? String,
              let threadId = notification.userInfo?["threadId"] as? String else { return }

        // Cancel any existing undo tasks
        undoTask?.cancel()
        undoTask = nil
        undoCountdownTask?.cancel()
        undoCountdownTask = nil

        // Find the email (may still be in list since spam doesn't call trash)
        var email: Email?
        var idx: Int?

        if let foundIdx = emails.firstIndex(where: { $0.threadId == threadId }) {
            email = emails[foundIdx]
            idx = foundIdx
            // Remove from list
            animate {
                emails.remove(at: foundIdx)
            }
            updateFilterCounts()
        }

        guard let email, let idx else { return }

        // Cancel any existing block/spam undo
        if let pending = pendingBlockSpamAction {
            finalizeBlockSpamAction(pending)
        }

        // Store pending action for undo
        pendingBlockSpamAction = PendingBlockSpamAction(
            email: email,
            index: idx,
            senderEmail: "",
            senderName: senderName,
            actionType: .spam
        )

        // Show undo toast
        undoToastMessage = "Reported as spam"
        animate(.spring(response: 0.3, dampingFraction: 0.8)) {
            showingUndoToast = true
        }

        let delaySeconds = undoDelaySeconds()
        startUndoCountdown(seconds: delaySeconds)

        undoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            guard let self, let pending = self.pendingBlockSpamAction else { return }
            self.finalizeBlockSpamAction(pending)
        }
    }

    private func undoBlockSpamAction() {
        guard let pending = pendingBlockSpamAction else { return }

        Task {
            do {
                switch pending.actionType {
                case .block:
                    // Remove sender from blocked list
                    let settingsAccountEmail = AuthService.shared.currentAccount?.email
                    var blockedSenders = AccountDefaults.stringArray(for: "blockedSenders", accountEmail: settingsAccountEmail)
                    blockedSenders.removeAll { $0.lowercased() == pending.senderEmail.lowercased() }
                    AccountDefaults.setStringArray(blockedSenders, for: "blockedSenders", accountEmail: settingsAccountEmail)
                    NotificationCenter.default.post(name: .blockedSendersDidChange, object: nil)

                    // Move email back from trash to inbox
                    if let account = accountForEmail(pending.email) {
                        try await GmailService.shared.untrash(messageId: pending.email.id, account: account)
                    } else {
                        try await GmailService.shared.untrash(messageId: pending.email.id)
                    }

                case .spam:
                    // Move email back from spam to inbox
                    if let account = accountForEmail(pending.email) {
                        try await GmailService.shared.unmarkSpam(messageId: pending.email.id, account: account)
                    } else {
                        try await GmailService.shared.unmarkSpam(messageId: pending.email.id)
                    }
                }

                // Restore email to list
                await MainActor.run {
                    let insertIndex = min(pending.index, emails.count)
                    animate(.spring(response: 0.3, dampingFraction: 0.8)) {
                        emails.insert(pending.email, at: insertIndex)
                        showingUndoToast = false
                    }
                    pendingBlockSpamAction = nil
                    updateFilterCounts()
                }
            } catch {
                logger.error("Failed to undo block/spam action: \(error.localizedDescription)")
                await MainActor.run {
                    clearUndoState()
                    pendingBlockSpamAction = nil
                }
            }
        }
    }

    private func finalizeBlockSpamAction(_ pending: PendingBlockSpamAction) {
        // Action already happened on backend (block/spam was called from EmailDetailView)
        // Just clean up state
        clearUndoState()
        pendingBlockSpamAction = nil
    }

#if DEBUG
    func refreshFiltersForTest() {
        filterVersion += 1
        updateFilterCounts()
    }
#endif

}
