import Foundation

struct EmailSection: Identifiable, Sendable {
    let id: String
    let title: String
    let emails: [EmailDTO]
}
