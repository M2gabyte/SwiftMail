import Foundation

/// High-level Gmail buckets shown inline in the inbox (Promotions/Updates/Social/Forums).
enum GmailBucket: String, CaseIterable, Codable, Hashable {
    case promotions
    case updates
    case social
    case forums

    var title: String {
        switch self {
        case .promotions: return "Promotions"
        case .updates: return "Updates"
        case .social: return "Social"
        case .forums: return "Forums"
        }
    }

    /// Gmail label backing this bucket.
    var gmailLabel: String {
        switch self {
        case .promotions: return "CATEGORY_PROMOTIONS"
        case .updates: return "CATEGORY_UPDATES"
        case .social: return "CATEGORY_SOCIAL"
        case .forums: return "CATEGORY_FORUMS"
        }
    }
}

extension GmailBucket {
    var category: GmailCategory {
        switch self {
        case .promotions: return .promotions
        case .updates: return .updates
        case .social: return .social
        case .forums: return .forums
        }
    }
}
