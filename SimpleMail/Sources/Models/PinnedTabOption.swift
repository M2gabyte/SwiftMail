import Foundation

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
}
