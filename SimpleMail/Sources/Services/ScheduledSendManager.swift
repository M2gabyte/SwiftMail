import Foundation
import OSLog

private let scheduledLogger = Logger(subsystem: "com.simplemail.app", category: "ScheduledSend")

struct ScheduledAttachment: Codable, Identifiable {
    let id: UUID
    let filename: String
    let mimeType: String
    let dataBase64: String?
    let filePath: String?

    init(filename: String, mimeType: String, data: Data) {
        self.id = UUID()
        self.filename = filename
        self.mimeType = mimeType
        self.dataBase64 = data.base64EncodedString()
        self.filePath = nil
    }

    init(id: UUID, filename: String, mimeType: String, filePath: String?) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.dataBase64 = nil
        self.filePath = filePath
    }

    func decodedData() -> Data? {
        if let filePath, let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
            return data
        }
        if let dataBase64 {
            return Data(base64Encoded: dataBase64)
        }
        return nil
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
        let normalized = normalizeAttachments(for: send)
        current.append(normalized)
        saveAll(current)
        scheduledLogger.info("Scheduled send for \(send.sendAt.formatted())")
    }

    func remove(id: UUID) {
        var current = loadAll()
        if let send = current.first(where: { $0.id == id }) {
            deleteAttachments(for: send)
        }
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
            let sends = try JSONDecoder().decode([ScheduledSend].self, from: data)
            let migrated = sends.map { normalizeAttachments(for: $0) }
            saveAll(migrated)
            return migrated
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

    private func normalizeAttachments(for send: ScheduledSend) -> ScheduledSend {
        let normalized = send.attachments.map { attachment -> ScheduledAttachment in
            if let filePath = attachment.filePath {
                return attachment
            }
            guard let data = attachment.decodedData(),
                  let filePath = storeAttachmentData(data, filename: attachment.filename, attachmentId: attachment.id) else {
                return attachment
            }
            return ScheduledAttachment(id: attachment.id, filename: attachment.filename, mimeType: attachment.mimeType, filePath: filePath)
        }

        return ScheduledSend(
            id: send.id,
            accountEmail: send.accountEmail,
            to: send.to,
            cc: send.cc,
            bcc: send.bcc,
            subject: send.subject,
            body: send.body,
            bodyHtml: send.bodyHtml,
            attachments: normalized,
            sendAt: send.sendAt
        )
    }

    private func deleteAttachments(for send: ScheduledSend) {
        for attachment in send.attachments {
            guard let filePath = attachment.filePath else { continue }
            try? FileManager.default.removeItem(atPath: filePath)
        }
    }

    private func attachmentsDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("ScheduledAttachments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func storeAttachmentData(_ data: Data, filename: String, attachmentId: UUID) -> String? {
        guard let dir = attachmentsDirectory() else { return nil }
        let safeName = filename.replacingOccurrences(of: "/", with: "_")
        let fileURL = dir.appendingPathComponent("\(attachmentId.uuidString)-\(safeName)")
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            scheduledLogger.error("Failed to store scheduled attachment: \(error.localizedDescription)")
            return nil
        }
    }
}
