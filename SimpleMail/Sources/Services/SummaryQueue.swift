import Foundation
import UIKit

actor SummaryQueue {
    static let shared = SummaryQueue()

    private struct Job: Sendable {
        let emailId: String
        let accountEmail: String
        let subject: String
        let from: String
        let snippet: String
        let body: String
        let receivedAt: Date
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
            let job = Job(
                emailId: email.id,
                accountEmail: email.accountEmail,
                subject: email.subject,
                from: email.from,
                snippet: email.snippet,
                body: email.body,
                receivedAt: email.receivedAt
            )
            queue.append(job)
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
            queuedIds.remove(job.emailId)

            guard shouldPrecompute(for: job.accountEmail) else {
                continue
            }

            // Use the job data directly instead of fetching
            let summary = await SummaryService.summarizeIfNeeded(
                messageId: job.emailId,
                body: job.body,
                accountEmail: job.accountEmail
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

}
