import SwiftUI

/// Manages pending email sends with undo capability across views
@MainActor
@Observable
final class PendingSendManager {
    static let shared = PendingSendManager()

    private(set) var isPending = false
    private(set) var remainingSeconds = 0
    private var sendTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var pendingEmail: PendingEmail?

    struct PendingEmail {
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let body: String
        let bodyHtml: String?
        let attachments: [MIMEAttachment]
        let inReplyTo: String?
        let threadId: String?
        let draftId: String?
        let delaySeconds: Int
    }

    private init() {}

    /// Queue an email to be sent after a delay, allowing undo
    func queueSend(_ email: PendingEmail) {
        // Cancel any existing pending send
        sendTask?.cancel()
        timerTask?.cancel()

        pendingEmail = email
        isPending = true
        remainingSeconds = email.delaySeconds

        // Start countdown timer
        timerTask = Task { [weak self] in
            for _ in 0..<email.delaySeconds {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.remainingSeconds -= 1
            }
        }

        // Start send task
        sendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(email.delaySeconds))
            guard let self, !Task.isCancelled else { return }
            await self.executeSend()
        }
    }

    /// Undo the pending send
    func undoSend() {
        sendTask?.cancel()
        timerTask?.cancel()
        sendTask = nil
        timerTask = nil
        pendingEmail = nil
        isPending = false
        remainingSeconds = 0
    }

    private func executeSend() async {
        guard let email = pendingEmail else { return }

        do {
            _ = try await GmailService.shared.sendEmail(
                to: email.to,
                cc: email.cc,
                bcc: email.bcc,
                subject: email.subject,
                body: email.body,
                bodyHtml: email.bodyHtml,
                attachments: email.attachments,
                inReplyTo: email.inReplyTo,
                threadId: email.threadId
            )

            // Delete draft if exists
            if let draftId = email.draftId {
                try? await GmailService.shared.deleteDraft(draftId: draftId)
            }

            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        } catch {
            // Could add error handling here if needed
        }

        pendingEmail = nil
        isPending = false
        remainingSeconds = 0
    }
}
