import Foundation

/// Parsed search filter supporting smart queries like "from:john", "subject:meeting", etc.
struct SearchFilter {
    var fromFilter: String?
    var subjectFilter: String?
    var bodyFilter: String?
    var isUnread: Bool?
    var isStarred: Bool?
    var hasAttachment: Bool?
    var generalQuery: String?

    /// Available smart filter suggestions
    static let suggestions: [(prefix: String, description: String, icon: String)] = [
        ("from:", "Search by sender", "person"),
        ("subject:", "Search by subject", "text.alignleft"),
        ("is:unread", "Show unread only", "envelope.badge"),
        ("is:starred", "Show starred only", "star"),
        ("has:attachment", "Has attachments", "paperclip"),
    ]

    /// Parse a search query into structured filters
    static func parse(_ query: String) -> SearchFilter {
        var filter = SearchFilter()
        var remaining: [String] = []

        // Split by spaces, respecting quoted strings
        let tokens = tokenize(query)

        for token in tokens {
            let lower = token.lowercased()

            if lower.hasPrefix("from:") {
                filter.fromFilter = String(token.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("subject:") {
                filter.subjectFilter = String(token.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("body:") {
                filter.bodyFilter = String(token.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if lower == "is:unread" {
                filter.isUnread = true
            } else if lower == "is:read" {
                filter.isUnread = false
            } else if lower == "is:starred" {
                filter.isStarred = true
            } else if lower == "has:attachment" || lower == "has:attachments" {
                filter.hasAttachment = true
            } else {
                remaining.append(token)
            }
        }

        if !remaining.isEmpty {
            filter.generalQuery = remaining.joined(separator: " ")
        }

        return filter
    }

    /// Check if an email matches this filter
    func matches(_ email: Email) -> Bool {
        // Check from filter
        if let from = fromFilter, !from.isEmpty {
            let matchesFrom = email.senderName.localizedCaseInsensitiveContains(from) ||
                              email.senderEmail.localizedCaseInsensitiveContains(from)
            if !matchesFrom { return false }
        }

        // Check subject filter
        if let subject = subjectFilter, !subject.isEmpty {
            if !email.subject.localizedCaseInsensitiveContains(subject) {
                return false
            }
        }

        // Check body filter
        if let body = bodyFilter, !body.isEmpty {
            if !email.snippet.localizedCaseInsensitiveContains(body) {
                return false
            }
        }

        // Check unread status
        if let isUnread = isUnread {
            if email.isUnread != isUnread { return false }
        }

        // Check starred status
        if let isStarred = isStarred {
            if email.isStarred != isStarred { return false }
        }

        // Check attachments
        if let hasAttachment = hasAttachment, hasAttachment {
            if !email.hasAttachments { return false }
        }

        // Check general query against all fields
        if let query = generalQuery, !query.isEmpty {
            let matchesAny = email.senderName.localizedCaseInsensitiveContains(query) ||
                             email.senderEmail.localizedCaseInsensitiveContains(query) ||
                             email.subject.localizedCaseInsensitiveContains(query) ||
                             email.snippet.localizedCaseInsensitiveContains(query)
            if !matchesAny { return false }
        }

        return true
    }

    /// Check if an EmailDTO matches this filter
    func matches(_ email: EmailDTO) -> Bool {
        // Check from filter
        if let from = fromFilter, !from.isEmpty {
            let matchesFrom = email.senderName.localizedCaseInsensitiveContains(from) ||
                              email.senderEmail.localizedCaseInsensitiveContains(from)
            if !matchesFrom { return false }
        }

        // Check subject filter
        if let subject = subjectFilter, !subject.isEmpty {
            if !email.subject.localizedCaseInsensitiveContains(subject) {
                return false
            }
        }

        // Check body filter
        if let body = bodyFilter, !body.isEmpty {
            if !email.snippet.localizedCaseInsensitiveContains(body) {
                return false
            }
        }

        // Check unread status
        if let isUnread = isUnread {
            if email.isUnread != isUnread { return false }
        }

        // Check starred status
        if let isStarred = isStarred {
            if email.isStarred != isStarred { return false }
        }

        // Check attachments
        if let hasAttachment = hasAttachment, hasAttachment {
            if !email.hasAttachments { return false }
        }

        // Check general query against all fields
        if let query = generalQuery, !query.isEmpty {
            let matchesAny = email.senderName.localizedCaseInsensitiveContains(query) ||
                             email.senderEmail.localizedCaseInsensitiveContains(query) ||
                             email.subject.localizedCaseInsensitiveContains(query) ||
                             email.snippet.localizedCaseInsensitiveContains(query)
            if !matchesAny { return false }
        }

        return true
    }

    /// Get the search terms for highlighting
    var highlightTerms: [String] {
        var terms: [String] = []
        if let from = fromFilter { terms.append(from) }
        if let subject = subjectFilter { terms.append(subject) }
        if let body = bodyFilter { terms.append(body) }
        if let query = generalQuery {
            terms.append(contentsOf: query.components(separatedBy: " ").filter { !$0.isEmpty })
        }
        return terms
    }

    /// Tokenize query respecting quoted strings
    private static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in query {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == " " && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
