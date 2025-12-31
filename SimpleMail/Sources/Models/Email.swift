import Foundation
import SwiftData

// MARK: - Core Email Model

@Model
final class Email: Identifiable {
    @Attribute(.unique) var id: String
    var threadId: String
    var snippet: String
    var subject: String
    var from: String
    var date: Date
    var isUnread: Bool
    var isStarred: Bool
    var hasAttachments: Bool
    var labelIds: [String]
    var messagesCount: Int
    var accountEmail: String?

    // Bulk detection headers (for briefing classification)
    var listUnsubscribe: String?
    var listId: String?
    var precedence: String?
    var autoSubmitted: String?

    init(
        id: String,
        threadId: String,
        snippet: String = "",
        subject: String = "",
        from: String = "",
        date: Date = Date(),
        isUnread: Bool = true,
        isStarred: Bool = false,
        hasAttachments: Bool = false,
        labelIds: [String] = [],
        messagesCount: Int = 1,
        accountEmail: String? = nil,
        listUnsubscribe: String? = nil,
        listId: String? = nil,
        precedence: String? = nil,
        autoSubmitted: String? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.snippet = snippet
        self.subject = subject
        self.from = from
        self.date = date
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.hasAttachments = hasAttachments
        self.labelIds = labelIds
        self.messagesCount = messagesCount
        self.accountEmail = accountEmail
        self.listUnsubscribe = listUnsubscribe
        self.listId = listId
        self.precedence = precedence
        self.autoSubmitted = autoSubmitted
    }
}

// MARK: - Email Detail (with full body)

@Model
final class EmailDetail: Identifiable {
    @Attribute(.unique) var id: String
    var threadId: String
    var snippet: String
    var subject: String
    var from: String
    var date: Date
    var isUnread: Bool
    var isStarred: Bool
    var hasAttachments: Bool
    var labelIds: [String]
    var body: String
    var to: [String]
    var cc: [String]

    init(
        id: String,
        threadId: String,
        snippet: String = "",
        subject: String = "",
        from: String = "",
        date: Date = Date(),
        isUnread: Bool = true,
        isStarred: Bool = false,
        hasAttachments: Bool = false,
        labelIds: [String] = [],
        body: String = "",
        to: [String] = [],
        cc: [String] = []
    ) {
        self.id = id
        self.threadId = threadId
        self.snippet = snippet
        self.subject = subject
        self.from = from
        self.date = date
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.hasAttachments = hasAttachments
        self.labelIds = labelIds
        self.body = body
        self.to = to
        self.cc = cc
    }
}

// MARK: - Snoozed Email

@Model
final class SnoozedEmail: Identifiable {
    @Attribute(.unique) var id: String
    var threadId: String
    var subject: String
    var snippet: String
    var from: String
    var date: Date
    var snoozeUntil: Date

    init(
        id: String,
        threadId: String,
        subject: String,
        snippet: String,
        from: String,
        date: Date,
        snoozeUntil: Date
    ) {
        self.id = id
        self.threadId = threadId
        self.subject = subject
        self.snippet = snippet
        self.from = from
        self.date = date
        self.snoozeUntil = snoozeUntil
    }
}

// MARK: - Sender Preferences

@Model
final class SenderPreference: Identifiable {
    @Attribute(.unique) var email: String
    var neverNeedsReply: Bool
    var alwaysNeedsReply: Bool
    var createdAt: Date

    var id: String { email }

    init(email: String, neverNeedsReply: Bool = false, alwaysNeedsReply: Bool = false) {
        self.email = email
        self.neverNeedsReply = neverNeedsReply
        self.alwaysNeedsReply = alwaysNeedsReply
        self.createdAt = Date()
    }
}

// MARK: - Helper Extensions

extension Email {
    var senderEmail: String {
        EmailParser.extractSenderEmail(from: from)
    }

    var senderName: String {
        EmailParser.extractSenderName(from: from)
    }

    var senderInitials: String {
        let name = senderName
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

// MARK: - Email Parser

enum EmailParser {
    static func extractSenderEmail(from: String) -> String {
        if let match = from.range(of: "<([^>]+)>", options: .regularExpression) {
            let email = from[match].dropFirst().dropLast()
            return String(email).lowercased()
        }
        if from.contains("@") {
            return from.lowercased().trimmingCharacters(in: .whitespaces)
        }
        return from.lowercased()
    }

    static func extractSenderName(from: String) -> String {
        if let match = from.range(of: "^([^<]+)\\s*<", options: .regularExpression) {
            let name = from[from.startIndex..<match.upperBound]
                .dropLast()
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")
            return name
        }
        if let match = from.range(of: "<([^>]+)>", options: .regularExpression) {
            let email = from[match].dropFirst().dropLast()
            return String(email.split(separator: "@").first ?? Substring(email))
        }
        if from.contains("@") {
            return String(from.split(separator: "@").first ?? Substring(from))
        }
        return from.trimmingCharacters(in: .whitespaces)
    }
}
