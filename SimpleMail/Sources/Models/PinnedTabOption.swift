import Foundation
import SwiftUI

enum PinnedTabOption: String, CaseIterable, Identifiable, Hashable {
    case other
    case money
    case deadlines
    case needsReply
    case unread
    case newsletters
    case people

    var id: String { rawValue }

    var title: String {
        switch self {
        case .other: return "Other"
        case .money: return "Money"
        case .deadlines: return "Deadlines"
        case .needsReply: return "Needs Reply"
        case .unread: return "Unread"
        case .newsletters: return "Newsletters"
        case .people: return "People"
        }
    }

    var symbolName: String {
        switch self {
        case .other: return "tray"
        case .money: return "dollarsign.circle"
        case .deadlines: return "calendar.badge.exclamationmark"
        case .needsReply: return "arrowshape.turn.up.left"
        case .unread: return "envelope.badge"
        case .newsletters: return "newspaper"
        case .people: return "person.2"
        }
    }

    var color: Color {
        switch self {
        case .other: return .gray
        case .money: return .green
        case .deadlines: return .red
        case .needsReply: return .orange
        case .unread: return .blue
        case .newsletters: return .purple
        case .people: return .cyan
        }
    }
}
