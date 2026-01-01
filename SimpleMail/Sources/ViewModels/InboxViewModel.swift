import Foundation
import SwiftUI
import SwiftData
import OSLog

// MARK: - Inbox ViewModel

private let logger = Logger(subsystem: "com.simplemail.app", category: "InboxViewModel")

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

    // MARK: - Computed Properties

    var emailSections: [EmailSection] {
        let filteredEmails = applyFilters(emails)
        return groupEmailsByDate(filteredEmails)
    }

    /// Last visible email after filtering (for pagination trigger)
    private var lastVisibleEmailId: String? {
        emailSections.last?.emails.last?.id
    }

    // MARK: - Init

    init() {
        Task {
            await loadEmails()
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
        } catch {
            logger.error("Failed to fetch emails: \(error.localizedDescription)")
            self.error = error
            #if DEBUG
            loadMockData()
            #endif
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
        default:
            return nil
        }
    }

    private func dedupeByThread(_ emails: [Email]) -> [Email] {
        var seen = Set<String>()
        var deduped: [Email] = []
        for email in emails {
            if seen.contains(email.threadId) {
                continue
            }
            seen.insert(email.threadId)
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
            let lowerText = text.lowercased()
            if deadlineKeywords.contains(where: { lowerText.contains($0) }) {
                counts[.deadlines, default: 0] += 1
            }
        }

        self.filterCounts = counts
    }

    // MARK: - Filtering

    private var blockedSenders: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "blockedSenders") ?? [])
    }

    private func applyFilters(_ emails: [Email]) -> [Email] {
        var filtered = emails

        // Filter out blocked senders first
        let blocked = blockedSenders
        if !blocked.isEmpty {
            filtered = filtered.filter { email in
                !blocked.contains(email.senderEmail.lowercased())
            }
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
                try await GmailService.shared.archive(messageId: email.id)
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
                try await GmailService.shared.trash(messageId: email.id)
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
                        try await GmailService.shared.unstar(messageId: email.id)
                    } else {
                        try await GmailService.shared.star(messageId: email.id)
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
                try await GmailService.shared.archive(messageId: email.id)

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
                        try await GmailService.shared.markAsRead(messageId: email.id)
                    } else {
                        try await GmailService.shared.markAsUnread(messageId: email.id)
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
                    try await GmailService.shared.markAsRead(messageId: email.id)
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

    // MARK: - Mock Data

    private func loadMockData() {
        let calendar = Calendar.current

        emails = [
            Email(
                id: "1",
                threadId: "t1",
                snippet: "Hey! Just wanted to check in about the project. Do you have time to chat this week?",
                subject: "Quick question about the project",
                from: "Chelsea Hart <chelsea.hart@gmail.com>",
                date: Date(),
                isUnread: true,
                labelIds: []
            ),
            Email(
                id: "2",
                threadId: "t2",
                snippet: "Your order has shipped! Track your package with the link below.",
                subject: "Your Amazon order has shipped",
                from: "Amazon <ship-confirm@amazon.com>",
                date: calendar.date(byAdding: .hour, value: -3, to: Date())!,
                isUnread: true,
                hasAttachments: false,
                labelIds: ["CATEGORY_UPDATES"]
            ),
            Email(
                id: "3",
                threadId: "t3",
                snippet: "Don't miss our biggest sale of the year! Up to 50% off everything.",
                subject: "Black Friday Sale - 50% Off!",
                from: "Nordstrom <newsletter@nordstrom.com>",
                date: calendar.date(byAdding: .hour, value: -5, to: Date())!,
                isUnread: false,
                labelIds: ["CATEGORY_PROMOTIONS"],
                listUnsubscribe: "<mailto:unsubscribe@nordstrom.com>"
            ),
            Email(
                id: "4",
                threadId: "t4",
                snippet: "The deadline for the quarterly report is tomorrow. Please make sure to submit your sections by EOD.",
                subject: "Reminder: Quarterly report due tomorrow",
                from: "Mark Johnson <mark.johnson@company.com>",
                date: calendar.date(byAdding: .day, value: -1, to: Date())!,
                isUnread: true,
                labelIds: []
            ),
            Email(
                id: "5",
                threadId: "t5",
                snippet: "Thank you for your payment of $150.00. Your receipt is attached.",
                subject: "Payment Receipt - Invoice #12345",
                from: "Stripe <receipts@stripe.com>",
                date: calendar.date(byAdding: .day, value: -1, to: Date())!,
                isUnread: false,
                hasAttachments: true,
                labelIds: ["CATEGORY_UPDATES"]
            ),
            Email(
                id: "6",
                threadId: "t6",
                snippet: "What do you think about grabbing dinner this weekend? Let me know!",
                subject: "Dinner plans?",
                from: "Sarah Miller <sarah.m@icloud.com>",
                date: calendar.date(byAdding: .day, value: -2, to: Date())!,
                isUnread: true,
                labelIds: []
            ),
            Email(
                id: "7",
                threadId: "t7",
                snippet: "Your weekly digest of the top tech news stories.",
                subject: "TechCrunch Daily - December 30, 2025",
                from: "TechCrunch <newsletter@techcrunch.com>",
                date: calendar.date(byAdding: .day, value: -3, to: Date())!,
                isUnread: false,
                labelIds: ["CATEGORY_PROMOTIONS"],
                listUnsubscribe: "<https://techcrunch.com/unsubscribe>"
            ),
            Email(
                id: "8",
                threadId: "t8",
                snippet: "Your flight to San Francisco has been confirmed. Please find your itinerary attached.",
                subject: "Flight Confirmation - SFO Jan 15",
                from: "United Airlines <noreply@united.com>",
                date: calendar.date(byAdding: .day, value: -4, to: Date())!,
                isUnread: false,
                hasAttachments: true,
                labelIds: ["CATEGORY_UPDATES"]
            )
        ]
    }
}
