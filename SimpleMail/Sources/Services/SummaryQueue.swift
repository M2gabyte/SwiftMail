import Foundation
import UIKit

actor SummaryQueue {
    static let shared = SummaryQueue()

    private struct Job {
        let email: Email
    }

    private var queue: [Job] = []
    private var queuedIds: Set<String> = []
    private var isProcessing = false
    private let maxPerHour = 10
    private let timestampsKey = "summaryQueueTimestamps"

    private init() {}

    func enqueueCandidates(_ emails: [Email]) async {
        guard !emails.isEmpty else { return }

        for email in prioritized(emails) {
            if queuedIds.contains(email.id) {
                continue
            }
            if SummaryCache.shared.summary(for: email.id, accountEmail: email.accountEmail) != nil {
                continue
            }
            queuedIds.insert(email.id)
            queue.append(Job(email: email))
        }

        await processIfNeeded()
    }

    private func processIfNeeded() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        while !queue.isEmpty {
            if !(await canRunNow()) {
                return
            }

            let job = queue.removeFirst()
            queuedIds.remove(job.email.id)

            guard shouldPrecompute(for: job.email.accountEmail) else {
                continue
            }

            guard let detail = await fetchDetail(for: job.email) else {
                continue
            }

            let summary = await SummaryService.summarizeIfNeeded(
                messageId: detail.id,
                body: detail.body,
                accountEmail: detail.accountEmail
            )

            if summary != nil {
                recordRun()
            }
        }
    }

    private func prioritized(_ emails: [Email]) -> [Email] {
        emails.sorted { lhs, rhs in
            let lhsScore = priorityScore(lhs)
            let rhsScore = priorityScore(rhs)
            if lhsScore == rhsScore {
                return lhs.date > rhs.date
            }
            return lhsScore > rhsScore
        }
    }

    private func priorityScore(_ email: Email) -> Int {
        var score = 0
        if email.isUnread { score += 2 }
        if email.isStarred { score += 1 }
        if email.listUnsubscribe == nil { score += 1 }
        return score
    }

    private func shouldPrecompute(for accountEmail: String?) -> Bool {
        guard let data = AccountDefaults.data(for: "appSettings", accountEmail: accountEmail),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return true
        }
        return settings.precomputeSummaries
    }

    private func canRunNow() async -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return false
        }
        let batteryLevel: Float = await MainActor.run(resultType: Float.self, body: {
            UIDevice.current.isBatteryMonitoringEnabled = true
            return UIDevice.current.batteryLevel
        })
        if batteryLevel >= 0 && batteryLevel < 0.2 {
            return false
        }
        return remainingAllowance() > 0
    }

    private func remainingAllowance() -> Int {
        let now = Date().timeIntervalSince1970
        let windowStart = now - 3600
        let timestamps = loadTimestamps().filter { $0 >= windowStart }
        saveTimestamps(timestamps)
        return max(0, maxPerHour - timestamps.count)
    }

    private func recordRun() {
        var timestamps = loadTimestamps()
        timestamps.append(Date().timeIntervalSince1970)
        saveTimestamps(timestamps)
    }

    private func loadTimestamps() -> [TimeInterval] {
        UserDefaults.standard.array(forKey: timestampsKey) as? [TimeInterval] ?? []
    }

    private func saveTimestamps(_ timestamps: [TimeInterval]) {
        UserDefaults.standard.set(timestamps, forKey: timestampsKey)
    }

    private func fetchDetail(for email: Email) async -> EmailDetailDTO? {
        if let accountEmail = email.accountEmail,
           let account = await MainActor.run(resultType: AuthService.Account?.self, body: {
               AuthService.shared.accounts.first(where: { $0.email.lowercased() == accountEmail.lowercased() })
           }) {
            if let thread = try? await GmailService.shared.fetchThread(threadId: email.threadId, account: account),
               let latest = thread.sorted(by: { $0.date > $1.date }).first {
                return latest
            }
        }

        return try? await GmailService.shared.fetchEmailDetail(messageId: email.id)
    }
}
