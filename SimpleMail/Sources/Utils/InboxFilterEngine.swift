import Foundation

struct InboxFilterEngine {
    private static let needsReplyPatterns: [NSRegularExpression] = {
        let patterns = [
            "can\\s+you", "could\\s+you", "would\\s+you", "are\\s+you\\s+able",
            "let\\s+me\\s+know", "please\\s+confirm", "quick\\s+question",
            "thoughts\\?", "what\\s+do\\s+you\\s+think"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    static func recomputeFilterCounts(
        from emails: [Email],
        currentTab: InboxTab,
        pinnedTabOption: PinnedTabOption
    ) -> [InboxFilter: Int] {
        let base = applyTabContext(
            emails.filter { email in
                let blocked = blockedSenders(for: email.accountEmail)
                return !blocked.contains(email.senderEmail.lowercased())
            },
            currentTab: currentTab,
            pinnedTabOption: pinnedTabOption
        )

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

        return counts
    }

    static func applyFilters(
        _ emails: [Email],
        currentTab: InboxTab,
        pinnedTabOption: PinnedTabOption,
        activeFilter: InboxFilter?
    ) -> [Email] {
        var filtered = emails.filter { email in
            let blocked = blockedSenders(for: email.accountEmail)
            return !blocked.contains(email.senderEmail.lowercased())
        }

        filtered = applyTabContext(filtered, currentTab: currentTab, pinnedTabOption: pinnedTabOption)

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

    static func groupEmailsByDate(_ emails: [Email]) -> [EmailSection] {
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

    private static func isNeedsReplyCandidate(_ email: Email) -> Bool {
        if email.labelIds.contains("SENT") {
            return false
        }

        if email.subject.lowercased().hasPrefix("re:") {
            if email.messagesCount > 1 {
                return false
            }
        }

        if let accountEmail = email.accountEmail {
            let senderEmail = email.senderEmail.lowercased()
            if senderEmail == accountEmail.lowercased() {
                return false
            }
        }

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
        return needsReplyPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    private static func blockedSenders(for accountEmail: String?) -> Set<String> {
        Set(AccountDefaults.stringArray(for: "blockedSenders", accountEmail: accountEmail))
    }

    private static func alwaysPrimarySenders(for accountEmail: String?) -> [String] {
        AccountDefaults.stringArray(for: "alwaysPrimarySenders", accountEmail: accountEmail)
    }

    private static func alwaysOtherSenders(for accountEmail: String?) -> [String] {
        AccountDefaults.stringArray(for: "alwaysOtherSenders", accountEmail: accountEmail)
    }

    private static func senderOverride(for email: Email) -> InboxTab? {
        let accountEmail = email.accountEmail ?? AuthService.shared.currentAccount?.email
        let sender = email.senderEmail.lowercased()

        let primary = alwaysPrimarySenders(for: accountEmail)
        if primary.contains(sender) { return .primary }

        let other = alwaysOtherSenders(for: accountEmail)
        if other.contains(sender) { return .pinned }

        return nil
    }

    private static func isVIPSender(_ email: Email) -> Bool {
        let vipSenders = AccountDefaults.stringArray(for: "vipSenders", accountEmail: email.accountEmail)
        return vipSenders.contains(email.senderEmail.lowercased())
    }

    private static func isNewsletter(_ email: Email) -> Bool {
        email.labelIds.contains("CATEGORY_PROMOTIONS") || email.listUnsubscribe != nil
    }

    private static func isMoney(_ email: Email) -> Bool {
        let text = "\(email.subject) \(email.snippet)".lowercased()
        return text.contains("receipt") || text.contains("order") ||
            text.contains("payment") || text.contains("invoice")
    }

    private static func isDeadline(_ email: Email) -> Bool {
        let text = "\(email.subject) \(email.snippet)".lowercased()
        return text.contains("today") || text.contains("tomorrow") ||
            text.contains("urgent") || text.contains("deadline")
    }

    private static func isSecurity(_ email: Email) -> Bool {
        let text = "\(email.subject) \(email.snippet)".lowercased()
        let keywords = [
            "security alert", "new sign-in", "sign-in", "password",
            "verify", "verification", "two-factor", "2fa",
            "suspicious", "unrecognized", "confirm", "action required"
        ]
        return keywords.contains { text.contains($0) }
    }

    private static func isPeople(_ email: Email) -> Bool {
        EmailFilters.looksLikeHumanSender(email) && !EmailFilters.isBulk(email)
    }

    private static func isPrimary(_ email: Email) -> Bool {
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

    private static func matchesPinned(_ email: Email, pinnedTabOption: PinnedTabOption) -> Bool {
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

    private static func applyTabContext(
        _ emails: [Email],
        currentTab: InboxTab,
        pinnedTabOption: PinnedTabOption
    ) -> [Email] {
        var filtered = emails
        switch currentTab {
        case .all:
            break
        case .primary:
            filtered = filtered.filter { isPrimary($0) }
        case .pinned:
            filtered = filtered.filter { matchesPinned($0, pinnedTabOption: pinnedTabOption) }
        }

        return filtered
    }
}
