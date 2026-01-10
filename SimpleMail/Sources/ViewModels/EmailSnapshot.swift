import Foundation

struct EmailSnapshot: Sendable, Hashable {
    let id: String
    let threadId: String
    let date: Date
    let subject: String
    let snippet: String
    let senderEmail: String
    let senderName: String
    let isUnread: Bool
    let isStarred: Bool
    let hasAttachments: Bool
    let accountEmail: String?
    let labelIdsKey: String
    let listUnsubscribe: String?
    let listId: String?
    let precedence: String?
    let autoSubmitted: String?
    let messagesCount: Int
}

extension EmailSnapshot {
    /// Convert snapshot to DTO (pure value type conversion, no SwiftData access)
    func toDTO() -> EmailDTO {
        let fromString: String = {
            if !senderName.isEmpty && senderName.lowercased() != senderEmail.lowercased() {
                return "\(senderName) <\(senderEmail)>"
            }
            return senderEmail
        }()
        return EmailDTO(
            id: id,
            threadId: threadId,
            snippet: snippet,
            subject: subject,
            from: fromString,
            date: date,
            isUnread: isUnread,
            isStarred: isStarred,
            hasAttachments: hasAttachments,
            labelIds: labelIdsKey.isEmpty ? [] : labelIdsKey.split(separator: "|").map(String.init),
            messagesCount: messagesCount,
            accountEmail: accountEmail,
            listUnsubscribe: listUnsubscribe,
            listId: listId,
            precedence: precedence,
            autoSubmitted: autoSubmitted
        )
    }
}
