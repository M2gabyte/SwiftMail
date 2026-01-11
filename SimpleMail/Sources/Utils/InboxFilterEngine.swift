import Foundation

struct InboxFilterEngine {
    struct ClassificationSignature: Hashable {
        let subject: String
        let snippet: String
        let from: String
        let labelKey: String
        let listUnsubscribe: String?
        let listId: String?
        let precedence: String?
        let autoSubmitted: String?
        let messagesCount: Int
        let accountEmail: String?
    }

    struct Classification {
        let isMoney: Bool
        let isDeadline: Bool
        let isSecurity: Bool
        let isNewsletter: Bool
        let isPeople: Bool
        let isBulk: Bool
        let isNeedsReply: Bool
    }

    struct CacheEntry {
        let signature: ClassificationSignature
        let classification: Classification
    }

    struct CacheResult {
        let cache: [String: CacheEntry]
        let classifications: [String: Classification]
    }

    // MARK: - Static Formatters (avoid per-call creation)

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEEE"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static let needsReplyPatterns: [NSRegularExpression] = {
        let patterns = [
            "can\\s+you", "could\\s+you", "would\\s+you", "are\\s+you\\s+able",
            "let\\s+me\\s+know", "please\\s+confirm", "quick\\s+question",
            "thoughts\\?", "what\\s+do\\s+you\\s+think"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private static func scopedKey(_ key: String, accountEmail: String?) -> String {
        guard let email = accountEmail?.lowercased(), !email.isEmpty else {
            return key
        }
        return "\(key)::\(email)"
    }

    private static func stringArraySync(for key: String, accountEmail: String?) -> [String] {
        UserDefaults.standard.stringArray(forKey: scopedKey(key, accountEmail: accountEmail)) ?? []
    }

    private static func boolSync(for key: String, accountEmail: String?) -> Bool {
        UserDefaults.standard.bool(forKey: scopedKey(key, accountEmail: accountEmail))
    }

    private static func isPrimaryRuleEnabledSync(_ rule: PrimaryRule) -> Bool {
        boolSync(for: rule.defaultsKey, accountEmail: nil)
    }

    static func buildClassificationCache(
        emails: [EmailSnapshot],
        existingCache: [String: CacheEntry],
        currentAccountEmail: String?
    ) -> CacheResult {
        var newCache: [String: CacheEntry] = [:]
        newCache.reserveCapacity(emails.count)

        for email in emails {
            let signature = classificationSignature(for: email, currentAccountEmail: currentAccountEmail)
            if let cached = existingCache[email.id], cached.signature == signature {
                newCache[email.id] = cached
                continue
            }
            let classification = classify(email, currentAccountEmail: currentAccountEmail)
            newCache[email.id] = CacheEntry(signature: signature, classification: classification)
        }

        var classifications: [String: Classification] = [:]
        classifications.reserveCapacity(newCache.count)
        for (id, entry) in newCache {
            classifications[id] = entry.classification
        }

        return CacheResult(cache: newCache, classifications: classifications)
    }

    static func recomputeFilterCounts(
        from emails: [EmailSnapshot],
        currentTab: InboxTab,
        pinnedTabOption: PinnedTabOption,
        currentAccountEmail: String?,
        classifications: [String: Classification]
    ) -> [InboxFilter: Int] {
        let blocked = blockedSendersSync(for: currentAccountEmail)
        let base = applyTabContext(
            emails.filter { !blocked.contains($0.senderEmail.lowercased()) },
            currentTab: currentTab,
            pinnedTabOption: pinnedTabOption,
            currentAccountEmail: currentAccountEmail,
            classifications: classifications
        )

        var counts: [InboxFilter: Int] = [:]
        counts[.unread] = base.filter { $0.isUnread }.count

        for email in base {
            if classifications[email.id]?.isNeedsReply == true {
                counts[.needsReply, default: 0] += 1
            }

            if classifications[email.id]?.isDeadline == true {
                counts[.deadlines, default: 0] += 1
            }

            if classifications[email.id]?.isMoney == true {
                counts[.money, default: 0] += 1
            }

            if classifications[email.id]?.isNewsletter == true {
                counts[.newsletters, default: 0] += 1
            }
        }

        return counts
    }

    static func applyFilters(
        _ emails: [EmailSnapshot],
        currentTab: InboxTab,
        pinnedTabOption: PinnedTabOption,
        activeFilter: InboxFilter?,
        currentAccountEmail: String?,
        classifications: [String: Classification]
    ) -> [EmailSnapshot] {
        let blocked = blockedSendersSync(for: currentAccountEmail)
        var filtered = emails.filter { email in
            !blocked.contains(email.senderEmail.lowercased())
        }

        filtered = applyTabContext(
            filtered,
            currentTab: currentTab,
            pinnedTabOption: pinnedTabOption,
            currentAccountEmail: currentAccountEmail,
            classifications: classifications
        )

        if let filter = activeFilter {
            switch filter {
            case .unread:
                filtered = filtered.filter { $0.isUnread }
            case .needsReply:
                filtered = filtered.filter { classifications[$0.id]?.isNeedsReply == true }
            case .deadlines:
                filtered = filtered.filter { classifications[$0.id]?.isDeadline == true }
            case .money:
                filtered = filtered.filter { classifications[$0.id]?.isMoney == true }
            case .newsletters:
                filtered = filtered.filter { classifications[$0.id]?.isNewsletter == true }
            }
        }

        return filtered
    }

    static func groupEmailsByDate(_ emails: [EmailDTO]) -> [EmailSection] {
        let calendar = Calendar.current
        let now = Date()
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now)
        let lastWeekInterval = weekInterval.flatMap { interval in
            calendar.dateInterval(of: .weekOfYear, for: interval.start.addingTimeInterval(-1))
        }

        var today: [EmailDTO] = []
        var yesterday: [EmailDTO] = []
        var weekdayBuckets: [Int: [EmailDTO]] = [:]
        var orderedWeekdays: [Int] = []
        var lastWeek: [EmailDTO] = []
        var monthBuckets: [String: [EmailDTO]] = [:]
        var orderedMonths: [String] = []
        var yearBuckets: [String: [EmailDTO]] = [:]
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

    private static func isNeedsReplyCandidate(_ email: EmailSnapshot) -> Bool {
        let labelIds = email.labelIdsKey.split(separator: "|").map(String.init)

        if labelIds.contains("SENT") {
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

        if isBulkSnapshot(email) {
            return false
        }
        if !looksLikeHumanSenderSnapshot(email) {
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
        Set(stringArraySync(for: "blockedSenders", accountEmail: accountEmail))
    }

    private static func blockedSendersSync(for accountEmail: String?) -> Set<String> {
        Set(stringArraySync(for: "blockedSenders", accountEmail: accountEmail))
    }

    private static func alwaysPrimarySenders(for accountEmail: String?) -> [String] {
        stringArraySync(for: "alwaysPrimarySenders", accountEmail: accountEmail)
    }

    private static func alwaysOtherSenders(for accountEmail: String?) -> [String] {
        stringArraySync(for: "alwaysOtherSenders", accountEmail: accountEmail)
    }

    private static func accountEmail(for email: EmailSnapshot, fallback: String?) -> String? {
        email.accountEmail ?? fallback
    }

    private static func senderOverride(for email: EmailSnapshot, currentAccountEmail: String?) -> InboxTab? {
        let accountEmail = accountEmail(for: email, fallback: currentAccountEmail)
        let sender = email.senderEmail.lowercased()

        let primary = alwaysPrimarySenders(for: accountEmail)
        if primary.contains(sender) { return .primary }

        let other = alwaysOtherSenders(for: accountEmail)
        if other.contains(sender) { return .pinned }

        return nil
    }

    private static func isVIPSender(_ email: EmailSnapshot) -> Bool {
        let vipSenders = stringArraySync(for: "vipSenders", accountEmail: email.accountEmail)
        return vipSenders.contains(email.senderEmail.lowercased())
    }

    private static func isNewsletter(_ email: EmailSnapshot) -> Bool {
        let labelIds = email.labelIdsKey.split(separator: "|").map(String.init)
        return labelIds.contains("CATEGORY_PROMOTIONS") || email.listUnsubscribe != nil
    }

    private static func isMoney(_ email: EmailSnapshot) -> Bool {
        let text = "\(email.subject) \(email.snippet)".lowercased()
        return text.contains("receipt") || text.contains("order") ||
            text.contains("payment") || text.contains("invoice")
    }

    private static func isDeadline(_ email: EmailSnapshot) -> Bool {
        let text = "\(email.subject) \(email.snippet)".lowercased()
        return text.contains("today") || text.contains("tomorrow") ||
            text.contains("urgent") || text.contains("deadline")
    }

    private static func isSecurity(_ email: EmailSnapshot) -> Bool {
        let text = "\(email.subject) \(email.snippet)".lowercased()
        let keywords = [
            "security alert", "new sign-in", "sign-in", "password",
            "verify", "verification", "two-factor", "2fa",
            "suspicious", "unrecognized", "confirm", "action required"
        ]
        return keywords.contains { text.contains($0) }
    }

    // MARK: - Snapshot-based EmailFilters replacements

    private static let personalEmailDomains: Set<String> = [
        "gmail.com", "googlemail.com",
        "yahoo.com", "ymail.com",
        "hotmail.com", "outlook.com", "live.com", "msn.com",
        "icloud.com", "me.com", "mac.com",
        "aol.com",
        "protonmail.com", "proton.me",
        "fastmail.com",
        "zoho.com",
    ]

    private static let noReplyPatterns: [NSRegularExpression] = {
        let patterns = [
            "no-?reply", "noreply", "do-?not-?reply", "donotreply",
            "notifications?@", "notify@", "alerts?@", "mailer@",
            "bounce@", "auto@", "automated@", "system@", "info@",
            "support@", "help@", "contact@", "hello@", "team@",
            "news@", "updates?@", "marketing@", "promo@", "sales@",
            "billing@", "service@", "admin@",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private static let bulkCategoryLabels: Set<String> = [
        "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS",
    ]

    private static let bulkPrecedenceValues: Set<String> = ["bulk", "list", "junk"]

    private static func looksLikeHumanSenderSnapshot(_ email: EmailSnapshot) -> Bool {
        let senderEmail = email.senderEmail.lowercased()
        let senderName = email.senderName
        let domain = senderEmail.split(separator: "@").last.map(String.init) ?? ""

        // Strong negative: no-reply patterns
        let emailRange = NSRange(senderEmail.startIndex..., in: senderEmail)
        for pattern in noReplyPatterns {
            if pattern.firstMatch(in: senderEmail, range: emailRange) != nil {
                return false
            }
        }

        // Strong positive: personal email domain
        if personalEmailDomains.contains(domain) {
            return true
        }

        // Moderate positive: name has a space (First Last pattern)
        if senderName.contains(" ") {
            let words = senderName.split(separator: " ")
            if words.count >= 2 && words.count <= 4 {
                let firstWord = String(words[0]).lowercased()
                let nonNameWords: Set<String> = ["the", "a", "an", "my", "your", "our", "team", "support", "news"]
                if !nonNameWords.contains(firstWord) {
                    return true
                }
            }
        }

        // Single-word names are likely org/brand
        if !senderName.contains(" ") && senderName.count > 3 {
            return false
        }

        return false
    }

    private static func isBulkSnapshot(_ email: EmailSnapshot) -> Bool {
        let labelIds = Set(email.labelIdsKey.split(separator: "|").map(String.init))

        // Bulk category labels
        if !bulkCategoryLabels.isDisjoint(with: labelIds) { return true }

        // List-Unsubscribe or List-ID headers
        if email.listUnsubscribe != nil { return true }
        if email.listId != nil { return true }

        // Precedence header
        if let precedence = email.precedence?.lowercased() {
            if bulkPrecedenceValues.contains(where: { precedence.contains($0) }) {
                return true
            }
        }

        // Auto-Submitted header
        if let autoSubmitted = email.autoSubmitted?.lowercased(), autoSubmitted != "no" {
            return true
        }

        // No-reply sender patterns
        let senderEmail = email.senderEmail.lowercased()
        let emailRange = NSRange(senderEmail.startIndex..., in: senderEmail)
        for pattern in noReplyPatterns {
            if pattern.firstMatch(in: senderEmail, range: emailRange) != nil {
                return true
            }
        }

        return false
    }

    private static func isPeople(_ email: EmailSnapshot) -> Bool {
        looksLikeHumanSenderSnapshot(email) && !isBulkSnapshot(email)
    }

    private static func isPrimary(
        _ email: EmailSnapshot,
        classification: Classification,
        currentAccountEmail: String?
    ) -> Bool {
        // User override takes precedence
        if let override = senderOverride(for: email, currentAccountEmail: currentAccountEmail) {
            return override == .primary
        }

        let labelIds = Set(email.labelIdsKey.split(separator: "|").map(String.init))

        // Match Gmail's Primary: CATEGORY_PERSONAL or no category label
        // Gmail puts emails in Primary if they have CATEGORY_PERSONAL,
        // or if they don't have any of the other category labels
        let nonPrimaryCategories = ["CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS"]
        let hasNonPrimaryCategory = nonPrimaryCategories.contains { labelIds.contains($0) }

        return !hasNonPrimaryCategory
    }

    private static func matchesPinned(
        _ email: EmailSnapshot,
        pinnedTabOption: PinnedTabOption,
        currentAccountEmail: String?,
        classifications: [String: Classification]
    ) -> Bool {
        guard let classification = classifications[email.id] else { return false }
        switch pinnedTabOption {
        case .other:
            return !isPrimary(email, classification: classification, currentAccountEmail: currentAccountEmail)
        case .money:
            return classification.isMoney
        case .deadlines:
            return classification.isDeadline
        case .needsReply:
            return classification.isNeedsReply
        case .unread:
            return email.isUnread
        case .newsletters:
            return classification.isNewsletter
        case .people:
            return classification.isPeople
        }
    }

    private static func applyTabContext(
        _ emails: [EmailSnapshot],
        currentTab: InboxTab,
        pinnedTabOption: PinnedTabOption,
        currentAccountEmail: String?,
        classifications: [String: Classification]
    ) -> [EmailSnapshot] {
        var filtered = emails
        switch currentTab {
        case .all:
            break
        case .primary:
            filtered = filtered.filter { email in
                guard let classification = classifications[email.id] else { return false }
                return isPrimary(email, classification: classification, currentAccountEmail: currentAccountEmail)
            }
        case .pinned:
            filtered = filtered.filter { email in
                matchesPinned(
                    email,
                    pinnedTabOption: pinnedTabOption,
                    currentAccountEmail: currentAccountEmail,
                    classifications: classifications
                )
            }
        }

        return filtered
    }

    private static func classificationSignature(
        for email: EmailSnapshot,
        currentAccountEmail: String?
    ) -> ClassificationSignature {
        return ClassificationSignature(
            subject: email.subject,
            snippet: email.snippet,
            from: email.senderEmail,
            labelKey: email.labelIdsKey,
            listUnsubscribe: email.listUnsubscribe,
            listId: email.listId,
            precedence: email.precedence,
            autoSubmitted: email.autoSubmitted,
            messagesCount: email.messagesCount,
            accountEmail: accountEmail(for: email, fallback: currentAccountEmail)
        )
    }

    private static func classify(
        _ email: EmailSnapshot,
        currentAccountEmail: String?
    ) -> Classification {
        let isBulk = isBulkSnapshot(email)
        let isPeople = looksLikeHumanSenderSnapshot(email) && !isBulk
        let isMoney = isMoney(email)
        let isDeadline = isDeadline(email)
        let isSecurity = isSecurity(email)
        let isNewsletter = isNewsletter(email)
        let isNeedsReply = isNeedsReplyCandidate(email)

        return Classification(
            isMoney: isMoney,
            isDeadline: isDeadline,
            isSecurity: isSecurity,
            isNewsletter: isNewsletter,
            isPeople: isPeople,
            isBulk: isBulk,
            isNeedsReply: isNeedsReply
        )
    }

    // MARK: - Category Bundles

    /// Compute category bundles for non-Primary emails (Promotions, Social, Updates, Forums)
    /// Only computed when viewing Primary tab to show collapsed bundles
    static func computeCategoryBundles(from emails: [EmailSnapshot]) -> [CategoryBundle] {
        var bundleData: [GmailCategory: (unread: Int, total: Int, latest: EmailSnapshot?)] = [:]

        // Initialize all categories
        for category in GmailCategory.allCases {
            bundleData[category] = (unread: 0, total: 0, latest: nil)
        }

        // Sort emails by date descending to get latest first
        let sortedEmails = emails.sorted { $0.date > $1.date }

        for email in sortedEmails {
            let labelIds = Set(email.labelIdsKey.split(separator: "|").map(String.init))

            for category in GmailCategory.allCases {
                if labelIds.contains(category.rawValue) {
                    var data = bundleData[category]!
                    data.total += 1
                    if email.isUnread {
                        data.unread += 1
                    }
                    // First match is the latest (already sorted by date)
                    if data.latest == nil {
                        data.latest = email
                    }
                    bundleData[category] = data
                    break  // Email belongs to one category
                }
            }
        }

        // Convert to CategoryBundle array, only include non-empty bundles
        return GmailCategory.allCases.compactMap { category in
            guard let data = bundleData[category], data.total > 0 else { return nil }
            return CategoryBundle(
                category: category,
                unreadCount: data.unread,
                totalCount: data.total,
                latestEmail: data.latest?.toDTO()
            )
        }
    }
}
