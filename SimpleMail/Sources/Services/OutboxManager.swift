import Foundation
import SwiftData
import OSLog
import UIKit

private let logger = Logger(subsystem: "com.simplemail.app", category: "OutboxManager")

/// Manages the offline email outbox queue
@MainActor
@Observable
final class OutboxManager {
    static let shared = OutboxManager()

    private(set) var pendingCount: Int = 0
    private(set) var failedCount: Int = 0
    private(set) var isSyncing: Bool = false

    private var modelContext: ModelContext?
    private var isProcessing = false

    /// Maximum retry attempts before marking as failed
    private let maxRetries = 3

    private init() {}

    /// Configure with ModelContext (call from app startup)
    func configure(with context: ModelContext) {
        self.modelContext = context
        Task {
            await refreshCounts()
        }
    }

    // MARK: - Queue Operations

    /// Queue an email for sending (works offline)
    func queue(
        accountEmail: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        body: String,
        bodyHtml: String? = nil,
        attachments: [MIMEAttachment] = [],
        inReplyTo: String? = nil,
        threadId: String? = nil,
        draftId: String? = nil
    ) async throws {
        guard let context = modelContext else {
            throw OutboxError.notConfigured
        }

        // Save attachments to disk on background thread (file I/O)
        let attachmentInputs = attachments.map { (data: $0.data, filename: $0.filename, mimeType: $0.mimeType) }
        let queuedAttachments: [QueuedAttachment] = try await Task.detached(priority: .utility) {
            var results: [QueuedAttachment] = []
            for input in attachmentInputs {
                let relativePath = try QueuedAttachmentStorage.save(
                    data: input.data,
                    filename: input.filename
                )
                results.append(QueuedAttachment(
                    filename: input.filename,
                    mimeType: input.mimeType,
                    fileURL: relativePath
                ))
            }
            return results
        }.value

        // SwiftData operations stay on main
        let queuedEmail = QueuedEmail(
            accountEmail: accountEmail,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            bodyHtml: bodyHtml,
            attachments: queuedAttachments,
            inReplyTo: inReplyTo,
            threadId: threadId
        )

        context.insert(queuedEmail)
        try context.save()

        logger.info("Queued email to \(to.count) recipients for offline sending")

        await refreshCounts()

        // Delete draft if exists
        if let draftId = draftId {
            Task {
                try? await GmailService.shared.deleteDraft(draftId: draftId)
            }
        }
    }

    /// Process all pending emails in the queue
    func processQueue() async {
        guard !isProcessing else {
            logger.debug("Queue processing already in progress")
            return
        }

        guard NetworkMonitor.shared.isConnected else {
            logger.debug("Skipping queue processing - offline")
            return
        }

        guard let context = modelContext else {
            logger.warning("OutboxManager not configured")
            return
        }

        isProcessing = true
        isSyncing = true
        defer {
            isProcessing = false
            isSyncing = false
        }

        logger.info("Processing outbox queue")

        // Fetch pending emails
        let descriptor = FetchDescriptor<QueuedEmail>(
            predicate: #Predicate { $0.statusRaw == "pending" },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )

        guard let pendingEmails = try? context.fetch(descriptor) else {
            logger.error("Failed to fetch pending emails")
            return
        }

        logger.info("Found \(pendingEmails.count) pending emails to send")

        for email in pendingEmails {
            // Check network before each send
            guard NetworkMonitor.shared.isConnected else {
                logger.info("Lost connectivity, stopping queue processing")
                break
            }

            await sendQueuedEmail(email, context: context)
        }

        await refreshCounts()
    }

    /// Retry a specific failed email
    func retry(id: UUID) async {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<QueuedEmail>(
            predicate: #Predicate { $0.id == id }
        )

        guard let emails = try? context.fetch(descriptor),
              let email = emails.first else {
            return
        }

        email.status = .pending
        email.retryCount = 0
        email.lastError = nil
        try? context.save()

        await refreshCounts()
        await processQueue()
    }

    /// Delete a queued email
    func delete(id: UUID) async {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<QueuedEmail>(
            predicate: #Predicate { $0.id == id }
        )

        guard let emails = try? context.fetch(descriptor),
              let email = emails.first else {
            return
        }

        // Fire-and-forget file deletion (don't block on disk I/O)
        let attachmentsToDelete = email.attachments
        Task.detached(priority: .utility) {
            QueuedAttachmentStorage.deleteAttachments(attachmentsToDelete)
        }

        // SwiftData cleanup stays on main
        context.delete(email)
        try? context.save()

        await refreshCounts()
        logger.info("Deleted queued email \(id)")
    }

    /// Get all queued emails for a specific account
    func fetchQueued(for accountEmail: String) -> [QueuedEmailDTO] {
        guard let context = modelContext else { return [] }

        let descriptor = FetchDescriptor<QueuedEmail>(
            predicate: #Predicate { $0.accountEmail == accountEmail },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        guard let emails = try? context.fetch(descriptor) else {
            return []
        }

        return emails.map { $0.toDTO() }
    }

    /// Get all queued emails (all accounts)
    func fetchAllQueued() -> [QueuedEmailDTO] {
        guard let context = modelContext else { return [] }

        let descriptor = FetchDescriptor<QueuedEmail>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        guard let emails = try? context.fetch(descriptor) else {
            return []
        }

        return emails.map { $0.toDTO() }
    }

    // MARK: - Private Helpers

    private func sendQueuedEmail(_ email: QueuedEmail, context: ModelContext) async {
        email.status = .sending
        try? context.save()

        do {
            // Find account for this email
            guard let account = AuthService.shared.accounts.first(where: {
                $0.email.lowercased() == email.accountEmail.lowercased()
            }) else {
                throw OutboxError.accountNotFound
            }

            // Extract attachment info from SwiftData object BEFORE crossing threads
            let attachmentInfo = email.attachments.map { (filename: $0.filename, mimeType: $0.mimeType, fileURL: $0.fileURL) }

            // Load attachments from disk on background thread (user tapped send = .userInitiated)
            let mimeAttachments: [MIMEAttachment] = try await Task.detached(priority: .userInitiated) {
                try attachmentInfo.map { info in
                    let data = try QueuedAttachmentStorage.load(relativePath: info.fileURL)
                    return MIMEAttachment(
                        filename: info.filename,
                        mimeType: info.mimeType,
                        data: data
                    )
                }
            }.value

            // Send the email (network is async, fine on main)
            _ = try await GmailService.shared.sendEmail(
                to: email.toRecipients,
                cc: email.ccRecipients,
                bcc: email.bccRecipients,
                subject: email.subject,
                body: email.body,
                bodyHtml: email.bodyHtml,
                attachments: mimeAttachments,
                inReplyTo: email.inReplyTo,
                threadId: email.threadId,
                account: account
            )

            // Success - fire-and-forget file deletion (don't block on disk I/O)
            let attachmentsToDelete = email.attachments
            Task.detached(priority: .utility) {
                QueuedAttachmentStorage.deleteAttachments(attachmentsToDelete)
            }

            // SwiftData cleanup stays on main
            context.delete(email)
            try? context.save()

            logger.info("Successfully sent queued email to \(email.toRecipients.count) recipients")

            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

        } catch {
            // Handle failure
            email.retryCount += 1
            email.lastError = error.localizedDescription

            if email.retryCount >= maxRetries {
                email.status = .failed
                logger.error("Email failed after \(self.maxRetries) retries: \(error.localizedDescription)")
            } else {
                email.status = .pending
                logger.warning("Email send failed, will retry (\(email.retryCount)/\(self.maxRetries)): \(error.localizedDescription)")
            }

            try? context.save()
        }
    }

    private func refreshCounts() async {
        guard let context = modelContext else { return }

        let pendingDescriptor = FetchDescriptor<QueuedEmail>(
            predicate: #Predicate { $0.statusRaw == "pending" || $0.statusRaw == "sending" }
        )

        let failedDescriptor = FetchDescriptor<QueuedEmail>(
            predicate: #Predicate { $0.statusRaw == "failed" }
        )

        pendingCount = (try? context.fetchCount(pendingDescriptor)) ?? 0
        failedCount = (try? context.fetchCount(failedDescriptor)) ?? 0
    }
}

// MARK: - Errors

enum OutboxError: LocalizedError {
    case notConfigured
    case accountNotFound
    case attachmentLoadFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Outbox manager not configured"
        case .accountNotFound:
            return "Account not found for queued email"
        case .attachmentLoadFailed:
            return "Failed to load attachment from disk"
        }
    }
}
