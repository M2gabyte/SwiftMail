import Foundation

enum BriefingItemType: String, Codable, CaseIterable {
    case deadline
    case oweReply = "owe_reply"
    case waiting
    case money
}

enum BriefingConfidence: String, Codable {
    case high
    case medium
    case low
}

struct BriefingItem: Identifiable, Codable, Hashable {
    var id: String
    let type: BriefingItemType
    let title: String
    let whyQuote: String
    let sourceThreadId: String
    var sourceMessageIds: [String]
    let confidence: BriefingConfidence
    let dueAt: String?
}

struct BriefingSnapshot: Codable {
    let items: [BriefingItem]
    let sources: [BriefingThreadHit]
    let generatedAt: Date
    let scopeDays: Int
    let generationNote: String?
    let debugInfo: BriefingDebugInfo?
}

struct BriefingDebugInfo: Codable {
    let candidateCount: Int
    let shortlistCount: Int
    let aiItemCount: Int
    let keptItemCount: Int
}

struct BriefingUserState: Codable {
    var doneItemIds: Set<String> = []
    var snoozedUntil: [String: Date] = [:]
    var mutedThreadIds: Set<String> = []
    var mutedSenders: Set<String> = []
}

struct BriefingThreadHit: Codable, Hashable {
    let threadId: String
    let messageId: String
    let subject: String
    let from: String
    let dateISO: String
    let snippet: String
    let isUnread: Bool
    let labelIds: [String]
    let accountEmail: String?
    let excerpt: String?
}
