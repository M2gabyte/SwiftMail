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

struct MIMEAttachment: Sendable {
    let filename: String
    let mimeType: String
    let data: Data
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
    let attachments: [MIMEAttachment]

    init(
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        body: String,
        bodyHtml: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil,
        attachments: [MIMEAttachment] = []
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.bodyHtml = bodyHtml
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
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
        if attachments.isEmpty {
            if let html = bodyHtml {
                return buildMultipart(html: html)
            } else {
                return buildPlainText()
            }
        }
        return buildMixed()
    }

    private func buildPlainText() -> String {
        var lines = headers.map(\.rendered)
        lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
        lines.append("Content-Transfer-Encoding: base64")
        let encodedBody = Data(body.utf8).base64EncodedString()
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + encodedBody
    }

    private func buildMultipart(html: String) -> String {
        let boundary = "boundary_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        var lines = headers.map(\.rendered)
        lines.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")

        let headerSection = lines.joined(separator: "\r\n")

        let plainEncoded = Data(body.utf8).base64EncodedString()
        let htmlEncoded = Data(html.utf8).base64EncodedString()

        let plainPart = """
        --\(boundary)\r
        Content-Type: text/plain; charset="UTF-8"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(plainEncoded)\r
        """

        let htmlPart = """
        --\(boundary)\r
        Content-Type: text/html; charset="UTF-8"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(htmlEncoded)\r
        --\(boundary)--
        """

        return headerSection + "\r\n\r\n" + plainPart.replacingOccurrences(of: "\r", with: "\r\n") +
        "\r\n" + htmlPart.replacingOccurrences(of: "\r", with: "\r\n")
    }

    private func buildMixed() -> String {
        let mixedBoundary = "mixed_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var lines = headers.map(\.rendered)
        lines.append("Content-Type: multipart/mixed; boundary=\"\(mixedBoundary)\"")

        let headerSection = lines.joined(separator: "\r\n")

        let bodyPart: String
        if let html = bodyHtml {
            let altBoundary = "alt_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            let plainEncoded = Data(body.utf8).base64EncodedString()
            let htmlEncoded = Data(html.utf8).base64EncodedString()
            bodyPart = """
            --\(mixedBoundary)\r
            Content-Type: multipart/alternative; boundary="\(altBoundary)"\r
            \r
            --\(altBoundary)\r
            Content-Type: text/plain; charset="UTF-8"\r
            Content-Transfer-Encoding: base64\r
            \r
            \(plainEncoded)\r
            --\(altBoundary)\r
            Content-Type: text/html; charset="UTF-8"\r
            Content-Transfer-Encoding: base64\r
            \r
            \(htmlEncoded)\r
            --\(altBoundary)--\r
            """
        } else {
            let plainEncoded = Data(body.utf8).base64EncodedString()
            bodyPart = """
            --\(mixedBoundary)\r
            Content-Type: text/plain; charset="UTF-8"\r
            Content-Transfer-Encoding: base64\r
            \r
            \(plainEncoded)\r
            """
        }

        var attachmentParts: [String] = []
        for attachment in attachments {
            let encoded = attachment.data.base64EncodedString()
            let part = """
            --\(mixedBoundary)\r
            Content-Type: \(attachment.mimeType); name="\(attachment.filename)"\r
            Content-Disposition: attachment; filename="\(attachment.filename)"\r
            Content-Transfer-Encoding: base64\r
            \r
            \(encoded)\r
            """
            attachmentParts.append(part)
        }

        let closing = "--\(mixedBoundary)--"
        return headerSection + "\r\n\r\n" +
        bodyPart.replacingOccurrences(of: "\r", with: "\r\n") +
        "\r\n" +
        attachmentParts.joined(separator: "\r\n").replacingOccurrences(of: "\r", with: "\r\n") +
        "\r\n" + closing
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
protocol GmailAPIProvider {
    func fetchInbox(query: String?, maxResults: Int, pageToken: String?, labelIds: [String]) async throws -> (emails: [EmailDTO], nextPageToken: String?)
    func fetchThread(threadId: String) async throws -> [EmailDetailDTO]
    func sendEmail(to: [String], cc: [String], bcc: [String], subject: String, body: String, bodyHtml: String?, attachments: [MIMEAttachment], inReplyTo: String?, references: String?, threadId: String?) async throws -> String
    func archive(messageId: String) async throws
    func markAsRead(messageId: String) async throws
    func markAsUnread(messageId: String) async throws
    func star(messageId: String) async throws
    func unstar(messageId: String) async throws
    func trash(messageId: String) async throws
    func search(query: String, maxResults: Int) async throws -> [EmailDTO]
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

    private func getAccessToken(for account: AuthService.Account) async throws -> String {
        let refreshedAccount = try await AuthService.shared.refreshTokenIfNeeded(for: account)
        return refreshedAccount.accessToken
    }

    // MARK: - Fetch Inbox

    func fetchInbox(
        query: String? = nil,
        maxResults: Int = 50,
        pageToken: String? = nil,
        labelIds: [String] = ["INBOX"]
    ) async throws -> (emails: [EmailDTO], nextPageToken: String?) {
        logger.info("Fetching inbox: labels=\(labelIds), max=\(maxResults), page=\(pageToken ?? "first")")

        // Get current account for scoping
        guard let account = await AuthService.shared.currentAccount else {
            throw GmailError.notAuthenticated
        }
        let accountEmail = account.email.lowercased()
        let refreshedAccount = try await AuthService.shared.refreshTokenIfNeeded(for: account)
        let token = refreshedAccount.accessToken

        guard var components = URLComponents(string: "\(baseURL)/users/me/messages") else {
            throw GmailError.invalidURL
        }
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

        guard let url = components.url else {
            throw GmailError.invalidURL
        }

        let listResponse: MessageListResponse = try await request(
            url: url,
            token: token
        )

        guard let messageRefs = listResponse.messages, !messageRefs.isEmpty else {
            logger.info("No emails found")
            return ([], nil)
        }

        // Fetch details in batches
        let emails = try await fetchEmailDetails(
            messageIds: messageRefs.map(\.id),
            token: token,
            accountEmail: accountEmail
        )

        logger.info("Fetched \(emails.count) emails, hasMore=\(listResponse.nextPageToken != nil)")
        return (emails, listResponse.nextPageToken)
    }

    func fetchInbox(
        for account: AuthService.Account,
        query: String? = nil,
        maxResults: Int = 50,
        pageToken: String? = nil,
        labelIds: [String] = ["INBOX"]
    ) async throws -> (emails: [EmailDTO], nextPageToken: String?) {
        logger.info("Fetching inbox: labels=\(labelIds), max=\(maxResults), page=\(pageToken ?? "first")")

        let accountEmail = account.email.lowercased()
        let token = try await getAccessToken(for: account)

        guard var components = URLComponents(string: "\(baseURL)/users/me/messages") else {
            throw GmailError.invalidURL
        }
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

        guard let url = components.url else {
            throw GmailError.invalidURL
        }

        let listResponse: MessageListResponse = try await request(
            url: url,
            token: token
        )

        guard let messageRefs = listResponse.messages, !messageRefs.isEmpty else {
            logger.info("No emails found")
            return ([], nil)
        }

        let emails = try await fetchEmailDetails(
            messageIds: messageRefs.map(\.id),
            token: token,
            accountEmail: accountEmail
        )

        logger.info("Fetched \(emails.count) emails, hasMore=\(listResponse.nextPageToken != nil)")
        return (emails, listResponse.nextPageToken)
    }

    // MARK: - Fetch Email Details (Batched)
    // Handles per-message errors gracefully - one failing message won't cancel the batch

    private func fetchEmailDetails(messageIds: [String], token: String, accountEmail: String) async throws -> [EmailDTO] {
        var emails: [EmailDTO] = []

        for batchStart in stride(from: 0, to: messageIds.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, messageIds.count)
            let batch = Array(messageIds[batchStart..<batchEnd])

            // Use TaskGroup with Result to handle per-message errors gracefully
            let batchResults = await withTaskGroup(of: Result<EmailDTO, Error>.self) { group in
                for messageId in batch {
                    group.addTask {
                        do {
                            if let email = try await self.fetchSingleEmail(messageId: messageId, token: token, accountEmail: accountEmail) {
                                return .success(email)
                            } else {
                                return .failure(GmailError.notFound)
                            }
                        } catch {
                            return .failure(error)
                        }
                    }
                }

                var results: [EmailDTO] = []
                for await result in group {
                    switch result {
                    case .success(let email):
                        results.append(email)
                    case .failure(let error):
                        // Log but don't fail the entire batch
                        logger.warning("Failed to fetch single email: \(error.localizedDescription)")
                    }
                }
                return results
            }

            emails.append(contentsOf: batchResults)
        }

        return emails.sorted { $0.date > $1.date }
    }

    private func fetchSingleEmail(messageId: String, token: String, accountEmail: String) async throws -> EmailDTO? {
        guard let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=List-Unsubscribe&metadataHeaders=List-Id&metadataHeaders=Precedence&metadataHeaders=Auto-Submitted&metadataHeaders=Message-ID&metadataHeaders=References&metadataHeaders=In-Reply-To") else {
            throw GmailError.invalidURL
        }

        let message: MessageResponse = try await request(url: url, token: token)
        return parseEmail(from: message, accountEmail: accountEmail)
    }

    // MARK: - Fetch Full Email (with body)

    func fetchEmailDetail(messageId: String) async throws -> EmailDetailDTO {
        let token = try await getAccessToken()
        guard let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)?format=full") else {
            throw GmailError.invalidURL
        }

        let message: MessageResponse = try await request(url: url, token: token)
        let accountEmail = await MainActor.run { AuthService.shared.currentAccount?.email.lowercased() }
        var emailDetail = parseEmailDetail(from: message, accountEmail: accountEmail)

        // Fetch body attachment if needed
        emailDetail = try await fetchBodyAttachmentIfNeeded(for: emailDetail, from: message, token: token)

        return emailDetail
    }

    // MARK: - Fetch Thread

    func fetchThread(threadId: String) async throws -> [EmailDetailDTO] {
        let token = try await getAccessToken()
        guard let url = URL(string: "\(baseURL)/users/me/threads/\(threadId)?format=full") else {
            throw GmailError.invalidURL
        }

        let thread: ThreadResponse = try await request(url: url, token: token)

        guard let messages = thread.messages else { return [] }

        // Parse all messages and fetch body attachments in parallel
        let accountEmail = await MainActor.run { AuthService.shared.currentAccount?.email.lowercased() }
        return try await fetchThreadMessages(messages: messages, token: token, accountEmail: accountEmail)
    }

    func fetchThread(threadId: String, account: AuthService.Account) async throws -> [EmailDetailDTO] {
        let token = try await getAccessToken(for: account)
        guard let url = URL(string: "\(baseURL)/users/me/threads/\(threadId)?format=full") else {
            throw GmailError.invalidURL
        }

        let thread: ThreadResponse = try await request(url: url, token: token)

        guard let messages = thread.messages else { return [] }

        let accountEmail = account.email.lowercased()
        return try await fetchThreadMessages(messages: messages, token: token, accountEmail: accountEmail)
    }

    /// Fetch and parse thread messages in parallel
    private func fetchThreadMessages(
        messages: [MessageResponse],
        token: String,
        accountEmail: String?
    ) async throws -> [EmailDetailDTO] {
        // Use TaskGroup to fetch body attachments in parallel
        let indexedMessages = messages.enumerated().map { ($0.offset, $0.element) }

        return try await withThrowingTaskGroup(of: (Int, EmailDetailDTO).self) { group in
            for (index, message) in indexedMessages {
                group.addTask {
                    var emailDetail = self.parseEmailDetail(from: message, accountEmail: accountEmail)
                    emailDetail = try await self.fetchBodyAttachmentIfNeeded(for: emailDetail, from: message, token: token)
                    return (index, emailDetail)
                }
            }

            var results: [(Int, EmailDetailDTO)] = []
            for try await result in group {
                results.append(result)
            }

            // Sort by original order to preserve thread chronology
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    // MARK: - Fetch Body Attachment If Needed

    /// Fetches body content if it's stored as an attachment rather than inline
    private func fetchBodyAttachmentIfNeeded(
        for emailDetail: EmailDetailDTO,
        from message: MessageResponse,
        token: String
    ) async throws -> EmailDetailDTO {
        // If body is already populated with non-whitespace content, no need to fetch
        let trimmedBody = emailDetail.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            return emailDetail
        }

        logger.info("Body is empty for message \(message.id), checking for body attachment")

        // Look for body attachment ID in the message parts
        guard let payload = message.payload,
              let bodyAttachmentInfo = findBodyAttachment(in: payload) else {
            logger.warning("No body attachment found for message \(message.id)")
            return emailDetail
        }

        logger.info("Found body attachment \(bodyAttachmentInfo.attachmentId) with mimeType \(bodyAttachmentInfo.mimeType)")

        // Fetch the attachment content
        let bodyData = try await fetchAttachment(
            messageId: message.id,
            attachmentId: bodyAttachmentInfo.attachmentId
        )

        // Decode the body content
        let body: String
        if let text = String(data: bodyData, encoding: .utf8) {
            body = text
        } else {
            body = ""
        }

        // Create updated EmailDetail with the fetched body
        return EmailDetailDTO(
            id: emailDetail.id,
            threadId: emailDetail.threadId,
            snippet: emailDetail.snippet,
            subject: emailDetail.subject,
            from: emailDetail.from,
            date: emailDetail.date,
            isUnread: emailDetail.isUnread,
            isStarred: emailDetail.isStarred,
            hasAttachments: emailDetail.hasAttachments,
            labelIds: emailDetail.labelIds,
            body: body,
            to: emailDetail.to,
            cc: emailDetail.cc,
            listUnsubscribe: emailDetail.listUnsubscribe,
            accountEmail: emailDetail.accountEmail
        )
    }

    /// Body attachment info returned from recursive search
    private struct BodyAttachmentInfo {
        let attachmentId: String
        let mimeType: String
    }

    /// Recursively finds a body part that has an attachmentId (for large email bodies)
    private nonisolated func findBodyAttachment(in payload: Payload) -> BodyAttachmentInfo? {
        // Check top-level body
        if let mimeType = payload.mimeType?.lowercased(),
           (mimeType == "text/html" || mimeType == "text/plain"),
           let attachmentId = payload.body?.attachmentId {
            return BodyAttachmentInfo(attachmentId: attachmentId, mimeType: mimeType)
        }

        // Check parts recursively (prefer HTML)
        if let parts = payload.parts {
            // First pass: look for HTML attachment
            if let htmlInfo = findBodyAttachmentRecursively(in: parts, preferredMimeType: "text/html") {
                return htmlInfo
            }

            // Second pass: fall back to plain text
            if let plainInfo = findBodyAttachmentRecursively(in: parts, preferredMimeType: "text/plain") {
                return plainInfo
            }
        }

        return nil
    }

    /// Recursively searches parts for a body attachment with the specified MIME type
    private nonisolated func findBodyAttachmentRecursively(in parts: [Part], preferredMimeType: String) -> BodyAttachmentInfo? {
        for part in parts {
            if let mimeType = part.mimeType?.lowercased(), mimeType == preferredMimeType {
                if let attachmentId = part.body?.attachmentId {
                    return BodyAttachmentInfo(attachmentId: attachmentId, mimeType: mimeType)
                }
            }

            // Recursively check nested parts
            if let nestedParts = part.parts {
                if let found = findBodyAttachmentRecursively(in: nestedParts, preferredMimeType: preferredMimeType) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: - Search

    func search(query: String, maxResults: Int = 50) async throws -> [EmailDTO] {
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
        guard let url = URL(string: "\(baseURL)/users/me/labels") else {
            throw GmailError.invalidURL
        }

        let response: LabelsResponse = try await request(url: url, token: token)
        return response.labels ?? []
    }

    // MARK: - Email Actions

    func archive(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, removeLabels: ["INBOX"])
    }

    func archive(messageId: String, account: AuthService.Account) async throws {
        try await modifyLabels(messageId: messageId, removeLabels: ["INBOX"], account: account)
    }

    func unarchive(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["INBOX"])
    }

    func unarchive(messageId: String, account: AuthService.Account) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["INBOX"], account: account)
    }

    func markAsRead(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, removeLabels: ["UNREAD"])
    }

    func markAsRead(messageId: String, account: AuthService.Account) async throws {
        try await modifyLabels(messageId: messageId, removeLabels: ["UNREAD"], account: account)
    }

    func markAsUnread(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["UNREAD"])
    }

    func markAsUnread(messageId: String, account: AuthService.Account) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["UNREAD"], account: account)
    }

    func star(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["STARRED"])
    }

    func star(messageId: String, account: AuthService.Account) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["STARRED"], account: account)
    }

    func unstar(messageId: String) async throws {
        try await modifyLabels(messageId: messageId, removeLabels: ["STARRED"])
    }

    func unstar(messageId: String, account: AuthService.Account) async throws {
        try await modifyLabels(messageId: messageId, removeLabels: ["STARRED"], account: account)
    }

    func trash(messageId: String) async throws {
        let token = try await getAccessToken()
        guard let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/trash") else {
            throw GmailError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GmailError.actionFailed
        }
    }

    func trash(messageId: String, account: AuthService.Account) async throws {
        let token = try await getAccessToken(for: account)
        guard let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/trash") else {
            throw GmailError.invalidURL
        }

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
        guard let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/untrash") else {
            throw GmailError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GmailError.actionFailed
        }
    }

    func untrash(messageId: String, account: AuthService.Account) async throws {
        let token = try await getAccessToken(for: account)
        guard let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/untrash") else {
            throw GmailError.invalidURL
        }

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
        guard let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)") else {
            throw GmailError.invalidURL
        }

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

    func reportSpam(messageId: String, account: AuthService.Account) async throws {
        try await modifyLabels(messageId: messageId, addLabels: ["SPAM"], removeLabels: ["INBOX"], account: account)
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
        guard let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/modify") else {
            throw GmailError.invalidURL
        }

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

    private func modifyLabels(
        messageId: String,
        addLabels: [String] = [],
        removeLabels: [String] = [],
        account: AuthService.Account
    ) async throws {
        let token = try await getAccessToken(for: account)
        guard let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/modify") else {
            throw GmailError.invalidURL
        }

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

    // MARK: - Batch Operations (reduces API calls for threads)

    /// Batch modify labels for multiple messages at once
    /// Much more efficient than calling modifyLabels per message
    func batchModifyLabels(
        messageIds: [String],
        addLabels: [String] = [],
        removeLabels: [String] = []
    ) async throws {
        guard !messageIds.isEmpty else { return }

        let token = try await getAccessToken()
        guard let url = URL(string: "\(baseURL)/users/me/messages/batchModify") else {
            throw GmailError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        let body: [String: Any] = [
            "ids": messageIds,
            "addLabelIds": addLabels,
            "removeLabelIds": removeLabels
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 204 else {
            throw GmailError.actionFailed
        }
    }

    func batchModifyLabels(
        messageIds: [String],
        addLabels: [String] = [],
        removeLabels: [String] = [],
        account: AuthService.Account
    ) async throws {
        guard !messageIds.isEmpty else { return }

        let token = try await getAccessToken(for: account)
        guard let url = URL(string: "\(baseURL)/users/me/messages/batchModify") else {
            throw GmailError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        let body: [String: Any] = [
            "ids": messageIds,
            "addLabelIds": addLabels,
            "removeLabelIds": removeLabels
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 204 else {
            throw GmailError.actionFailed
        }
    }

    /// Batch archive (remove INBOX label) for multiple messages
    func batchArchive(messageIds: [String]) async throws {
        try await batchModifyLabels(messageIds: messageIds, removeLabels: ["INBOX"])
    }

    func batchArchive(messageIds: [String], account: AuthService.Account) async throws {
        try await batchModifyLabels(messageIds: messageIds, removeLabels: ["INBOX"], account: account)
    }

    /// Batch mark as read for multiple messages
    func batchMarkAsRead(messageIds: [String]) async throws {
        try await batchModifyLabels(messageIds: messageIds, removeLabels: ["UNREAD"])
    }

    func batchMarkAsRead(messageIds: [String], account: AuthService.Account) async throws {
        try await batchModifyLabels(messageIds: messageIds, removeLabels: ["UNREAD"], account: account)
    }

    /// Batch mark as unread for multiple messages
    func batchMarkAsUnread(messageIds: [String]) async throws {
        try await batchModifyLabels(messageIds: messageIds, addLabels: ["UNREAD"])
    }

    func batchMarkAsUnread(messageIds: [String], account: AuthService.Account) async throws {
        try await batchModifyLabels(messageIds: messageIds, addLabels: ["UNREAD"], account: account)
    }

    /// Batch trash for multiple messages
    func batchTrash(messageIds: [String]) async throws {
        try await batchModifyLabels(messageIds: messageIds, addLabels: ["TRASH"], removeLabels: ["INBOX"])
    }

    func batchTrash(messageIds: [String], account: AuthService.Account) async throws {
        try await batchModifyLabels(messageIds: messageIds, addLabels: ["TRASH"], removeLabels: ["INBOX"], account: account)
    }

    // MARK: - Send Email

    func sendEmail(
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        body: String,
        bodyHtml: String? = nil,
        attachments: [MIMEAttachment] = [],
        inReplyTo: String? = nil,
        references: String? = nil,
        threadId: String? = nil
    ) async throws -> String {
        logger.info("Sending email to \(to.count) recipients")

        let token = try await getAccessToken()
        guard let url = URL(string: "\(baseURL)/users/me/messages/send") else {
            throw GmailError.invalidURL
        }

        // Use the type-safe MIME builder
        let mimeMessage = MIMEMessage(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            bodyHtml: bodyHtml,
            inReplyTo: inReplyTo,
            references: references,
            attachments: attachments
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

        let sendResponse = try JSONCoding.decoder.decode(MessageRef.self, from: data)
        logger.info("Email sent successfully: \(sendResponse.id)")
        return sendResponse.id
    }

    func sendEmail(
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        body: String,
        bodyHtml: String? = nil,
        attachments: [MIMEAttachment] = [],
        inReplyTo: String? = nil,
        references: String? = nil,
        threadId: String? = nil,
        account: AuthService.Account
    ) async throws -> String {
        logger.info("Sending email to \(to.count) recipients")

        let token = try await getAccessToken(for: account)
        guard let url = URL(string: "\(baseURL)/users/me/messages/send") else {
            throw GmailError.invalidURL
        }

        let mimeMessage = MIMEMessage(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            bodyHtml: bodyHtml,
            inReplyTo: inReplyTo,
            references: references,
            attachments: attachments
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

        let sendResponse = try JSONCoding.decoder.decode(MessageRef.self, from: data)
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
            guard let draftUrl = URL(string: "\(baseURL)/users/me/drafts/\(draftId)") else {
                throw GmailError.invalidURL
            }
            url = draftUrl
            method = "PUT"
        } else {
            guard let draftsUrl = URL(string: "\(baseURL)/users/me/drafts") else {
                throw GmailError.invalidURL
            }
            url = draftsUrl
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

        let draftResponse = try JSONCoding.decoder.decode(DraftResponse.self, from: data)
        logger.info("Draft saved: \(draftResponse.id)")
        return draftResponse.id
    }

    func fetchDrafts() async throws -> [Draft] {
        let token = try await getAccessToken()
        guard let url = URL(string: "\(baseURL)/users/me/drafts") else {
            throw GmailError.invalidURL
        }

        let response: DraftsListResponse = try await request(url: url, token: token)
        return response.drafts ?? []
    }

    func deleteDraft(draftId: String) async throws {
        let token = try await getAccessToken()
        guard let url = URL(string: "\(baseURL)/users/me/drafts/\(draftId)") else {
            throw GmailError.invalidURL
        }

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
        guard let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/attachments/\(attachmentId)") else {
            throw GmailError.invalidURL
        }

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
        guard var components = URLComponents(string: "\(baseURL)/users/me/history") else {
            throw GmailError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId),
            URLQueryItem(name: "historyTypes", value: "messageAdded"),
            URLQueryItem(name: "historyTypes", value: "messageDeleted"),
            URLQueryItem(name: "historyTypes", value: "labelAdded"),
            URLQueryItem(name: "historyTypes", value: "labelRemoved")
        ]

        guard let url = components.url else {
            throw GmailError.invalidURL
        }

        return try await request(url: url, token: token)
    }

    // MARK: - Request Helper

    private func request<T: Decodable>(url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        // Use retry logic for transient network failures
        let frozenRequest = request
        let (data, response) = try await NetworkRetry.withRetry(maxAttempts: 3) {
            try await URLSession.shared.data(for: frozenRequest)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from \(url.path)")
            throw GmailError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            do {
                return try JSONCoding.decoder.decode(T.self, from: data)
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

    private nonisolated func parseEmail(from message: MessageResponse, accountEmail: String) -> EmailDTO {
        var from = ""
        var subject = ""
        var listUnsubscribe: String?
        var listId: String?
        var precedence: String?
        var autoSubmitted: String?

        // Prefer internalDate (milliseconds since epoch) over header date
        var date: Date
        if let internalDate = message.internalDate,
           let timestamp = Double(internalDate) {
            date = Date(timeIntervalSince1970: timestamp / 1000.0)
        } else {
            date = Date()
        }

        for header in message.payload?.headers ?? [] {
            switch header.name.lowercased() {
            case "from": from = header.value
            case "subject": subject = header.value
            case "date":
                // Only use header date if internalDate wasn't available
                if message.internalDate == nil {
                    date = parseDate(header.value) ?? date
                }
            case "list-unsubscribe": listUnsubscribe = header.value
            case "list-id": listId = header.value
            case "precedence": precedence = header.value
            case "auto-submitted": autoSubmitted = header.value
            default: break
            }
        }

        let email = EmailDTO(
            id: message.id,
            threadId: message.threadId,
            snippet: cleanPreviewText(message.snippet ?? ""),
            subject: subject,
            from: from,
            date: date,
            isUnread: message.labelIds?.contains("UNREAD") ?? false,
            isStarred: message.labelIds?.contains("STARRED") ?? false,
            hasAttachments: hasAttachments(message.payload),
            labelIds: message.labelIds ?? [],
            messagesCount: 1,
            accountEmail: accountEmail,
            listUnsubscribe: listUnsubscribe,
            listId: listId,
            precedence: precedence,
            autoSubmitted: autoSubmitted
        )

        return email
    }

    private nonisolated func parseEmailDetail(from message: MessageResponse, accountEmail: String?) -> EmailDetailDTO {
        var from = ""
        var to: [String] = []
        var cc: [String] = []
        var subject = ""
        var listUnsubscribe: String?

        // Prefer internalDate (milliseconds since epoch) over header date
        var date: Date
        if let internalDate = message.internalDate,
           let timestamp = Double(internalDate) {
            date = Date(timeIntervalSince1970: timestamp / 1000.0)
        } else {
            date = Date()
        }

        for header in message.payload?.headers ?? [] {
            switch header.name.lowercased() {
            case "from": from = header.value
            case "to": to = parseAddressList(header.value)
            case "cc": cc = parseAddressList(header.value)
            case "subject": subject = header.value
            case "list-unsubscribe": listUnsubscribe = header.value
            case "date":
                if message.internalDate == nil {
                    date = parseDate(header.value) ?? date
                }
            default: break
            }
        }

        let body = extractBody(from: message.payload)

        return EmailDetailDTO(
            id: message.id,
            threadId: message.threadId,
            snippet: cleanPreviewText(message.snippet ?? ""),
            subject: subject,
            from: from,
            date: date,
            isUnread: message.labelIds?.contains("UNREAD") ?? false,
            isStarred: message.labelIds?.contains("STARRED") ?? false,
            hasAttachments: hasAttachments(message.payload),
            labelIds: message.labelIds ?? [],
            body: body,
            to: to,
            cc: cc,
            listUnsubscribe: listUnsubscribe,
            accountEmail: accountEmail
        )
    }

    /// Parse RFC 2822 address list, handling quoted display names with commas
    /// e.g., "Doe, John" <john@example.com>, jane@example.com
    private nonisolated func parseAddressList(_ value: String) -> [String] {
        var addresses: [String] = []
        var current = ""
        var inQuotes = false
        var inAngleBrackets = false

        for char in value {
            switch char {
            case "\"":
                inQuotes.toggle()
                current.append(char)
            case "<":
                inAngleBrackets = true
                current.append(char)
            case ">":
                inAngleBrackets = false
                current.append(char)
            case ",":
                if inQuotes || inAngleBrackets {
                    // Comma inside quotes or angle brackets, keep it
                    current.append(char)
                } else {
                    // Address separator
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        addresses.append(trimmed)
                    }
                    current = ""
                }
            default:
                current.append(char)
            }
        }

        // Don't forget the last address
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            addresses.append(trimmed)
        }

        return addresses
    }

    private nonisolated func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        // Common HTML entities
        let entities: [(String, String)] = [
            ("&#39;", "'"),
            ("&#x27;", "'"),
            ("&apos;", "'"),
            ("&quot;", "\""),
            ("&#34;", "\""),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " "),
            ("&#160;", " "),
            ("&hellip;", "…"),
            ("&#8230;", "…"),
            ("&mdash;", "—"),
            ("&#8212;", "—"),
            ("&ndash;", "–"),
            ("&#8211;", "–")
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    private nonisolated func cleanPreviewText(_ text: String) -> String {
        var cleaned = decodeHTMLEntities(text)
        let lower = cleaned.lowercased()

        // If the snippet looks like raw MIME or HTML, strip headers/tags aggressively.
        if lower.contains("content-type:") ||
            lower.contains("content-transfer-encoding:") ||
            lower.contains("mime-version:") ||
            lower.contains("<!doctype") ||
            lower.contains("<html") {
            cleaned = stripMIMEHeaders(from: cleaned)
            cleaned = stripHTMLTags(from: cleaned)
        } else if cleaned.contains("<") && cleaned.contains(">") {
            cleaned = stripHTMLTags(from: cleaned)
        }

        // Basic whitespace normalization
        cleaned = cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Premium parsing: strip forwarded headers, signatures, and extract meaningful content
        cleaned = EmailPreviewParser.extractMeaningfulPreview(from: cleaned)

        return cleaned
    }

    private nonisolated func stripMIMEHeaders(from text: String) -> String {
        var result = text

        if let headerRange = result.range(of: "\r\n\r\n") ?? result.range(of: "\n\n") {
            let headerBlock = result[..<headerRange.lowerBound]
            if headerBlock.range(of: "content-type:", options: .caseInsensitive) != nil {
                result = String(result[headerRange.upperBound...])
            }
        }

        // Remove any remaining header-like lines.
        let headerPattern = "(?im)^(from|to|cc|bcc|subject|date|content-type|content-transfer-encoding|mime-version|received|return-path|message-id|dkim|spf|authentication-results|list-unsubscribe|list-id|precedence|auto-submitted|x-[^:]+):.*$"
        result = result.replacingOccurrences(of: headerPattern, with: "", options: .regularExpression)

        return result
    }

    private nonisolated func stripHTMLTags(from text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    /// Check if HTML content is visually empty (contains only tags, whitespace, &nbsp;, <br>, etc.)
    /// This handles cases like Gmail sending `<div dir="ltr"><br></div>` for empty emails
    private nonisolated func isVisuallyEmptyHTML(_ html: String) -> Bool {
        var text = html

        // Remove all HTML tags
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)

        // Decode common HTML entities that represent whitespace/empty content
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&#160;", with: " ")
        text = text.replacingOccurrences(of: "&#xA0;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")

        // Remove zero-width characters
        text = text.replacingOccurrences(of: "\u{200B}", with: "") // zero-width space
        text = text.replacingOccurrences(of: "\u{200C}", with: "") // zero-width non-joiner
        text = text.replacingOccurrences(of: "\u{200D}", with: "") // zero-width joiner
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "") // byte order mark
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ") // non-breaking space

        // Trim all whitespace (including newlines, tabs, etc.)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Collapse any remaining internal whitespace
        text = text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)

        return text.isEmpty
    }

    private nonisolated func cleanBodyContent(_ body: String, mimeType: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let lower = trimmed.lowercased()
        let looksLikeHeaders = lower.contains("content-type:") ||
            lower.contains("content-transfer-encoding:") ||
            lower.contains("mime-version:")

        if looksLikeHeaders {
            // Check if content is base64 encoded before stripping headers
            let isBase64Encoded = lower.contains("content-transfer-encoding:") &&
                lower.contains("base64")

            let withoutHeaders = stripMIMEHeaders(from: trimmed)
            var collapsed = withoutHeaders
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if collapsed.isEmpty {
                return ""
            }

            // If the original content indicated base64 encoding, decode the remaining content
            if isBase64Encoded {
                // Remove any whitespace that might have been in the base64 data
                let base64Data = collapsed.replacingOccurrences(of: " ", with: "")
                if let decoded = Base64URL.decode(base64Data), !decoded.isEmpty {
                    collapsed = decoded
                } else if let data = Data(base64Encoded: base64Data),
                          let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty {
                    // Try standard base64 decoding as fallback
                    collapsed = decoded
                }
            }

            // Recursively clean the decoded content (it might be HTML that needs further processing)
            let cleanedMimeType = lower.contains("text/html") ? "text/html" : mimeType
            if collapsed != trimmed {
                return cleanBodyContent(collapsed, mimeType: cleanedMimeType)
            }
            return collapsed
        }

        if mimeType == "text/plain" && lower.contains("<html") {
            return stripHTMLTags(from: trimmed)
        }

        // For HTML content, check if it's visually empty (only tags, whitespace, &nbsp;, etc.)
        // This handles cases like Gmail sending `<div dir="ltr"><br></div>` for empty emails
        if mimeType == "text/html" && isVisuallyEmptyHTML(trimmed) {
            return ""
        }

        return trimmed
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
                return subparts.contains { $0.filename?.isEmpty == false }
            }
            return false
        }
    }

    private nonisolated func extractBody(from payload: Payload?) -> String {
        guard let payload = payload else { return "" }

        // For simple messages with direct body
        if let mimeType = payload.mimeType?.lowercased(),
           (mimeType == "text/html" || mimeType == "text/plain"),
           let data = payload.body?.data, !data.isEmpty {
            let decoded = decodeBase64URL(data)
            let cleaned = cleanBodyContent(decoded, mimeType: mimeType)
            if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return cleaned
            }
        }

        // Recursively search all parts for HTML first, then plain text
        if let parts = payload.parts {
            // First pass: look for HTML anywhere in the tree
            if let html = findBodyRecursively(in: parts, preferredMimeType: "text/html") {
                let cleaned = cleanBodyContent(html, mimeType: "text/html")
                if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return cleaned
                }
            }

            // Second pass: fall back to plain text
            if let plain = findBodyRecursively(in: parts, preferredMimeType: "text/plain") {
                let cleaned = cleanBodyContent(plain, mimeType: "text/plain")
                if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return cleaned
                }
            }
        }

        return ""
    }

    /// Recursively searches through all parts to find body content with the specified MIME type
    private nonisolated func findBodyRecursively(in parts: [Part], preferredMimeType: String) -> String? {
        for part in parts {
            // Check if this part matches the preferred MIME type
            if let mimeType = part.mimeType?.lowercased(), mimeType == preferredMimeType {
                // Only return if data exists and is non-empty
                if let data = part.body?.data, !data.isEmpty {
                    let decoded = decodeBase64URL(data)
                    if !decoded.isEmpty {
                        return decoded
                    }
                }
            }

            // Recursively check nested parts
            if let nestedParts = part.parts {
                if let found = findBodyRecursively(in: nestedParts, preferredMimeType: preferredMimeType) {
                    return found
                }
            }
        }
        return nil
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
    case invalidURL
    case rateLimited
    case notFound
    case serverError(Int)
    case actionFailed
    case sendFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Please sign in to continue"
        case .invalidResponse: return "Invalid response from server"
        case .invalidURL: return "Invalid URL configuration"
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
    let internalDate: String?  // Unix timestamp in milliseconds
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
