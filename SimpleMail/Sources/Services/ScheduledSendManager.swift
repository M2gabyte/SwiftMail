import Foundation
import OSLog

private let scheduledLogger = Logger(subsystem: "com.simplemail.app", category: "ScheduledSend")

struct ScheduledAttachment: Codable, Identifiable {
    let id: UUID
    let filename: String
    let mimeType: String
    let dataBase64: String

    init(filename: String, mimeType: String, data: Data) {
        self.id = UUID()
        self.filename = filename
        self.mimeType = mimeType
        self.dataBase64 = data.base64EncodedString()
    }

    func decodedData() -> Data? {
        Data(base64Encoded: dataBase64)
    }
}

struct ScheduledSend: Codable, Identifiable {
    let id: UUID
    let accountEmail: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let body: String
    let bodyHtml: String?
    let attachments: [ScheduledAttachment]
    let sendAt: Date
}

final class ScheduledSendManager {
    static let shared = ScheduledSendManager()

    private let storageKey = "scheduledSends"
    private init() {}

    func schedule(_ send: ScheduledSend) {
        var current = loadAll()
        current.append(send)
        saveAll(current)
        scheduledLogger.info("Scheduled send for \(send.sendAt.formatted())")
    }

    func remove(id: UUID) {
        var current = loadAll()
        current.removeAll { $0.id == id }
        saveAll(current)
    }

    func reschedule(id: UUID, date: Date) {
        var current = loadAll()
        if let index = current.firstIndex(where: { $0.id == id }) {
            let updated = ScheduledSend(
                id: current[index].id,
                accountEmail: current[index].accountEmail,
                to: current[index].to,
                cc: current[index].cc,
                bcc: current[index].bcc,
                subject: current[index].subject,
                body: current[index].body,
                bodyHtml: current[index].bodyHtml,
                attachments: current[index].attachments,
                sendAt: date
            )
            current[index] = updated
            saveAll(current)
        }
    }

    func loadAll() -> [ScheduledSend] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([ScheduledSend].self, from: data)
        } catch {
            scheduledLogger.error("Failed to decode scheduled sends: \(error.localizedDescription)")
            return []
        }
    }

    private func saveAll(_ sends: [ScheduledSend]) {
        do {
            let data = try JSONEncoder().encode(sends)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            scheduledLogger.error("Failed to encode scheduled sends: \(error.localizedDescription)")
        }
    }

    func processDueSends() async {
        let now = Date()
        let pending = loadAll()
        let due = pending.filter { $0.sendAt <= now }
        guard !due.isEmpty else { return }

        for item in due {
            let account = await MainActor.run {
                AuthService.shared.accounts.first { $0.email.lowercased() == item.accountEmail.lowercased() }
            }
            guard let account else {
                scheduledLogger.error("Account not found for scheduled send")
                continue
            }

            let attachments: [MIMEAttachment] = item.attachments.compactMap { attachment in
                guard let data = attachment.decodedData() else { return nil }
                return MIMEAttachment(filename: attachment.filename, mimeType: attachment.mimeType, data: data)
            }

            do {
                _ = try await GmailService.shared.sendEmail(
                    to: item.to,
                    cc: item.cc,
                    bcc: item.bcc,
                    subject: item.subject,
                    body: item.body,
                    bodyHtml: item.bodyHtml,
                    attachments: attachments,
                    account: account
                )
                remove(id: item.id)
                scheduledLogger.info("Sent scheduled email \(item.id.uuidString)")
            } catch {
                scheduledLogger.error("Failed scheduled send: \(error.localizedDescription)")
            }
        }
    }
}
