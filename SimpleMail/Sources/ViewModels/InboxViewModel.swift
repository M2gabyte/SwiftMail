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
            markSectionsDirty()
        }
    }
    var currentTab: InboxTab = .all {
        didSet {
            markSectionsDirty()
            updateFilterCounts()
        }
    }
    var pinnedTabOption: PinnedTabOption = .other {
        didSet {
            markSectionsDirty()
            updateFilterCounts()
        }
    }
    var activeFilter: InboxFilter? = nil {
        didSet {
            markSectionsDirty()
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
            markSectionsDirty()
        }
    }
    private var sectionsDirty = true
    private var cachedSections: [EmailSection] = []

    // MARK: - Search State

    var isSearchActive = false
    var searchResults: [Email] = []
    var isSearching = false
    var currentSearchQuery = ""

    // MARK: - Bulk Actions Toast

    var bulkToastMessage: String?
    var bulkToastIsError = false
    var bulkToastShowsRetry = false

    // MARK: - Navigation

    var selectedEmail: Email?
    var showingEmailDetail = false

    // MARK: - Filter Counts

    var filterCounts: [InboxFilter: Int] = [:]

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

    // MARK: - Computed Properties

    var emailSections: [EmailSection] {
        if sectionsDirty {
            cachedSections = recomputeSections()
            sectionsDirty = false
        }
        return cachedSections
    }

    /// Last visible email after filtering (for pagination trigger)
    private var lastVisibleEmailId: String? {
        emailSections.last?.emails.last?.id
    }

    private func animate(_ animation: Animation? = .default, _ body: () -> Void) {
        withAnimation(animation, body)
    }

    private func markSectionsDirty() {
        sectionsDirty = true
    }

    private func recomputeSections() -> [EmailSection] {
        let filteredEmails = applyFilters(emails)
        return groupEmailsByDate(filteredEmails)
    }

    // MARK: - Init

    init() {
        InboxPreferences.ensureDefaultsInitialized()
        pinnedTabOption = InboxPreferences.getPinnedTabOption()

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
                await self?.loadEmails()
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

    func loadEmails() async {
        isLoading = true
        nextPageToken = nil
        defer {
            isLoading = false
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
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    let candidates = self.emails.compactMap { email -> SummaryQueue.Candidate? in
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
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    let candidates = self.emails.compactMap { email -> SummaryQueue.Candidate? in
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
              hasMoreEmails,
              !isLoadingMore else {
            return
        }

        await loadMoreEmails()
    }

    func loadMoreEmails() async {
        if currentMailbox == .allInboxes {
            return
        }

        guard let pageToken = nextPageToken, !isLoadingMore else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let labelIds = labelIdsForMailbox(currentMailbox)
            let query = mailboxQuery(for: currentMailbox)
            let (moreEmails, newPageToken) = try await GmailService.shared.fetchInbox(
                query: query,
                maxResults: 50,
                pageToken: pageToken,
                labelIds: labelIds
            )
            let moreEmailModels = moreEmails.map(Email.init(dto:))
            let uniqueNewEmails: [Email]
            if conversationThreading {
                let existingThreadIds = Set(emails.map { $0.threadId })
                uniqueNewEmails = moreEmailModels.filter { !existingThreadIds.contains($0.threadId) }
            } else {
                let existingIds = Set(emails.map { $0.id })
                uniqueNewEmails = moreEmailModels.filter { !existingIds.contains($0.id) }
            }
            emails.append(contentsOf: uniqueNewEmails)
            nextPageToken = newPageToken
            updateFilterCounts()
            logger.info("Loaded \(uniqueNewEmails.count) more emails")
        } catch {
            logger.error("Failed to load more emails: \(error.localizedDescription)")
            self.error = error
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

    // MARK: - Needs Reply Heuristics

    private static let needsReplyPatterns: [NSRegularExpression] = {
        let patterns = [
            "can\\s+you", "could\\s+you", "would\\s+you", "are\\s+you\\s+able",
            "let\\s+me\\s+know", "please\\s+confirm", "quick\\s+question",
            "thoughts\\?", "what\\s+do\\s+you\\s+think"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private func isNeedsReplyCandidate(_ email: Email) -> Bool {
        // Skip emails the user sent
        if email.labelIds.contains("SENT") {
            return false
        }

        // Skip if this is a reply FROM the user (subject starts with Re: and has SENT in thread)
        // This is a heuristic - if the email is a "Re:" and the user has SENT emails, likely replied
        if email.subject.lowercased().hasPrefix("re:") {
            // Check if there's any indication user participated in thread
            // messagesCount > 1 often means back-and-forth (user may have replied)
            if email.messagesCount > 1 {
                return false
            }
        }

        // Skip emails from the user's own account
        if let accountEmail = email.accountEmail {
            let senderEmail = email.senderEmail.lowercased()
            if senderEmail == accountEmail.lowercased() {
                return false
            }
        }

        // Gate out commercial/automated senders to avoid false positives.
        if EmailFilters.isBulk(email) {
            return false
        }
        if !EmailFilters.looksLikeHumanSender(email) {
            return false
        }

        let text = "\(email.subject) \(email.snippet)"
        if text.contains("?") {
            return true
        }

        let range = NSRange(text.startIndex..., in: text)
        return Self.needsReplyPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    // MARK: - Filter Counts (Simplified - no actor calls)

    private func updateFilterCounts() {
        recomputeFilterCounts(from: emails)
    }

    private func recomputeFilterCounts(from emails: [Email]) {
        let base = applyTabContext(emails.filter { email in
            let blocked = blockedSenders(for: email.accountEmail)
            return !blocked.contains(email.senderEmail.lowercased())
        })
        var counts: [InboxFilter: Int] = [:]

        counts[.unread] = base.filter { $0.isUnread }.count

        for email in base {
            if isNeedsReplyCandidate(email) {
                counts[.needsReply, default: 0] += 1
            }

            if isDeadline(email) {
                counts[.deadlines, default: 0] += 1
            }

            if isMoney(email) {
                counts[.money, default: 0] += 1
            }

            if isNewsletter(email) {
                counts[.newsletters, default: 0] += 1
            }
        }

        filterCounts = counts
    }

    // MARK: - Filtering

    private func blockedSenders(for accountEmail: String?) -> Set<String> {
        Set(AccountDefaults.stringArray(for: "blockedSenders", accountEmail: accountEmail))
    }

    private func alwaysPrimarySenders(for accountEmail: String?) -> [String] {
        AccountDefaults.stringArray(for: "alwaysPrimarySenders", accountEmail: accountEmail)
    }

    private func alwaysOtherSenders(for accountEmail: String?) -> [String] {
        AccountDefaults.stringArray(for: "alwaysOtherSenders", accountEmail: accountEmail)
    }

    private func accountForEmail(_ email: Email) -> AuthService.Account? {
        if let accountEmail = email.accountEmail?.lowercased() {
            return AuthService.shared.accounts.first { $0.email.lowercased() == accountEmail }
        }
        return AuthService.shared.currentAccount
    }

    private func senderOverride(for email: Email) -> InboxTab? {
        let accountEmail = email.accountEmail ?? AuthService.shared.currentAccount?.email
        let sender = email.senderEmail.lowercased()

        let primary = alwaysPrimarySenders(for: accountEmail)
        if primary.contains(sender) { return .primary }

        let other = alwaysOtherSenders(for: accountEmail)
        if other.contains(sender) { return .pinned }

        return nil
    }

    private func isVIPSender(_ email: Email) -> Bool {
        let vipSenders = AccountDefaults.stringArray(for: "vipSenders", accountEmail: email.accountEmail)
        return vipSenders.contains(email.senderEmail.lowercased())
    }

    private func isNewsletter(_ email: Email) -> Bool {
        email.labelIds.contains("CATEGORY_PROMOTIONS") || email.listUnsubscribe != nil
    }

    private func isMoney(_ email: Email) -> Bool {
        let text = "\(email.subject) \(email.snippet)".lowercased()
        return text.contains("receipt") || text.contains("order") ||
            text.contains("payment") || text.contains("invoice")
    }

    private func isDeadline(_ email: Email) -> Bool {
        let text = "\(email.subject) \(email.snippet)".lowercased()
        return text.contains("today") || text.contains("tomorrow") ||
            text.contains("urgent") || text.contains("deadline")
    }

    private func isSecurity(_ email: Email) -> Bool {
        let text = "\(email.subject) \(email.snippet)".lowercased()
        let keywords = [
            "security alert", "new sign-in", "sign-in", "password",
            "verify", "verification", "two-factor", "2fa",
            "suspicious", "unrecognized", "confirm", "action required"
        ]
        return keywords.contains { text.contains($0) }
    }

    private func isPeople(_ email: Email) -> Bool {
        EmailFilters.looksLikeHumanSender(email) && !EmailFilters.isBulk(email)
    }

    private func isPrimary(_ email: Email) -> Bool {
        if let override = senderOverride(for: email) {
            return override == .primary
        }

        for rule in PrimaryRule.allCases where InboxPreferences.isPrimaryRuleEnabled(rule) {
            switch rule {
            case .people:
                if isPeople(email) { return true }
            case .vip:
                if isVIPSender(email) { return true }
            case .security:
                if isSecurity(email) { return true }
            case .money:
                if isMoney(email) { return true }
            case .deadlines:
                if isDeadline(email) { return true }
            case .newsletters:
                if isNewsletter(email) { return true }
            case .promotions:
                if email.labelIds.contains("CATEGORY_PROMOTIONS") { return true }
            case .social:
                if email.labelIds.contains("CATEGORY_SOCIAL") { return true }
            case .forums:
                if email.labelIds.contains("CATEGORY_FORUMS") { return true }
            case .updates:
                if email.labelIds.contains("CATEGORY_UPDATES") { return true }
            }
        }

        return false
    }

    private func matchesPinned(_ email: Email) -> Bool {
        switch pinnedTabOption {
        case .other:
            return !isPrimary(email)
        case .money:
            return isMoney(email)
        case .deadlines:
            return isDeadline(email)
        case .needsReply:
            return isNeedsReplyCandidate(email)
        case .unread:
            return email.isUnread
        case .newsletters:
            return isNewsletter(email)
        case .people:
            return isPeople(email)
        }
    }

    private func applyTabContext(_ emails: [Email]) -> [Email] {
        var filtered = emails
        switch currentTab {
        case .all:
            break
        case .primary:
            filtered = filtered.filter { isPrimary($0) }
        case .pinned:
            filtered = filtered.filter { matchesPinned($0) }
        }

        return filtered
    }

    private func applyFilters(_ emails: [Email]) -> [Email] {
        var filtered = emails.filter { email in
            let blocked = blockedSenders(for: email.accountEmail)
            return !blocked.contains(email.senderEmail.lowercased())
        }

        filtered = applyTabContext(filtered)

        if let filter = activeFilter {
            switch filter {
            case .unread:
                filtered = filtered.filter { $0.isUnread }
            case .needsReply:
                filtered = filtered.filter { isNeedsReplyCandidate($0) }
            case .deadlines:
                filtered = filtered.filter { isDeadline($0) }
            case .money:
                filtered = filtered.filter { isMoney($0) }
            case .newsletters:
                filtered = filtered.filter { isNewsletter($0) }
            }
        }

        return filtered
    }

    private func groupEmailsByDate(_ emails: [Email]) -> [EmailSection] {
        let calendar = Calendar.current
        let now = Date()
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now)
        let lastWeekInterval = weekInterval.flatMap { interval in
            calendar.dateInterval(of: .weekOfYear, for: interval.start.addingTimeInterval(-1))
        }

        var today: [Email] = []
        var yesterday: [Email] = []
        var weekdayBuckets: [Int: [Email]] = [:]
        var orderedWeekdays: [Int] = []
        var lastWeek: [Email] = []
        var monthBuckets: [String: [Email]] = [:]
        var orderedMonths: [String] = []
        var yearBuckets: [String: [Email]] = [:]
        var orderedYears: [String] = []
        let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: now)

        for email in emails.sorted(by: { $0.date > $1.date }) {
            if calendar.isDateInToday(email.date) {
                today.append(email)
            } else if calendar.isDateInYesterday(email.date) {
                yesterday.append(email)
            } else if let weekInterval, weekInterval.contains(email.date) {
                let weekday = calendar.component(.weekday, from: email.date)
                if weekdayBuckets[weekday] == nil {
                    orderedWeekdays.append(weekday)
                    weekdayBuckets[weekday] = []
                }
                weekdayBuckets[weekday]?.append(email)
            } else if let lastWeekInterval, lastWeekInterval.contains(email.date) {
                lastWeek.append(email)
            } else {
                if let oneYearAgo, email.date >= oneYearAgo {
                    let year = calendar.component(.year, from: email.date)
                    let month = calendar.component(.month, from: email.date)
                    let monthKey = String(format: "%04d-%02d", year, month)
                    if monthBuckets[monthKey] == nil {
                        orderedMonths.append(monthKey)
                        monthBuckets[monthKey] = []
                    }
                    monthBuckets[monthKey]?.append(email)
                } else {
                    let year = calendar.component(.year, from: email.date)
                    let yearKey = String(year)
                    if yearBuckets[yearKey] == nil {
                        orderedYears.append(yearKey)
                        yearBuckets[yearKey] = []
                    }
                    yearBuckets[yearKey]?.append(email)
                }
            }
        }

        var sections: [EmailSection] = []
        let weekdayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.calendar = calendar
            formatter.dateFormat = "EEEE"
            return formatter
        }()
        let monthFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.calendar = calendar
            formatter.dateFormat = "MMMM yyyy"
            return formatter
        }()

        if !today.isEmpty {
            sections.append(EmailSection(id: "today", title: "Today", emails: today))
        }
        if !yesterday.isEmpty {
            sections.append(EmailSection(id: "yesterday", title: "Yesterday", emails: yesterday))
        }
        for weekday in orderedWeekdays {
            guard let emailsForDay = weekdayBuckets[weekday], let first = emailsForDay.first else { continue }
            let title = weekdayFormatter.string(from: first.date)
            sections.append(EmailSection(id: "weekday-\(weekday)", title: title, emails: emailsForDay))
        }
        if !lastWeek.isEmpty {
            sections.append(EmailSection(id: "lastWeek", title: "Last Week", emails: lastWeek))
        }
        for monthKey in orderedMonths {
            guard let emailsForMonth = monthBuckets[monthKey], let first = emailsForMonth.first else { continue }
            let title = monthFormatter.string(from: first.date)
            sections.append(EmailSection(id: "month-\(monthKey)", title: title, emails: emailsForMonth))
        }
        for yearKey in orderedYears {
            guard let emailsForYear = yearBuckets[yearKey] else { continue }
            sections.append(EmailSection(id: "year-\(yearKey)", title: yearKey, emails: emailsForYear))
        }

        return sections
    }

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
        updateFilterCounts()
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
