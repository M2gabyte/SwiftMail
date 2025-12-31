import Foundation

// MARK: - Briefing Types

enum BriefingBucket: String, CaseIterable, Codable {
    case snoozedDue = "snoozed_due"
    case moneyConfirmations = "money_confirmations"
    case deadlinesToday = "deadlines_today"
    case needsReply = "needs_reply"
    case maybeReply = "maybe_reply"
    case newsletters = "newsletters"
    case everythingElse = "everything_else"
}

typealias BriefingSectionId = BriefingBucket

enum NeedsReplyReason: String, Codable {
    case askedQuestion = "Asked a question"
    case replyPending = "Reply pending"
    case deadlineMentioned = "Deadline mentioned"
    case conversation = "Conversation"
}

enum BriefingAction: String, CaseIterable, Codable {
    case reply
    case open
    case snooze
    case archive
    case pin
    case unsnooze
    case read
    case notAReply = "not_a_reply"
}

// MARK: - Briefing Item

struct BriefingItem: Identifiable, Equatable {
    let threadId: String
    let messageId: String
    let senderName: String
    let senderEmail: String
    let subject: String
    let snippet: String
    let receivedAt: Date
    let reasonTag: String
    let actions: [BriefingAction]
    let bucket: BriefingBucket
    let needsReplyScore: Int?
    let needsReplyReason: NeedsReplyReason?

    var id: String { messageId }
}

// MARK: - Briefing Section

struct BriefingSection: Identifiable {
    let sectionId: BriefingSectionId
    let title: String
    var items: [BriefingItem]
    let total: Int

    var id: String { sectionId.rawValue }

    var isEmpty: Bool { items.isEmpty }
}

// MARK: - Briefing

struct Briefing {
    let dateISO: String
    let unreadCount: Int
    let needsReplyCount: Int
    var sections: [BriefingSection]
    let generatedAt: Date

    static var empty: Briefing {
        Briefing(
            dateISO: ISO8601DateFormatter().string(from: Date()).prefix(10).description,
            unreadCount: 0,
            needsReplyCount: 0,
            sections: [],
            generatedAt: Date()
        )
    }
}

// MARK: - Classification Types

enum ClassificationType: String, Codable {
    case needsReply
    case deadline
    case money
    case newsletter
    case none
}

struct IndexClassification {
    let type: ClassificationType
    let confidence: Double
    let reason: String
}

// MARK: - Thread Context

struct ThreadContextInfo {
    let threadHasUserReply: Bool
    let isLatestFromThem: Bool
}

// MARK: - Section Helpers

extension BriefingSectionId {
    var displayTitle: String {
        switch self {
        case .snoozedDue: return "Returning Now"
        case .moneyConfirmations: return "Money & Confirmations"
        case .deadlinesToday: return "Today / Deadlines"
        case .needsReply: return "Needs Reply"
        case .maybeReply: return "Maybe Reply"
        case .newsletters: return "Newsletters"
        case .everythingElse: return "Other"
        }
    }

    var primaryAction: BriefingAction {
        switch self {
        case .snoozedDue: return .unsnooze
        case .moneyConfirmations: return .open
        case .deadlinesToday: return .snooze
        case .needsReply: return .reply
        case .maybeReply: return .reply
        case .newsletters: return .read
        case .everythingElse: return .open
        }
    }

    var icon: String {
        switch self {
        case .snoozedDue: return "clock.arrow.circlepath"
        case .moneyConfirmations: return "dollarsign.circle"
        case .deadlinesToday: return "calendar.badge.exclamationmark"
        case .needsReply: return "arrowshape.turn.up.left.circle"
        case .maybeReply: return "questionmark.circle"
        case .newsletters: return "newspaper"
        case .everythingElse: return "tray"
        }
    }
}
