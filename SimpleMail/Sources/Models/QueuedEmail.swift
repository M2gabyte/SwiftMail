import Foundation
import SwiftData

// MARK: - Queue Status

enum QueueStatus: String, Codable {
    case pending
    case sending
    case failed
}

// MARK: - Queued Attachment

/// Attachment data stored for offline queued emails
struct QueuedAttachment: Codable, Sendable {
    let id: UUID
    let filename: String
    let mimeType: String
    /// File URL where attachment data is stored (relative to app documents)
    let fileURL: String

    init(filename: String, mimeType: String, fileURL: String) {
        self.id = UUID()
        self.filename = filename
        self.mimeType = mimeType
        self.fileURL = fileURL
    }
}

// MARK: - Queued Email Model

/// Email queued for sending when offline - persisted in SwiftData
@Model
final class QueuedEmail: Identifiable {
    @Attribute(.unique) var id: UUID
    var accountEmail: String
    var toRecipients: [String]
    var ccRecipients: [String]
    var bccRecipients: [String]
    var subject: String
    var body: String
    var bodyHtml: String?
    /// JSON-encoded array of QueuedAttachment
    var attachmentsData: Data?
    var inReplyTo: String?
    var references: String?
    var threadId: String?
    var createdAt: Date
    var statusRaw: String
    var lastError: String?
    var retryCount: Int

    var status: QueueStatus {
        get { QueueStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var attachments: [QueuedAttachment] {
        get {
            guard let data = attachmentsData else { return [] }
            return (try? JSONDecoder().decode([QueuedAttachment].self, from: data)) ?? []
        }
        set {
            attachmentsData = try? JSONEncoder().encode(newValue)
        }
    }

    init(
        id: UUID = UUID(),
        accountEmail: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        body: String,
        bodyHtml: String? = nil,
        attachments: [QueuedAttachment] = [],
        inReplyTo: String? = nil,
        references: String? = nil,
        threadId: String? = nil,
        createdAt: Date = Date(),
        status: QueueStatus = .pending,
        lastError: String? = nil,
        retryCount: Int = 0
    ) {
        self.id = id
        self.accountEmail = accountEmail
        self.toRecipients = to
        self.ccRecipients = cc
        self.bccRecipients = bcc
        self.subject = subject
        self.body = body
        self.bodyHtml = bodyHtml
        self.attachmentsData = try? JSONEncoder().encode(attachments)
        self.inReplyTo = inReplyTo
        self.references = references
        self.threadId = threadId
        self.createdAt = createdAt
        self.statusRaw = status.rawValue
        self.lastError = lastError
        self.retryCount = retryCount
    }
}

// MARK: - DTO for Cross-Actor Transfer

struct QueuedEmailDTO: Sendable, Identifiable {
    let id: UUID
    let accountEmail: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let body: String
    let bodyHtml: String?
    let attachments: [QueuedAttachment]
    let inReplyTo: String?
    let references: String?
    let threadId: String?
    let createdAt: Date
    let status: QueueStatus
    let lastError: String?
    let retryCount: Int
}

extension QueuedEmail {
    func toDTO() -> QueuedEmailDTO {
        QueuedEmailDTO(
            id: id,
            accountEmail: accountEmail,
            to: toRecipients,
            cc: ccRecipients,
            bcc: bccRecipients,
            subject: subject,
            body: body,
            bodyHtml: bodyHtml,
            attachments: attachments,
            inReplyTo: inReplyTo,
            references: references,
            threadId: threadId,
            createdAt: createdAt,
            status: status,
            lastError: lastError,
            retryCount: retryCount
        )
    }
}

// MARK: - Attachment Storage Helper

enum QueuedAttachmentStorage {
    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var outboxDirectory: URL {
        documentsDirectory.appendingPathComponent("outbox_attachments", isDirectory: true)
    }

    /// Save attachment data to disk and return the relative file path
    static func save(data: Data, filename: String) throws -> String {
        let outboxDir = outboxDirectory

        // Create directory if needed
        if !FileManager.default.fileExists(atPath: outboxDir.path) {
            try FileManager.default.createDirectory(at: outboxDir, withIntermediateDirectories: true)
        }

        // Create unique filename to avoid collisions
        let uniqueFilename = "\(UUID().uuidString)_\(filename)"
        let fileURL = outboxDir.appendingPathComponent(uniqueFilename)

        try data.write(to: fileURL)
        return uniqueFilename
    }

    /// Load attachment data from disk
    static func load(relativePath: String) throws -> Data {
        let fileURL = outboxDirectory.appendingPathComponent(relativePath)
        return try Data(contentsOf: fileURL)
    }

    /// Delete attachment file from disk
    static func delete(relativePath: String) {
        let fileURL = outboxDirectory.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Delete all attachments for a queued email
    static func deleteAttachments(_ attachments: [QueuedAttachment]) {
        for attachment in attachments {
            delete(relativePath: attachment.fileURL)
        }
    }

    /// Clean up orphaned attachment files (called periodically)
    static func cleanupOrphanedFiles(validPaths: Set<String>) {
        let outboxDir = outboxDirectory

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: outboxDir.path) else {
            return
        }

        for file in files {
            if !validPaths.contains(file) {
                let fileURL = outboxDir.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
}
