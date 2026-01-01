import Foundation
import OSLog

// MARK: - Email Filters
// Pure functions for email classification, ported from React briefingEngine.ts

private let logger = Logger(subsystem: "com.simplemail.app", category: "EmailFilters")

enum EmailFilters {

    // MARK: - Personal Email Domains
    // Emails from these domains are likely from real people

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

    // MARK: - No-Reply Patterns

    private static let noReplyPatterns: [NSRegularExpression] = {
        let patterns = [
            "no-?reply",
            "noreply",
            "do-?not-?reply",
            "donotreply",
            "notifications?@",
            "notify@",
            "alerts?@",
            "mailer@",
            "bounce@",
            "auto@",
            "automated@",
            "system@",
            "info@",
            "support@",
            "help@",
            "contact@",
            "hello@",
            "team@",
            "news@",
            "updates?@",
            "marketing@",
            "promo@",
            "sales@",
            "billing@",
            "service@",
            "admin@",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    // MARK: - Via Patterns (sender name contains "via X")

    private static let viaPatterns: [NSRegularExpression] = {
        let patterns = [
            "via\\s+\\w+",
            "through\\s+\\w+",
            "by way of",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    // MARK: - Brand/Org Sender Name Patterns

    private static let brandSenderPatterns: [NSRegularExpression] = {
        let patterns = [
            "^(The\\s+)?\\w+\\s+(Team|Support|News|Updates|Notifications?)$",
            "^\\w+(\\.com|\\.io|\\.co|\\.org)$",
            "^[A-Z][a-z]+[A-Z]",  // CamelCase like "LinkedIn"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    // MARK: - Org-like Name Patterns

    private static let orgNamePatterns: [NSRegularExpression] = {
        let patterns = [
            "\\b(Inc|LLC|Ltd|Corp|Co|Team|Support|News|Updates|Notifications?|Service|Newsletter)\\b",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    // MARK: - Marketing Platform Domains

    private static let marketingPlatformDomains: Set<String> = [
        // Email service providers
        "mailchimp.com", "sendgrid.net", "sendgrid.com",
        "amazonses.com", "mailgun.org", "mailgun.com",
        "postmarkapp.com", "sparkpostmail.com",
        "constantcontact.com", "campaign-archive.com",
        "createsend.com", "cmail19.com", "cmail20.com",
        "hubspot.com", "hs-analytics.net",
        "klaviyo.com", "sailthru.com",
        "braze.com", "iterable.com",
        "customer.io", "intercom-mail.com",
        "drip.com", "convertkit.com",
        "activecampaign.com", "aweber.com",
        "getresponse.com", "sendinblue.com",
        // Transactional/notification platforms
        "transmail.net", "rsgsv.net",
        "mcsv.net", "list-manage.com",
    ]

    // MARK: - Bulk Gmail Category Labels

    private static let bulkCategoryLabels: Set<String> = [
        "CATEGORY_PROMOTIONS",
        "CATEGORY_SOCIAL",
        "CATEGORY_UPDATES",
        "CATEGORY_FORUMS",
    ]

    // MARK: - Bulk Precedence Header Values

    private static let bulkPrecedenceValues: Set<String> = [
        "bulk", "list", "junk",
    ]

    // MARK: - Public API

    /// Check if sender looks like a real person (human gate)
    /// Positive signals: personal domain, First Last name pattern
    /// Negative signals: no-reply patterns, brand names, via patterns
    static func looksLikeHumanSender(_ email: Email) -> Bool {
        let senderEmail = email.senderEmail.lowercased()
        let senderName = email.senderName
        let domain = senderEmail.split(separator: "@").last.map(String.init) ?? ""

        // Strong negative: no-reply patterns in email
        if matchesAnyPattern(senderEmail, patterns: noReplyPatterns) {
            return false
        }

        // Strong negative: brand sender name
        if hasBrandSenderName(senderName) {
            return false
        }

        // Strong negative: "via" patterns in name (e.g., "John via Calendly")
        if matchesAnyPattern(senderName, patterns: viaPatterns) {
            return false
        }

        // Strong positive: personal email domain
        if personalEmailDomains.contains(domain) {
            return true
        }

        // Moderate positive: name has a space (First Last pattern)
        // And doesn't match org patterns
        if senderName.contains(" ") && !hasOrgLikeName(senderName) {
            let words = senderName.split(separator: " ")
            if words.count >= 2 && words.count <= 4 {
                let firstWord = String(words[0]).lowercased()
                // Check it's not just "The Company" or "My Team"
                let nonNameWords: Set<String> = ["the", "a", "an", "my", "your", "our", "team", "support", "news"]
                if !nonNameWords.contains(firstWord) {
                    return true
                }
            }
        }

        // Single-word names are likely org/brand unless from personal domain
        if !senderName.contains(" ") && senderName.count > 3 {
            return false
        }

        // Default: uncertain, lean towards not human
        return false
    }

    /// Check if email is bulk/newsletter/automated
    /// Uses Gmail categories, headers, and sender patterns
    static func isBulk(_ email: Email) -> Bool {
        // Strong signals - immediate bulk
        if hasBulkCategoryLabel(email) { return true }
        if hasBulkHeaders(email) { return true }
        if isMarketingPlatformDomain(email) { return true }

        // Medium signals
        if hasBrandSenderName(email.senderName) { return true }
        if hasBulkSenderPattern(email) { return true }

        return false
    }

    /// Filter emails to only show those from real people
    /// Matches React's filterForPeopleScope function
    static func filterForPeopleScope(_ emails: [Email]) -> [Email] {
        logger.info("filterForPeopleScope: Processing \(emails.count) emails")

        let result = emails.filter { email in
            let isHuman = looksLikeHumanSender(email)
            let bulk = isBulk(email)
            let hasSent = email.labelIds.contains("SENT")

            // Keep if it looks like a human sender AND is not bulk
            if isHuman && !bulk {
                return true
            }
            // Also keep emails we've replied to (conversation evidence)
            if hasSent {
                return true
            }

            // Log why email was filtered out
            logger.debug("Filtered out: \(email.senderName) <\(email.senderEmail)> - isHuman=\(isHuman), isBulk=\(bulk)")
            return false
        }

        logger.info("filterForPeopleScope: Kept \(result.count) of \(emails.count) emails")
        return result
    }

    // MARK: - Private Helpers

    private static func matchesAnyPattern(_ string: String, patterns: [NSRegularExpression]) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return patterns.contains { $0.firstMatch(in: string, range: range) != nil }
    }

    private static func hasBrandSenderName(_ name: String) -> Bool {
        guard name.count >= 2 else { return false }
        return matchesAnyPattern(name, patterns: brandSenderPatterns)
    }

    private static func hasOrgLikeName(_ name: String) -> Bool {
        // No space in name (like "Experian") or matches org patterns
        let hasNoSpace = !name.contains(" ") && name.count > 3
        let matchesOrgPattern = matchesAnyPattern(name, patterns: orgNamePatterns)
        return hasNoSpace || matchesOrgPattern
    }

    private static func hasBulkCategoryLabel(_ email: Email) -> Bool {
        return !bulkCategoryLabels.isDisjoint(with: email.labelIds)
    }

    private static func hasBulkHeaders(_ email: Email) -> Bool {
        // List-Unsubscribe header
        if email.listUnsubscribe != nil { return true }

        // List-ID header
        if email.listId != nil { return true }

        // Precedence header (bulk, list, junk)
        if let precedence = email.precedence?.lowercased() {
            if bulkPrecedenceValues.contains(where: { precedence.contains($0) }) {
                return true
            }
        }

        // Auto-Submitted header (anything except "no" means automated)
        if let autoSubmitted = email.autoSubmitted?.lowercased(), autoSubmitted != "no" {
            return true
        }

        return false
    }

    private static func hasBulkSenderPattern(_ email: Email) -> Bool {
        let senderEmail = email.senderEmail.lowercased()
        return matchesAnyPattern(senderEmail, patterns: noReplyPatterns)
    }

    private static func isMarketingPlatformDomain(_ email: Email) -> Bool {
        let senderEmail = email.senderEmail.lowercased()
        let domain = senderEmail.split(separator: "@").last.map(String.init) ?? ""

        // Direct match
        if marketingPlatformDomains.contains(domain) { return true }

        // Subdomain match (e.g., "mail.sendgrid.net")
        for marketingDomain in marketingPlatformDomains {
            if domain.hasSuffix(".\(marketingDomain)") { return true }
        }

        return false
    }
}
