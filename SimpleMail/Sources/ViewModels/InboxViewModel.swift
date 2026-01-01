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
}

@MainActor
@Observable
final class InboxViewModel {
    // MARK: - State

    var emails: [Email] = []
    var scope: InboxScope = .all
    var activeFilter: InboxFilter? = nil
    var currentMailbox: Mailbox = .inbox
    var isLoading = false
    var isLoadingMore = false
    var error: Error?

    // Increment to force re-filter (e.g., when blocked senders change)
    private var filterVersion = 0

    // MARK: - Navigation

    var selectedEmail: Email?
    var showingEmailDetail = false

    // MARK: - Filter Counts

    var filterCounts: [InboxFilter: Int] = [:]

    // MARK: - Pagination

    private var nextPageToken: String?
    var hasMoreEmails: Bool { nextPageToken != nil }

    // MARK: - Undo Toast State

    var showingUndoToast = false
    var undoToastMessage = ""
    private var pendingArchive: PendingArchive?
    private var undoTask: Task<Void, Never>?

    struct PendingArchive {
        let email: Email
        let index: Int
    }

    // MARK: - Notification Observer
    @ObservationIgnored private var blockedSendersObserver: NSObjectProtocol?
    @ObservationIgnored private var accountChangeObserver: NSObjectProtocol?

    // MARK: - Computed Properties

    var emailSections: [EmailSection] {
        // Touch filterVersion to trigger re-computation when it changes
        _ = filterVersion
        let filteredEmails = applyFilters(emails)
        return groupEmailsByDate(filteredEmails)
    }

    /// Last visible email after filtering (for pagination trigger)
    private var lastVisibleEmailId: String? {
        emailSections.last?.emails.last?.id
    }

    // MARK: - Init

    init() {
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

        Task {
            await loadEmails()
        }
    }

    // Note: blockedSendersObserver is automatically removed when the token is deallocated

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
                self.emails = dedupeByThread(fetchedEmails)
                self.nextPageToken = nil
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
        // This ensures pagination triggers correctly when People filter reduces the list
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
            let existingThreadIds = Set(emails.map { $0.threadId })
            let uniqueNewEmails = moreEmailModels.filter { !existingThreadIds.contains($0.threadId) }
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
        var counts: [InboxFilter: Int] = [:]

        counts[.unread] = emails.filter { $0.isUnread }.count

        for email in emails {
            // Newsletter detection (sync)
            if email.labelIds.contains("CATEGORY_PROMOTIONS") || email.listUnsubscribe != nil {
                counts[.newsletters, default: 0] += 1
            }

            // Money/transactional detection (sync)
            let lowerSubject = email.subject.lowercased()
            let lowerSnippet = email.snippet.lowercased()
            if lowerSubject.contains("receipt") || lowerSubject.contains("order") ||
               lowerSubject.contains("payment") || lowerSubject.contains("invoice") ||
               lowerSnippet.contains("receipt") || lowerSnippet.contains("payment") {
                counts[.money, default: 0] += 1
            }

            // Needs reply detection (sync)
            if isNeedsReplyCandidate(email) {
                counts[.needsReply, default: 0] += 1
            }

            // Deadline detection (sync)
            let deadlineKeywords = ["today", "tomorrow", "urgent", "asap", "deadline", "due"]
            let emailText = "\(email.subject) \(email.snippet)".lowercased()
            if deadlineKeywords.contains(where: { emailText.contains($0) }) {
                counts[.deadlines, default: 0] += 1
            }
        }

        self.filterCounts = counts
    }

    // MARK: - Filtering

    private func blockedSenders(for accountEmail: String?) -> Set<String> {
        Set(AccountDefaults.stringArray(for: "blockedSenders", accountEmail: accountEmail))
    }

    private func accountForEmail(_ email: Email) -> AuthService.Account? {
        if let accountEmail = email.accountEmail?.lowercased() {
            return AuthService.shared.accounts.first { $0.email.lowercased() == accountEmail }
        }
        return AuthService.shared.currentAccount
    }

    private func applyFilters(_ emails: [Email]) -> [Email] {
        var filtered = emails

        // Filter out blocked senders first
        filtered = filtered.filter { email in
            let blocked = blockedSenders(for: email.accountEmail)
            return !blocked.contains(email.senderEmail.lowercased())
        }

        // Apply scope filter (People = emails from real humans, not bulk/newsletters)
        if scope == .people {
            filtered = EmailFilters.filterForPeopleScope(filtered)
        }

        // Apply active filter
        if let filter = activeFilter {
            switch filter {
            case .unread:
                filtered = filtered.filter { $0.isUnread }
            case .needsReply:
                filtered = filtered.filter { isNeedsReplyCandidate($0) }
            case .deadlines:
                filtered = filtered.filter { email in
                    let text = "\(email.subject) \(email.snippet)".lowercased()
                    return text.contains("today") || text.contains("tomorrow") ||
                           text.contains("urgent") || text.contains("deadline")
                }
            case .money:
                filtered = filtered.filter { email in
                    let text = "\(email.subject) \(email.snippet)".lowercased()
                    return text.contains("receipt") || text.contains("order") ||
                           text.contains("payment") || text.contains("invoice")
                }
            case .newsletters:
                filtered = filtered.filter { email in
                    email.labelIds.contains("CATEGORY_PROMOTIONS") ||
                    email.listUnsubscribe != nil
                }
            }
        }

        return filtered
    }

    private func groupEmailsByDate(_ emails: [Email]) -> [EmailSection] {
        let calendar = Calendar.current
        let now = Date()

        var today: [Email] = []
        var yesterday: [Email] = []
        var thisWeek: [Email] = []
        var earlier: [Email] = []

        for email in emails.sorted(by: { $0.date > $1.date }) {
            if calendar.isDateInToday(email.date) {
                today.append(email)
            } else if calendar.isDateInYesterday(email.date) {
                yesterday.append(email)
            } else if calendar.isDate(email.date, equalTo: now, toGranularity: .weekOfYear) {
                thisWeek.append(email)
            } else {
                earlier.append(email)
            }
        }

        var sections: [EmailSection] = []

        if !today.isEmpty {
            sections.append(EmailSection(id: "today", title: "Today", emails: today))
        }
        if !yesterday.isEmpty {
            sections.append(EmailSection(id: "yesterday", title: "Yesterday", emails: yesterday))
        }
        if !thisWeek.isEmpty {
            sections.append(EmailSection(id: "thisWeek", title: "This Week", emails: thisWeek))
        }
        if !earlier.isEmpty {
            sections.append(EmailSection(id: "earlier", title: "Earlier", emails: earlier))
        }

        return sections
    }

    // MARK: - Actions

    func refresh() async {
        await loadEmails()
    }

    func archiveEmail(_ email: Email) {
        // Cancel any existing undo task and finalize it
        if let pending = pendingArchive {
            undoTask?.cancel()
            finalizeArchive(pending.email)
        }

        // Find the email's current index before removing
        guard let index = emails.firstIndex(where: { $0.id == email.id }) else { return }

        // Store pending archive for potential undo
        pendingArchive = PendingArchive(email: email, index: index)

        // Optimistic update - remove from list immediately
        withAnimation(.easeOut(duration: 0.25)) {
            emails.remove(at: index)
        }
        updateFilterCounts()
        HapticFeedback.medium()

        // Show undo toast
        undoToastMessage = "Email Archived"
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showingUndoToast = true
        }

        // Start 4-second countdown to finalize
        undoTask = Task {
            try? await Task.sleep(for: .seconds(4))

            // Check if task was cancelled (user tapped undo)
            guard !Task.isCancelled else { return }

            // Finalize the archive
            if let pending = pendingArchive, pending.email.id == email.id {
                finalizeArchive(email)
            }
        }
    }

    func undoArchive() {
        // Cancel the pending archive task
        undoTask?.cancel()
        undoTask = nil

        // Restore the email at its original position
        guard let pending = pendingArchive else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            // Insert at original index, clamped to valid range
            let insertIndex = min(pending.index, emails.count)
            emails.insert(pending.email, at: insertIndex)
            showingUndoToast = false
        }

        pendingArchive = nil
        updateFilterCounts()
        HapticFeedback.light()
    }

    private func finalizeArchive(_ email: Email) {
        // Hide toast
        withAnimation(.easeOut(duration: 0.2)) {
            showingUndoToast = false
        }
        pendingArchive = nil

        // Call Gmail API to actually archive
        Task {
            do {
                if let account = accountForEmail(email) {
                    try await GmailService.shared.archive(messageId: email.id, account: account)
                } else {
                    try await GmailService.shared.archive(messageId: email.id)
                }
                logger.info("Email archived: \(email.id)")
            } catch {
                // Rollback on failure - reload emails
                logger.error("Failed to archive email: \(error.localizedDescription)")
                self.error = error
                await loadEmails()
            }
        }
    }

    func trashEmail(_ email: Email) {
        withAnimation {
            emails.removeAll { $0.id == email.id }
        }
        updateFilterCounts()
        HapticFeedback.medium()

        Task {
            do {
                if let account = accountForEmail(email) {
                    try await GmailService.shared.trash(messageId: email.id, account: account)
                } else {
                    try await GmailService.shared.trash(messageId: email.id)
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

            Task {
                do {
                    if wasStarred {
                        if let account = accountForEmail(email) {
                            try await GmailService.shared.unstar(messageId: email.id, account: account)
                        } else {
                            try await GmailService.shared.unstar(messageId: email.id)
                        }
                    } else {
                        if let account = accountForEmail(email) {
                            try await GmailService.shared.star(messageId: email.id, account: account)
                        } else {
                            try await GmailService.shared.star(messageId: email.id)
                        }
                    }
                } catch {
                    // Rollback
                    if let idx = emails.firstIndex(where: { $0.id == email.id }) {
                        emails[idx].isStarred = wasStarred
                    }
                    self.error = error
                }
            }
        }
    }

    func snoozeEmail(_ email: Email, until date: Date) {
        // Archive the email optimistically
        withAnimation {
            emails.removeAll { $0.id == email.id }
        }
        updateFilterCounts()
        HapticFeedback.medium()

        Task {
            do {
                // Archive via Gmail
                if let account = accountForEmail(email) {
                    try await GmailService.shared.archive(messageId: email.id, account: account)
                } else {
                    try await GmailService.shared.archive(messageId: email.id)
                }

                // Save snooze to local database for unsnoozing later
                await SnoozeManager.shared.snoozeEmail(email, until: date)
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

            Task {
                do {
                    if wasUnread {
                        if let account = accountForEmail(email) {
                            try await GmailService.shared.markAsRead(messageId: email.id, account: account)
                        } else {
                            try await GmailService.shared.markAsRead(messageId: email.id)
                        }
                    } else {
                        if let account = accountForEmail(email) {
                            try await GmailService.shared.markAsUnread(messageId: email.id, account: account)
                        } else {
                            try await GmailService.shared.markAsUnread(messageId: email.id)
                        }
                    }
                } catch {
                    // Rollback
                    if let idx = emails.firstIndex(where: { $0.id == email.id }) {
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
        withAnimation {
            emails.removeAll { $0.id == email.id }
        }
        updateFilterCounts()
        HapticFeedback.medium()

        Task {
            do {
                if let account = accountForEmail(email) {
                    try await GmailService.shared.reportSpam(messageId: email.id, account: account)
                } else {
                    try await GmailService.shared.reportSpam(messageId: email.id)
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
    ) async throws -> [Email] {
        guard !accounts.isEmpty else { return [] }

        var allEmails: [Email] = []
        await withTaskGroup(of: [Email].self) { group in
            for account in accounts {
                group.addTask {
                    do {
                        let (emails, _) = try await GmailService.shared.fetchInbox(
                            for: account,
                            query: query,
                            maxResults: 50,
                            labelIds: labelIds
                        )
                        return emails.map(Email.init(dto:))
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
            Task {
                do {
                    if let account = accountForEmail(email) {
                        try await GmailService.shared.markAsRead(messageId: email.id, account: account)
                    } else {
                        try await GmailService.shared.markAsRead(messageId: email.id)
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

}
