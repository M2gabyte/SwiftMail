import Foundation
import SwiftUI

// EmailDTO is defined in Email.swift

/// Gmail category for bundling non-Primary emails
enum GmailCategory: String, CaseIterable, Identifiable, Sendable {
    case promotions = "CATEGORY_PROMOTIONS"
    case social = "CATEGORY_SOCIAL"
    case updates = "CATEGORY_UPDATES"
    case forums = "CATEGORY_FORUMS"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .promotions: return "Promotions"
        case .social: return "Social"
        case .updates: return "Updates"
        case .forums: return "Forums"
        }
    }

    var icon: String {
        switch self {
        case .promotions: return "tag.fill"
        case .social: return "person.2.fill"
        case .updates: return "info.circle.fill"
        case .forums: return "bubble.left.and.bubble.right.fill"
        }
    }

    var color: Color {
        switch self {
        case .promotions: return .green
        case .social: return .blue
        case .updates: return .yellow
        case .forums: return .purple
        }
    }
}

/// A collapsed bundle of emails from a Gmail category
struct CategoryBundle: Identifiable, Sendable {
    let category: GmailCategory
    let unreadCount: Int
    let totalCount: Int
    let latestEmail: EmailDTO?

    var id: String { category.rawValue }

    var previewText: String {
        if let email = latestEmail {
            return "\(email.senderName) - \(email.displaySubject)"
        }
        return ""
    }
}
