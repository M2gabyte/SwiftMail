import Foundation
import OSLog

// MARK: - Base64URL Utilities

enum Base64URL {
    /// Encode data to URL-safe Base64 (no padding)
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode URL-safe Base64 to string
    static func decode(_ encoded: String) -> String? {
        let base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding efficiently
        let paddingLength = (4 - base64.count % 4) % 4
        let padded = paddingLength > 0 ? base64 + String(repeating: "=", count: paddingLength) : base64

        guard let data = Data(base64Encoded: padded) else {
            logger.warning("Failed to decode Base64URL data")
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Decode URL-safe Base64 to Data
    static func decodeToData(_ encoded: String) -> Data? {
        let base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let paddingLength = (4 - base64.count % 4) % 4
        let padded = paddingLength > 0 ? base64 + String(repeating: "=", count: paddingLength) : base64

        return Data(base64Encoded: padded)
    }
}

// MARK: - MIME Message Builder (Result Builder Pattern)

/// Result builder for type-safe MIME header construction
@resultBuilder
struct MIMEHeaderBuilder {
    /// Combine multiple header arrays into one
    static func buildBlock(_ components: [MIMEHeader]...) -> [MIMEHeader] {
        components.flatMap { $0 }
    }

    /// Handle optional headers (if statements without else)
    static func buildOptional(_ component: [MIMEHeader]?) -> [MIMEHeader] {
        component ?? []
    }

    /// Handle if-else first branch
    static func buildEither(first component: [MIMEHeader]) -> [MIMEHeader] {
        component
    }

    /// Handle if-else second branch
    static func buildEither(second component: [MIMEHeader]) -> [MIMEHeader] {
        component
    }

    /// Handle for-in loops
    static func buildArray(_ components: [[MIMEHeader]]) -> [MIMEHeader] {
        components.flatMap { $0 }
    }

    /// Convert single header to array
    static func buildExpression(_ expression: MIMEHeader) -> [MIMEHeader] {
        [expression]
    }

    /// Convert optional header to array
    static func buildExpression(_ expression: MIMEHeader?) -> [MIMEHeader] {
        expression.map { [$0] } ?? []
    }
}

/// A single MIME header (name: value)
struct MIMEHeader: Sendable {
    let name: String
    let value: String

    var rendered: String { "\(name): \(value)" }
}

/// Type-safe MIME message construction
struct MIMEMessage: Sendable {
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let body: String
    let bodyHtml: String?
    let inReplyTo: String?
    let references: String?

    init(
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        body: String,
        bodyHtml: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.bodyHtml = bodyHtml
        self.inReplyTo = inReplyTo
        self.references = references
    }

    /// Build headers using result builder for clean syntax
    @MIMEHeaderBuilder
    private var headers: [MIMEHeader] {
        MIMEHeader(name: "To", value: to.joined(separator: ", "))

        if !cc.isEmpty {
            MIMEHeader(name: "Cc", value: cc.joined(separator: ", "))
        }

        if !bcc.isEmpty {
            MIMEHeader(name: "Bcc", value: bcc.joined(separator: ", "))
        }

        MIMEHeader(name: "Subject", value: subject)
        MIMEHeader(name: "MIME-Version", value: "1.0")

        if let reply = inReplyTo {
            MIMEHeader(name: "In-Reply-To", value: reply)
        }

        if let refs = references {
            MIMEHeader(name: "References", value: refs)
        }
    }

    func build() -> String {
        if let html = bodyHtml {
            return buildMultipart(html: html)
        } else {
            return buildPlainText()
        }
    }

    private func buildPlainText() -> String {
        var lines = headers.map(\.rendered)
        lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    private func buildMultipart(html: String) -> String {
        let boundary = "boundary_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        var lines = headers.map(\.rendered)
        lines.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")

        let headerSection = lines.joined(separator: "\r\n")

        let plainPart = """
        --\(boundary)\r
        Content-Type: text/plain; charset="UTF-8"\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        \(body)
        """

        let htmlPart = """
        --\(boundary)\r
        Content-Type: text/html; charset="UTF-8"\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        \(html)\r
        --\(boundary)--
        """

        return headerSection + "\r\n\r\n" + plainPart + "\r\n" + htmlPart
    }

    /// Encode the message for Gmail API (URL-safe Base64)
    func encoded() -> String {
        guard let data = build().data(using: .utf8) else {
            return ""
        }
        return Base64URL.encode(data)
    }
}

// MARK: - Gmail API Protocol (for testability)

/// Protocol for Gmail API operations - enables mocking for unit tests
/// Note: SwiftData @Model types are not Sendable, so we use @preconcurrency
/// to suppress warnings until full migration to DTOs
@preconcurrency
protocol GmailAPIProvider {
    func fetchInbox(query: String?, maxResults: Int, pageToken: String?, labelIds: [String]) async throws -> (emails: [Email], nextPageToken: String?)
    func fetchThread(threadId: String) async throws -> [EmailDetail]
    func sendEmail(to: [String], cc: [String], bcc: [String], subject: String, body: String, bodyHtml: String?, inReplyTo: String?, references: String?, threadId: String?) async throws -> String
    func archive(messageId: String) async throws
    func markAsRead(messageId: String) async throws
    func markAsUnread(messageId: String) async throws
    func star(messageId: String) async throws
    func unstar(messageId: String) async throws
    func trash(messageId: String) async throws
    func search(query: String, maxResults: Int) async throws -> [Email]
}

// MARK: - Gmail Service Logger

private let logger = Logger(subsystem: "com.simplemail.app", category: "GmailService")

// MARK: - Gmail Service

actor GmailService: GmailAPIProvider {
    static let shared = GmailService()

    private let baseURL = "https://gmail.googleapis.com/gmail/v1"
    private let batchSize = 3
    private let requestTimeout: TimeInterval = 20

    // MARK: - Get Access Token

    private func getAccessToken() async throws -> String {
        guard let account = await AuthService.shared.currentAccount else {
            throw GmailError.notAuthenticated
        }

        let refreshedAccount = try await AuthService.shared.refreshTokenIfNeeded(for: account)
        return refreshedAccount.accessToken
    }

    // MARK: - Fetch Inbox

    func fetchInbox(
        query: String? = nil,
        maxResults: Int = 50,
        pageToken: String? = nil,
        labelIds: [String] = ["INBOX"]
    ) async throws -> (emails: [Email], nextPageToken: String?) {
        logger.info("Fetching inbox: labels=\(labelIds), max=\(maxResults), page=\(pageToken ?? "first")")

        let token = try await getAccessToken()

        var components = URLComponents(string: "\(baseURL)/users/me/messages")!
        var queryItems = [
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]

        for labelId in labelIds {
            queryItems.append(URLQueryItem(name: "labelIds", value: labelId))
        }

        if let query = query {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }

        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        components.queryItems = queryItems

        let listResponse: MessageListResponse = try await request(
            url: components.url!,
            token: token
        )

        guard let messageRefs = listResponse.messages, !messageRefs.isEmpty else {
            logger.info("No emails found")
            return ([], nil)
        }

        // Fetch details in batches
        let emails = try await fetchEmailDetails(
            messageIds: messageRefs.map(\.id),
            token: token
        )

        logger.info("Fetched \(emails.count) emails, hasMore=\(listResponse.nextPageToken != nil)")
        return (emails, listResponse.nextPageToken)
    }

    // MARK: - Fetch Email Details (Batched)

    private func fetchEmailDetails(messageIds: [String], token: String) async throws -> [Email] {
        var emails: [Email] = []

        for batchStart in stride(from: 0, to: messageIds.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, messageIds.count)
            let batch = Array(messageIds[batchStart..<batchEnd])

            let batchResults = try await withThrowingTaskGroup(of: Email?.self) { group in
                for messageId in batch {
                    group.addTask {
                        try await self.fetchSingleEmail(messageId: messageId, token: token)
                    }
                }

                var results: [Email] = []
                for try await email in group {
                    if let email = email {
                        results.append(email)
                    }
                }
                return results
            }

            emails.append(contentsOf: batchResults)
        }

        return emails.sorted { $0.date > $1.date }
    }

    private func fetchSingleEmail(messageId: String, token: String) async throws -> Email? {
        let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=List-Unsubscribe&metadataHeaders=List-Id&metadataHeaders=Precedence&metadataHeaders=Auto-Submitted&metadataHeaders=Message-ID&metadataHeaders=References&metadataHeaders=In-Reply-To")!

        let message: MessageResponse = try await request(url: url, token: token)
        return parseEmail(from: message)
    }

    // MARK: - Fetch Full Email (with body)

    func fetchEmailDetail(messageId: String) async throws -> EmailDetail {
        let token = try await getAccessToken()
        let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)?format=full")!

        let message: MessageResponse = try await request(url: url, token: token)
        return parseEmailDetail(from: message)
    }

    // MARK: - Fetch Thread

    func fetchThread(threadId: String) async throws -> [EmailDetail] {
        let token = try await getAccessToken()
        let url = URL(string: "\(baseURL)/users/me/threads/\(threadId)?format=full")!

        let thread: ThreadResponse = try await request(url: url, token: token)

        return thread.messages?.compactMap { parseEmailDetail(from: $0) } ?? []
    }

    // MARK: - Search

    func search(query: String, maxResults: Int = 50) async throws -> [Email] {
        let (emails, _) = try await fetchInbox(
            query: query,
            maxResults: maxResults,
            labelIds: [] // Search across all labels
        )
        return emails
    }

    // MARK: - Labels

    func fetchLabels() async throws -> [GmailLabel] {
        let token = try await getAccessToken()
        let url = URL(string: "\(baseURL)/users/me/labels")!

        let response: LabelsResponse = try await request(url: url, token: token)
        return response.labels ?? []
    }

    // MARK: - Email Actions

    func archive(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, removeLabels: ["INBOX"])
    }

    func unarchive(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["INBOX"])
    }

    func markAsRead(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, removeLabels: ["UNREAD"])
    }

    func markAsUnread(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["UNREAD"])
    }

    func star(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["STARRED"])
    }

    func unstar(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, removeLabels: ["STARRED"])
    }

    func trash(messageId: String) async throws {
        let token = try await getAccessToken()
        let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/trash")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GmailError.actionFailed
        }
    }

    func untrash(messageId: String) async throws {
        let token = try await getAccessToken()
        let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/untrash")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GmailError.actionFailed
        }
    }

    func permanentlyDelete(messageId: String) async throws {
        let token = try await getAccessToken()
        let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)")!

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 204 else {
            throw GmailError.actionFailed
        }
    }

    func reportSpam(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["SPAM"], removeLabels: ["INBOX"])
    }

    func unmarkSpam(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["INBOX"], removeLabels: ["SPAM"])
    }

    func markImportant(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["IMPORTANT"])
    }

    func unmarkImportant(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, removeLabels: ["IMPORTANT"])
    }

    private func modifyLabels(
        messageId: String,
        addLabels: [String] = [],
        removeLabels: [String] = []
    ) async throws {
        let token = try await getAccessToken()
        let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/modify")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        let body: [String: Any] = [
            "addLabelIds": addLabels,
            "removeLabelIds": removeLabels
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GmailError.actionFailed
        }
    }

    // MARK: - Send Email

    func sendEmail(
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        body: String,
        bodyHtml: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil,
        threadId: String? = nil
    ) async throws -> String {
        logger.info("Sending email to \(to.count) recipients")

        let token = try await getAccessToken()
        let url = URL(string: "\(baseURL)/users/me/messages/send")!

        // Use the type-safe MIME builder
        let mimeMessage = MIMEMessage(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            bodyHtml: bodyHtml,
            inReplyTo: inReplyTo,
            references: references
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        var payload: [String: Any] = ["raw": mimeMessage.encoded()]
        if let threadId = threadId {
            payload["threadId"] = threadId
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            logger.error("Failed to send email: status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw GmailError.sendFailed
        }

        let sendResponse = try JSONDecoder().decode(MessageRef.self, from: data)
        logger.info("Email sent successfully: \(sendResponse.id)")
        return sendResponse.id
    }

    // MARK: - Drafts

    func saveDraft(
        to: [String],
        subject: String,
        body: String,
        bodyHtml: String? = nil,
        existingDraftId: String? = nil
    ) async throws -> String {
        logger.info("Saving draft\(existingDraftId != nil ? " (updating)" : "")")

        let token = try await getAccessToken()

        // Use the type-safe MIME builder
        let mimeMessage = MIMEMessage(
            to: to,
            subject: subject,
            body: body,
            bodyHtml: bodyHtml
        )

        let url: URL
        let method: String

        if let draftId = existingDraftId {
            url = URL(string: "\(baseURL)/users/me/drafts/\(draftId)")!
            method = "PUT"
        } else {
            url = URL(string: "\(baseURL)/users/me/drafts")!
            method = "POST"
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        let payload: [String: Any] = [
            "message": ["raw": mimeMessage.encoded()]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            logger.error("Failed to save draft: status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw GmailError.actionFailed
        }

        let draftResponse = try JSONDecoder().decode(DraftResponse.self, from: data)
        logger.info("Draft saved: \(draftResponse.id)")
        return draftResponse.id
    }

    func fetchDrafts() async throws -> [Draft] {
        let token = try await getAccessToken()
        let url = URL(string: "\(baseURL)/users/me/drafts")!

        let response: DraftsListResponse = try await request(url: url, token: token)
        return response.drafts ?? []
    }

    func deleteDraft(draftId: String) async throws {
        let token = try await getAccessToken()
        let url = URL(string: "\(baseURL)/users/me/drafts/\(draftId)")!

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 204 else {
            throw GmailError.actionFailed
        }
    }

    // MARK: - Attachments

    func fetchAttachment(messageId: String, attachmentId: String) async throws -> Data {
        logger.info("Fetching attachment \(attachmentId) from message \(messageId)")

        let token = try await getAccessToken()
        let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/attachments/\(attachmentId)")!

        let response: AttachmentResponse = try await request(url: url, token: token)

        guard let data = Base64URL.decodeToData(response.data) else {
            logger.error("Failed to decode attachment data")
            throw GmailError.invalidResponse
        }

        logger.info("Fetched attachment: \(data.count) bytes")
        return data
    }

    // MARK: - History

    func getHistory(startHistoryId: String) async throws -> HistoryResponse {
        let token = try await getAccessToken()
        var components = URLComponents(string: "\(baseURL)/users/me/history")!
        components.queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId),
            URLQueryItem(name: "historyTypes", value: "messageAdded"),
            URLQueryItem(name: "historyTypes", value: "messageDeleted"),
            URLQueryItem(name: "historyTypes", value: "labelAdded"),
            URLQueryItem(name: "historyTypes", value: "labelRemoved")
        ]

        return try await request(url: components.url!, token: token)
    }

    // MARK: - Request Helper

    private func request<T: Decodable>(url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from \(url.path)")
            throw GmailError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                logger.error("JSON decode error for \(T.self): \(error.localizedDescription)")
                throw GmailError.invalidResponse
            }
        case 401:
            logger.warning("Authentication required for \(url.path)")
            throw GmailError.notAuthenticated
        case 429:
            logger.warning("Rate limited on \(url.path)")
            throw GmailError.rateLimited
        case 404:
            logger.warning("Resource not found: \(url.path)")
            throw GmailError.notFound
        default:
            logger.error("Server error \(httpResponse.statusCode) on \(url.path)")
            throw GmailError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: - Parsing (nonisolated - no actor state access)

    private nonisolated func parseEmail(from message: MessageResponse) -> Email {
        var from = ""
        var subject = ""
        var date = Date()
        var listUnsubscribe: String?
        var listId: String?
        var precedence: String?
        var autoSubmitted: String?

        for header in message.payload?.headers ?? [] {
            switch header.name.lowercased() {
            case "from": from = header.value
            case "subject": subject = header.value
            case "date": date = parseDate(header.value) ?? Date()
            case "list-unsubscribe": listUnsubscribe = header.value
            case "list-id": listId = header.value
            case "precedence": precedence = header.value
            case "auto-submitted": autoSubmitted = header.value
            default: break
            }
        }

        let email = Email(
            id: message.id,
            threadId: message.threadId,
            snippet: message.snippet ?? "",
            subject: subject,
            from: from,
            date: date,
            isUnread: message.labelIds?.contains("UNREAD") ?? false,
            isStarred: message.labelIds?.contains("STARRED") ?? false,
            hasAttachments: hasAttachments(message.payload),
            labelIds: message.labelIds ?? []
        )

        email.listUnsubscribe = listUnsubscribe
        email.listId = listId
        email.precedence = precedence
        email.autoSubmitted = autoSubmitted

        return email
    }

    private nonisolated func parseEmailDetail(from message: MessageResponse) -> EmailDetail {
        var from = ""
        var to: [String] = []
        var cc: [String] = []
        var subject = ""
        var date = Date()

        for header in message.payload?.headers ?? [] {
            switch header.name.lowercased() {
            case "from": from = header.value
            case "to": to = parseAddressList(header.value)
            case "cc": cc = parseAddressList(header.value)
            case "subject": subject = header.value
            case "date": date = parseDate(header.value) ?? Date()
            default: break
            }
        }

        let body = extractBody(from: message.payload)

        return EmailDetail(
            id: message.id,
            threadId: message.threadId,
            snippet: message.snippet ?? "",
            subject: subject,
            from: from,
            date: date,
            isUnread: message.labelIds?.contains("UNREAD") ?? false,
            isStarred: message.labelIds?.contains("STARRED") ?? false,
            hasAttachments: hasAttachments(message.payload),
            labelIds: message.labelIds ?? [],
            body: body,
            to: to,
            cc: cc
        )
    }

    private nonisolated func parseAddressList(_ value: String) -> [String] {
        value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    // Cached date formatters for parsing (thread-safe static allocation)
    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss z",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter
        }
    }()

    private nonisolated func parseDate(_ dateString: String) -> Date? {
        for formatter in Self.dateFormatters {
            if let date = formatter.date(from: dateString) {
                return date
            }
        }
        return nil
    }

    private nonisolated func hasAttachments(_ payload: Payload?) -> Bool {
        guard let parts = payload?.parts else { return false }
        return parts.contains { part in
            if let filename = part.filename, !filename.isEmpty {
                return true
            }
            if let subparts = part.parts {
                return subparts.contains { $0.filename != nil && !$0.filename!.isEmpty }
            }
            return false
        }
    }

    private nonisolated func extractBody(from payload: Payload?) -> String {
        guard let payload = payload else { return "" }

        // Try to find HTML or plain text body
        if let data = payload.body?.data {
            return decodeBase64URL(data)
        }

        // Check parts
        if let parts = payload.parts {
            // Prefer HTML
            if let htmlPart = findPart(parts, mimeType: "text/html"),
               let data = htmlPart.body?.data {
                return decodeBase64URL(data)
            }

            // Fall back to plain text
            if let textPart = findPart(parts, mimeType: "text/plain"),
               let data = textPart.body?.data {
                return decodeBase64URL(data)
            }

            // Check nested parts
            for part in parts {
                if let nestedParts = part.parts {
                    if let htmlPart = findPart(nestedParts, mimeType: "text/html"),
                       let data = htmlPart.body?.data {
                        return decodeBase64URL(data)
                    }
                    if let textPart = findPart(nestedParts, mimeType: "text/plain"),
                       let data = textPart.body?.data {
                        return decodeBase64URL(data)
                    }
                }
            }
        }

        return ""
    }

    private nonisolated func findPart(_ parts: [Part], mimeType: String) -> Part? {
        parts.first { $0.mimeType?.lowercased() == mimeType.lowercased() }
    }

    private nonisolated func decodeBase64URL(_ encoded: String) -> String {
        Base64URL.decode(encoded) ?? ""
    }
}

// MARK: - Gmail Errors

enum GmailError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case rateLimited
    case notFound
    case serverError(Int)
    case actionFailed
    case sendFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Please sign in to continue"
        case .invalidResponse: return "Invalid response from server"
        case .rateLimited: return "Too many requests. Please wait a moment."
        case .notFound: return "Email not found"
        case .serverError(let code): return "Server error (\(code))"
        case .actionFailed: return "Action failed. Please try again."
        case .sendFailed: return "Failed to send email"
        }
    }
}

// MARK: - API Response Types

struct MessageListResponse: Codable {
    let messages: [MessageRef]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

struct MessageRef: Codable {
    let id: String
    let threadId: String
}

struct MessageResponse: Codable {
    let id: String
    let threadId: String
    let snippet: String?
    let labelIds: [String]?
    let payload: Payload?
    let historyId: String?
}

struct ThreadResponse: Codable {
    let id: String
    let messages: [MessageResponse]?
    let historyId: String?
}

struct Payload: Codable {
    let headers: [Header]?
    let parts: [Part]?
    let body: PartBody?
    let mimeType: String?
}

struct Header: Codable {
    let name: String
    let value: String
}

struct Part: Codable {
    let partId: String?
    let filename: String?
    let mimeType: String?
    let body: PartBody?
    let parts: [Part]?
}

struct PartBody: Codable {
    let attachmentId: String?
    let size: Int?
    let data: String?
}

struct LabelsResponse: Codable {
    let labels: [GmailLabel]?
}

struct GmailLabel: Codable, Identifiable {
    let id: String
    let name: String
    let type: String?
    let messagesTotal: Int?
    let messagesUnread: Int?
    let color: LabelColor?
}

struct LabelColor: Codable {
    let textColor: String?
    let backgroundColor: String?
}

struct DraftResponse: Codable {
    let id: String
    let message: MessageRef?
}

struct DraftsListResponse: Codable {
    let drafts: [Draft]?
}

struct Draft: Codable, Identifiable {
    let id: String
    let message: MessageRef?
}

struct AttachmentResponse: Codable {
    let size: Int
    let data: String
}

struct HistoryResponse: Codable {
    let history: [HistoryRecord]?
    let historyId: String?
    let nextPageToken: String?
}

struct HistoryRecord: Codable {
    let id: String
    let messagesAdded: [MessageAdded]?
    let messagesDeleted: [MessageDeleted]?
    let labelsAdded: [LabelModification]?
    let labelsRemoved: [LabelModification]?
}

struct MessageAdded: Codable {
    let message: MessageRef
}

struct MessageDeleted: Codable {
    let message: MessageRef
}

struct LabelModification: Codable {
    let message: MessageRef
    let labelIds: [String]
}
