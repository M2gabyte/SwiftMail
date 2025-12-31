import Foundation

/// BriefingEngine - Smart Email Triage
///
/// Surfaces what matters most without AI - uses Gmail metadata, headers, and scoring.
///
/// CLASSIFICATION ORDER (each email goes to exactly one bucket):
/// 1. money_confirmations - Receipts, statements, transactional
/// 2. newsletters - Bulk/marketing (Gmail labels + headers)
/// 3. needs_reply - High-precision scoring (before deadlines!)
/// 4. maybe_reply - Medium confidence scoring
/// 5. deadlines_today - Time-sensitive items that don't need reply
/// 6. everything_else - Not shown in briefing

actor BriefingEngine {

    // MARK: - Constants

    private let maxItemsPerSection = 5
    private let highConfidenceThreshold = 4
    private let mediumConfidenceThreshold = 2

    // MARK: - Pattern Sets

    private let bulkCategoryLabels = [
        "CATEGORY_PROMOTIONS",
        "CATEGORY_SOCIAL",
        "CATEGORY_FORUMS"
    ]

    private let updatesCategoryLabel = "CATEGORY_UPDATES"

    private let bulkPrecedenceValues = ["bulk", "list", "junk"]

    private let noReplyPatterns: [NSRegularExpression] = {
        let patterns = [
            "noreply", "no-reply", "donotreply", "do-not-reply",
            "notifications?@", "notify@", "info@", "marketing@",
            "newsletter@", "updates@", "mailer-daemon", "postmaster"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private let marketingPlatformDomains = [
        "mailchimp.com", "sendgrid.net", "sendgrid.com", "sailthru.com",
        "exacttarget.com", "constantcontact.com", "hubspot.com",
        "mailgun.org", "mailgun.com", "sparkpost.com", "amazonses.com",
        "postmarkapp.com", "mandrillapp.com", "klaviyo.com", "braze.com",
        "iterable.com", "customer.io", "intercom-mail.com", "zendesk.com",
        "freshdesk.com", "campaign-archive.com", "list-manage.com",
        "createsend.com", "mcsv.net", "rsgsv.net", "ctmail.com"
    ]

    private let brandSenderPatterns: [NSRegularExpression] = {
        let patterns = [
            "^[A-Z][A-Z0-9\\s&.'-]+$",
            "\\bTeam\\b", "\\bSupport\\b", "\\bUpdates?\\b",
            "\\bNotifications?\\b", "\\bAlerts?\\b", "\\bNews\\b",
            "\\bDigest\\b", "\\bNewsletter\\b", "\\bMarketing\\b",
            "\\bPromotions?\\b", "\\bSales\\b", "\\bOffers?\\b",
            "\\bDeals\\b", "\\bRewards?\\b", "\\bMembership\\b",
            "\\bAccount\\b", "\\bBilling\\b", "\\bService\\b"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private let personalEmailDomains = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com",
        "outlook.com", "hotmail.com", "live.com", "msn.com",
        "yahoo.com", "ymail.com", "aol.com",
        "protonmail.com", "proton.me", "fastmail.com", "hey.com"
    ]

    private let transactionalKeywords: [NSRegularExpression] = {
        let patterns = [
            "\\breceipt\\b", "\\binvoice\\b", "\\bstatement\\b",
            "\\border\\s+(confirm|ship|#|\\d)", "\\bshipped\\b",
            "\\btracking\\b", "\\breservation\\b", "\\bitinerary\\b",
            "\\bpayment\\b", "\\bcharge[ds]?\\b", "\\brenewal\\b",
            "\\bsecurity\\s+alert", "\\bverification\\s+code",
            "\\bpassword\\s+reset", "\\$\\d+\\.\\d{2}"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private let transactionalSenderPatterns: [NSRegularExpression] = {
        let patterns = [
            "amazon", "apple", "paypal", "venmo", "uber", "lyft",
            "doordash", "grubhub", "airbnb", "expedia", "delta",
            "united", "american\\s?airlines", "southwest", "fedex",
            "ups", "usps", "netflix", "spotify", "chase", "wellsfargo",
            "wells\\s?fargo", "bankofamerica", "bank\\s?of\\s?america",
            "citi", "amex", "capital\\s?one", "experian", "equifax",
            "transunion", "schwab", "fidelity", "vanguard"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private let meetingInvitePatterns: [NSRegularExpression] = {
        let patterns = [
            "invit(ing|es?)\\s+you\\s+to\\s+a.*meeting",
            "join\\s+zoom\\s+meeting", "zoom\\.us/j/",
            "meet\\.google\\.com", "teams\\.microsoft\\.com",
            "webex\\.com", "calendar\\s+invite", "meeting\\s+id:\\s*\\d",
            "passcode:\\s*\\d", "dial[\\s-]?in", "one\\s+tap\\s+mobile",
            "\\bmeeting\\s+request\\b", "\\bcalendar\\s+event\\b",
            "\\baccept\\b.*\\bdecline\\b"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private let deadlineKeywords: [(pattern: NSRegularExpression, label: String)] = {
        let patterns: [(String, String)] = [
            ("\\btoday\\b", "Due today"),
            ("\\btomorrow\\b", "Tomorrow"),
            ("\\beod\\b", "EOD"),
            ("\\bend\\s+of\\s+day\\b", "EOD"),
            ("\\bdue\\b", "Due"),
            ("\\bdeadline\\b", "Deadline"),
            ("\\brsvp\\b", "RSVP"),
            ("\\burgent\\b", "Urgent"),
            ("\\basap\\b", "ASAP")
        ]
        return patterns.compactMap { tuple in
            guard let regex = try? NSRegularExpression(pattern: tuple.0, options: .caseInsensitive) else {
                return nil
            }
            return (regex, tuple.1)
        }
    }()

    private let directAskPatterns: [NSRegularExpression] = {
        let patterns = [
            "can\\s+you", "could\\s+you", "would\\s+you", "are\\s+you\\s+able",
            "let\\s+me\\s+know", "please\\s+confirm", "quick\\s+question",
            "thoughts\\?", "what\\s+do\\s+you\\s+think"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    // MARK: - Build Briefing

    func buildBriefing(
        emails: [Email],
        snoozedEmails: [SnoozedEmail],
        userEmail: String,
        neverNeedsReplySenders: Set<String> = [],
        alwaysNeedsReplySenders: Set<String> = [],
        threadContextMap: [String: ThreadContextInfo] = [:]
    ) -> Briefing {
        let now = Date()
        let unreadCount = emails.filter { $0.isUnread }.count

        var assignedThreadIds = Set<String>()

        // 1. Snoozed Due
        let snoozedDueItems = processSnoozedEmails(
            snoozedEmails,
            assignedThreadIds: &assignedThreadIds
        )

        // 2-5. Classify remaining emails
        var moneyItems: [BriefingItem] = []
        var deadlineItems: [BriefingItem] = []
        var needsReplyItems: [BriefingItem] = []
        var maybeReplyItems: [BriefingItem] = []
        var newsletterItems: [BriefingItem] = []

        for email in emails {
            guard !assignedThreadIds.contains(email.threadId) else { continue }

            let threadContext = threadContextMap[email.threadId]
            let classification = classifyEmail(
                email,
                userEmail: userEmail,
                neverNeedsReplySenders: neverNeedsReplySenders,
                alwaysNeedsReplySenders: alwaysNeedsReplySenders,
                threadHasUserReply: threadContext?.threadHasUserReply ?? false,
                isLatestFromThem: threadContext?.isLatestFromThem ?? true
            )

            guard classification.bucket != .everythingElse else { continue }

            assignedThreadIds.insert(email.threadId)

            let actions = getActions(for: classification.bucket)
            let item = createBriefingItem(
                from: email,
                bucket: classification.bucket,
                reasonTag: classification.reasonTag,
                actions: actions,
                needsReplyScore: classification.needsReplyScore,
                needsReplyReason: classification.needsReplyReason
            )

            switch classification.bucket {
            case .moneyConfirmations:
                moneyItems.append(item)
            case .deadlinesToday:
                deadlineItems.append(item)
            case .needsReply:
                needsReplyItems.append(item)
            case .maybeReply:
                maybeReplyItems.append(item)
            case .newsletters:
                if email.isUnread {
                    newsletterItems.append(item)
                }
            default:
                break
            }
        }

        // Sort and dedupe
        let sortedMoney = moneyItems.sorted { $0.receivedAt > $1.receivedAt }
        let dedupedDeadlines = dedupeByThread(deadlineItems)
        let dedupedNeedsReply = dedupeByThread(needsReplyItems)
            .sorted { ($0.needsReplyScore ?? 0) > ($1.needsReplyScore ?? 0) }
        let dedupedMaybeReply = dedupeByThread(maybeReplyItems)
            .sorted { ($0.needsReplyScore ?? 0) > ($1.needsReplyScore ?? 0) }
        let sortedNewsletters = newsletterItems.sorted { $0.receivedAt > $1.receivedAt }

        // Build sections
        let allSections: [BriefingSection] = [
            BriefingSection(
                sectionId: .snoozedDue,
                title: "Returning Now",
                items: Array(snoozedDueItems.prefix(maxItemsPerSection)),
                total: snoozedDueItems.count
            ),
            BriefingSection(
                sectionId: .needsReply,
                title: "Needs Reply",
                items: Array(dedupedNeedsReply.prefix(maxItemsPerSection)),
                total: dedupedNeedsReply.count
            ),
            BriefingSection(
                sectionId: .maybeReply,
                title: "Maybe Reply",
                items: Array(dedupedMaybeReply.prefix(maxItemsPerSection)),
                total: dedupedMaybeReply.count
            ),
            BriefingSection(
                sectionId: .deadlinesToday,
                title: "Today / Deadlines",
                items: Array(dedupedDeadlines.prefix(maxItemsPerSection)),
                total: dedupedDeadlines.count
            ),
            BriefingSection(
                sectionId: .moneyConfirmations,
                title: "Money & Confirmations",
                items: Array(sortedMoney.prefix(maxItemsPerSection)),
                total: sortedMoney.count
            ),
            BriefingSection(
                sectionId: .newsletters,
                title: "Newsletters",
                items: Array(sortedNewsletters.prefix(maxItemsPerSection)),
                total: sortedNewsletters.count
            )
        ]

        let sections = allSections.filter { !$0.isEmpty }

        let dateFormatter = ISO8601DateFormatter()
        let dateISO = String(dateFormatter.string(from: now).prefix(10))

        return Briefing(
            dateISO: dateISO,
            unreadCount: unreadCount,
            needsReplyCount: dedupedNeedsReply.count,
            sections: sections,
            generatedAt: now
        )
    }

    // MARK: - Classification

    private struct ClassificationResult {
        let bucket: BriefingBucket
        let reasonTag: String
        let needsReplyScore: Int?
        let needsReplyReason: NeedsReplyReason?
    }

    private func classifyEmail(
        _ email: Email,
        userEmail: String,
        neverNeedsReplySenders: Set<String>,
        alwaysNeedsReplySenders: Set<String>,
        threadHasUserReply: Bool,
        isLatestFromThem: Bool
    ) -> ClassificationResult {
        let senderEmail = email.senderEmail

        // 1. Transactional (Money & Confirmations)
        if !alwaysNeedsReplySenders.contains(senderEmail) && isTransactional(email) {
            let reasonTag = getTransactionalReasonTag(email)
            return ClassificationResult(bucket: .moneyConfirmations, reasonTag: reasonTag, needsReplyScore: nil, needsReplyReason: nil)
        }

        // 2. Bulk/Newsletter
        if !alwaysNeedsReplySenders.contains(senderEmail) && isBulk(email) {
            return ClassificationResult(bucket: .newsletters, reasonTag: "Newsletter", needsReplyScore: nil, needsReplyReason: nil)
        }

        // 3. Needs Reply / Maybe Reply
        let (score, reason) = computeNeedsReplyScore(
            email,
            userEmail: userEmail,
            neverNeedsReplySenders: neverNeedsReplySenders,
            alwaysNeedsReplySenders: alwaysNeedsReplySenders,
            threadHasUserReply: threadHasUserReply,
            isLatestFromThem: isLatestFromThem
        )

        if score >= highConfidenceThreshold {
            return ClassificationResult(
                bucket: .needsReply,
                reasonTag: reason?.rawValue ?? "Reply pending",
                needsReplyScore: score,
                needsReplyReason: reason
            )
        }

        if score >= mediumConfidenceThreshold {
            return ClassificationResult(
                bucket: .maybeReply,
                reasonTag: reason?.rawValue ?? "Might need reply",
                needsReplyScore: score,
                needsReplyReason: reason
            )
        }

        // 4. Deadlines
        if let deadlineLabel = getDeadlineLabel(email) {
            return ClassificationResult(bucket: .deadlinesToday, reasonTag: deadlineLabel, needsReplyScore: nil, needsReplyReason: nil)
        }

        // 5. Everything else
        return ClassificationResult(bucket: .everythingElse, reasonTag: "", needsReplyScore: nil, needsReplyReason: nil)
    }

    // MARK: - Bulk Detection

    func isBulk(_ email: Email) -> Bool {
        // Strong signals
        if hasBulkCategoryLabel(email) { return true }
        if hasBulkHeaders(email) { return true }
        if isMarketingPlatformDomain(email) { return true }

        // Medium signals
        if hasBrandSenderName(email) { return true }
        if hasBulkSenderPattern(email) { return true }

        return false
    }

    private func hasBulkCategoryLabel(_ email: Email) -> Bool {
        bulkCategoryLabels.contains { email.labelIds.contains($0) }
    }

    private func hasBulkHeaders(_ email: Email) -> Bool {
        if email.listUnsubscribe != nil { return true }
        if email.listId != nil { return true }

        if let precedence = email.precedence?.lowercased() {
            if bulkPrecedenceValues.contains(where: { precedence.contains($0) }) {
                return true
            }
        }

        if let autoSubmitted = email.autoSubmitted?.lowercased(), autoSubmitted != "no" {
            return true
        }

        return false
    }

    private func hasBulkSenderPattern(_ email: Email) -> Bool {
        let senderEmail = email.senderEmail
        let range = NSRange(senderEmail.startIndex..., in: senderEmail)
        return noReplyPatterns.contains { $0.firstMatch(in: senderEmail, range: range) != nil }
    }

    private func isMarketingPlatformDomain(_ email: Email) -> Bool {
        let domain = email.senderEmail.split(separator: "@").last.map(String.init) ?? ""
        if marketingPlatformDomains.contains(domain) { return true }

        for marketingDomain in marketingPlatformDomains {
            if domain.hasSuffix(".\(marketingDomain)") { return true }
        }

        return false
    }

    private func hasBrandSenderName(_ email: Email) -> Bool {
        let name = email.senderName
        guard name.count >= 2 else { return false }

        let range = NSRange(name.startIndex..., in: name)
        return brandSenderPatterns.contains { $0.firstMatch(in: name, range: range) != nil }
    }

    // MARK: - Transactional Detection

    func isTransactional(_ email: Email) -> Bool {
        let text = "\(email.subject) \(email.snippet)".lowercased()
        let from = email.from
        let senderEmail = email.senderEmail

        let textRange = NSRange(text.startIndex..., in: text)
        let fromRange = NSRange(from.startIndex..., in: from)
        let senderRange = NSRange(senderEmail.startIndex..., in: senderEmail)

        let hasTransactionalKeywords = transactionalKeywords.contains {
            $0.firstMatch(in: text, range: textRange) != nil
        }

        let isKnownTransactionalSender = transactionalSenderPatterns.contains {
            $0.firstMatch(in: from, range: fromRange) != nil
        }

        let hasNoReplyPattern = noReplyPatterns.contains {
            $0.firstMatch(in: senderEmail, range: senderRange) != nil
        }

        let isFromUpdatesCategory = email.labelIds.contains(updatesCategoryLabel)

        // Strong signal: Known transactional sender
        if isKnownTransactionalSender { return true }

        // Strong signal: Updates category + keywords
        if isFromUpdatesCategory && hasTransactionalKeywords { return true }

        // Medium signal: No-reply + keywords
        if hasNoReplyPattern && hasTransactionalKeywords { return true }

        return false
    }

    private func getTransactionalReasonTag(_ email: Email) -> String {
        let text = "\(email.subject) \(email.snippet)".lowercased()

        if text.contains("receipt") || text.contains("invoice") || text.contains("paid") || text.contains("charge") {
            return "Receipt"
        }
        if text.contains("statement") { return "Statement" }
        if text.contains("shipping") || text.contains("tracking") || text.contains("delivery") || text.contains("shipped") {
            return "Shipping"
        }
        if text.contains("flight") || text.contains("hotel") || text.contains("booking") || text.contains("reservation") || text.contains("itinerary") {
            return "Booking"
        }
        if text.contains("order") { return "Order" }
        if text.contains("security") || text.contains("verification") || text.contains("password") {
            return "Security"
        }

        return "Confirmation"
    }

    // MARK: - Human Detection

    func looksLikeHumanSender(_ email: Email) -> Bool {
        let senderEmail = email.senderEmail
        let senderName = email.senderName
        let domain = senderEmail.split(separator: "@").last.map(String.init) ?? ""

        let senderRange = NSRange(senderEmail.startIndex..., in: senderEmail)
        // Note: nameRange removed - not used in current implementation

        // Strong negative: no-reply patterns
        if noReplyPatterns.contains(where: { $0.firstMatch(in: senderEmail, range: senderRange) != nil }) {
            return false
        }

        // Strong negative: brand sender name
        if hasBrandSenderName(email) { return false }

        // Strong positive: personal email domain
        if personalEmailDomains.contains(domain) { return true }

        // Moderate positive: name has a space (First Last pattern)
        if senderName.contains(" ") {
            let words = senderName.split(separator: " ")
            if words.count >= 2 && words.count <= 4 {
                let firstWord = String(words[0])
                let nonNameWords = ["the", "a", "an", "my", "your", "our", "team", "support", "news"]
                if !nonNameWords.contains(firstWord.lowercased()) {
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

    // MARK: - Meeting Invite Detection

    func isMeetingInvite(_ email: Email) -> Bool {
        let text = "\(email.subject) \(email.snippet)"
        let range = NSRange(text.startIndex..., in: text)
        return meetingInvitePatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    // MARK: - Deadline Detection

    private func getDeadlineLabel(_ email: Email) -> String? {
        guard !isTransactional(email) else { return nil }

        let text = "\(email.subject) \(email.snippet)"
        let range = NSRange(text.startIndex..., in: text)

        for (pattern, label) in deadlineKeywords {
            if pattern.firstMatch(in: text, range: range) != nil {
                return label
            }
        }

        return nil
    }

    // MARK: - Needs Reply Scoring

    private func computeNeedsReplyScore(
        _ email: Email,
        userEmail: String,
        neverNeedsReplySenders: Set<String>,
        alwaysNeedsReplySenders: Set<String>,
        threadHasUserReply: Bool,
        isLatestFromThem: Bool
    ) -> (Int, NeedsReplyReason?) {
        var score = 0
        var reason: NeedsReplyReason?

        let senderEmail = email.senderEmail
        let text = "\(email.subject) \(email.snippet)"
        let textRange = NSRange(text.startIndex..., in: text)

        // Never-needs-reply sender
        if neverNeedsReplySenders.contains(senderEmail) {
            return (-10, nil)
        }

        // Always-needs-reply sender (VIP)
        if alwaysNeedsReplySenders.contains(senderEmail) {
            return (10, .replyPending)
        }

        // Not from self
        if senderEmail == userEmail.lowercased() {
            return (0, nil)
        }

        // User already replied gate
        if threadHasUserReply && !isLatestFromThem {
            return (0, nil)
        }

        // Human gate
        let isHuman = looksLikeHumanSender(email)
        let hasConversationEvidence = threadHasUserReply && isLatestFromThem

        if !isHuman && !hasConversationEvidence {
            return (0, nil)
        }

        // Positive signals
        if hasConversationEvidence {
            score += 4
            reason = .conversation
        }

        if isHuman {
            score += 2
        }

        if text.contains("?") {
            score += 2
            if reason == nil { reason = .askedQuestion }
        }

        if directAskPatterns.contains(where: { $0.firstMatch(in: text, range: textRange) != nil }) {
            score += 2
            if reason == nil { reason = .replyPending }
        }

        if getDeadlineLabel(email) != nil {
            score += 1
            if reason == nil { reason = .deadlineMentioned }
        }

        // Negative signals
        if isMeetingInvite(email) {
            return (-10, nil)
        }

        if isBulk(email) {
            score -= 6
        }

        if isTransactional(email) {
            score -= 4
        }

        return (score, reason)
    }

    // MARK: - Helpers

    private func processSnoozedEmails(
        _ snoozedEmails: [SnoozedEmail],
        assignedThreadIds: inout Set<String>
    ) -> [BriefingItem] {
        let now = Date()
        let next24h = now.addingTimeInterval(24 * 60 * 60)

        return snoozedEmails
            .filter { $0.snoozeUntil <= next24h }
            .map { snoozed -> BriefingItem in
                assignedThreadIds.insert(snoozed.threadId)
                return createSnoozedItem(snoozed)
            }
            .sorted { $0.receivedAt < $1.receivedAt }
    }

    private func createSnoozedItem(_ snoozed: SnoozedEmail) -> BriefingItem {
        let isToday = Calendar.current.isDateInToday(snoozed.snoozeUntil)
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        let timeStr = timeFormatter.string(from: snoozed.snoozeUntil)
        let reasonTag = isToday ? "Due \(timeStr)" : "Returning"

        return BriefingItem(
            threadId: snoozed.threadId,
            messageId: snoozed.id,
            senderName: EmailParser.extractSenderName(from: snoozed.from),
            senderEmail: EmailParser.extractSenderEmail(from: snoozed.from),
            subject: snoozed.subject,
            snippet: String(snoozed.snippet.prefix(120)),
            receivedAt: snoozed.date,
            reasonTag: reasonTag,
            actions: [.open, .unsnooze, .archive],
            bucket: .snoozedDue,
            needsReplyScore: nil,
            needsReplyReason: nil
        )
    }

    private func createBriefingItem(
        from email: Email,
        bucket: BriefingBucket,
        reasonTag: String,
        actions: [BriefingAction],
        needsReplyScore: Int?,
        needsReplyReason: NeedsReplyReason?
    ) -> BriefingItem {
        BriefingItem(
            threadId: email.threadId,
            messageId: email.id,
            senderName: email.senderName,
            senderEmail: email.senderEmail,
            subject: email.subject,
            snippet: String(email.snippet.prefix(120)),
            receivedAt: email.date,
            reasonTag: reasonTag,
            actions: actions,
            bucket: bucket,
            needsReplyScore: needsReplyScore,
            needsReplyReason: needsReplyReason
        )
    }

    private func getActions(for bucket: BriefingBucket) -> [BriefingAction] {
        switch bucket {
        case .snoozedDue:
            return [.open, .unsnooze, .archive]
        case .moneyConfirmations:
            return [.open, .pin, .archive]
        case .deadlinesToday:
            return [.open, .snooze, .archive]
        case .needsReply, .maybeReply:
            return [.reply, .snooze, .archive, .notAReply]
        case .newsletters:
            return [.read, .archive]
        case .everythingElse:
            return [.open, .archive]
        }
    }

    private func dedupeByThread(_ items: [BriefingItem]) -> [BriefingItem] {
        var seen = Set<String>()
        return items
            .sorted { $0.receivedAt > $1.receivedAt }
            .filter { item in
                if seen.contains(item.threadId) { return false }
                seen.insert(item.threadId)
                return true
            }
    }
}
