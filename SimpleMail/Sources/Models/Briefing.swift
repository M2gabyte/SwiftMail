import Foundation

enum BriefingItemType: String, Codable, CaseIterable { case deadline, owe_reply, waiting, money }
enum BriefingConfidence: String, Codable { case high, medium, low }

struct BriefingItem: Identifiable, Codable, Hashable {
    let id: String
    let type: BriefingItemType
    let title: String
    let whyQuote: String
    let sourceThreadId: String
    let sourceMessageIds: [String]
    let confidence: BriefingConfidence
    let dueAt: Date?
    init(id: String = UUID().uuidString, type: BriefingItemType, title: String, whyQuote: String, sourceThreadId: String, sourceMessageIds: [String], confidence: BriefingConfidence, dueAt: Date? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.whyQuote = whyQuote
        self.sourceThreadId = sourceThreadId
        self.sourceMessageIds = sourceMessageIds
        self.confidence = confidence
        self.dueAt = dueAt
    }
}

struct BriefingThreadHit: Codable, Hashable {
    let threadId: String
    let messageIds: [String]
    let subject: String
    let from: String
    let date: Date
    let snippet: String
}

struct BriefingDebugInfo: Codable {
    let note: String?
}

struct BriefingSnapshot: Codable {
    let items: [BriefingItem]
    let sources: [BriefingThreadHit]
    let debugInfo: BriefingDebugInfo?
}
