import Foundation

enum PrimaryRule: String, CaseIterable, Identifiable, Hashable {
    case people
    case vip
    case security
    case money
    case deadlines
    case newsletters
    case promotions
    case social
    case forums
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: return "People"
        case .vip: return "VIP"
        case .security: return "Security"
        case .money: return "Money"
        case .deadlines: return "Deadlines"
        case .newsletters: return "Newsletters"
        case .promotions: return "Promotions"
        case .social: return "Social"
        case .forums: return "Forums"
        case .updates: return "Updates"
        }
    }

    var defaultsKey: String { "primaryRule.\(rawValue)" }

    var defaultEnabled: Bool {
        switch self {
        case .people, .vip, .security, .money, .deadlines:
            return true
        default:
            return false
        }
    }
}
