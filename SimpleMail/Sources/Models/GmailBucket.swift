import Foundation

/// High-level Gmail buckets shown inline in the inbox (Promotions/Updates/Social).
enum GmailBucket: String, CaseIterable, Codable, Hashable {
    case promotions
    case updates
    case social

    var title: String {
        switch self {
        case .promotions: return "Promotions"
        case .updates: return "Updates"
        case .social: return "Social"
        }
    }

    /// Gmail label backing this bucket.
    var gmailLabel: String {
        switch self {
        case .promotions: return "CATEGORY_PROMOTIONS"
        case .updates: return "CATEGORY_UPDATES"
        case .social: return "CATEGORY_SOCIAL"
        }
    }
}

extension GmailBucket {
    var category: GmailCategory {
        switch self {
        case .promotions: return .promotions
        case .updates: return .updates
        case .social: return .social
        }
    }
}
