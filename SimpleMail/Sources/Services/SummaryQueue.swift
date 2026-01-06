import Foundation
import UIKit

actor SummaryQueue {
    static let shared = SummaryQueue()

    struct Stats: Codable, Sendable {
        var enqueued: Int = 0
        var processed: Int = 0
        var skippedCached: Int = 0
        var skippedNoAccount: Int = 0
        var skippedShort: Int = 0
        var skippedBattery: Int = 0
        var skippedThrottle: Int = 0
        var failed: Int = 0
        var lastRun: TimeInterval?
    }

    struct Candidate: Sendable {
        let emailId: String
        let threadId: String
        let accountEmail: String
        let subject: String
        let from: String
        let snippet: String
        let date: Date
        let isUnread: Bool
        let isStarred: Bool
        let listUnsubscribe: String?
    }

    private struct Job: Sendable {
        let emailId: String
        let threadId: String
        let accountEmail: String
        let subject: String
        let from: String
        let snippet: String
        let date: Date
        let isUnread: Bool
        let isStarred: Bool
        let listUnsubscribe: String?
    }

    private var queue: [Job] = []
    private var queuedIds: Set<String> = []
    private var isProcessing = false
    private let maxPerHour = 10
    private let timestampsKey = "summaryQueueTimestamps"
    private let statsKey = "summaryQueueStats"

    private init() {}

    func enqueueCandidates(_ candidates: [Candidate]) async {
        guard !candidates.isEmpty else { return }

        var stats = loadStats()
        for candidate in prioritized(candidates) {
            if queuedIds.contains(candidate.emailId) {
                continue
            }
            if SummaryCache.shared.summary(for: candidate.emailId, accountEmail: candidate.accountEmail) != nil {
                stats.skippedCached += 1
                continue
            }
            queuedIds.insert(candidate.emailId)
            let job = Job(
                emailId: candidate.emailId,
                threadId: candidate.threadId,
                accountEmail: candidate.accountEmail,
                subject: candidate.subject,
                from: candidate.from,
                snippet: candidate.snippet,
                date: candidate.date,
                isUnread: candidate.isUnread,
                isStarred: candidate.isStarred,
                listUnsubscribe: candidate.listUnsubscribe
            )
            queue.append(job)
            stats.enqueued += 1
        }
        await saveStats(stats)

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

            let body = await resolveBody(for: job)
            guard let body else {
                var stats = loadStats()
                stats.failed += 1
                await saveStats(stats)
                continue
            }

            // Use the job data directly instead of fetching
            // Note: Use full body when available; falls back to snippet if body is empty
            let plain = SummaryService.plainText(body)
            if plain.count < SummaryService.minLength {
                var stats = loadStats()
                stats.skippedShort += 1
                await saveStats(stats)
                continue
            }

            let summary = await SummaryService.summarizeIfNeeded(
                messageId: job.emailId,
                body: body,
                accountEmail: job.accountEmail
            )

            var stats = loadStats()
            if summary != nil {
                stats.processed += 1
                stats.lastRun = Date().timeIntervalSince1970
                await recordRun()
            } else {
                stats.failed += 1
            }
            await saveStats(stats)
        }
    }

    private func prioritized(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted { lhs, rhs in
            let lhsScore = priorityScore(lhs)
            let rhsScore = priorityScore(rhs)
            if lhsScore == rhsScore {
                return lhs.date > rhs.date
            }
            return lhsScore > rhsScore
        }
    }

    private func priorityScore(_ email: Candidate) -> Int {
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
            var stats = loadStats()
            stats.skippedBattery += 1
                await saveStats(stats)
            return false
        }
        let batteryLevel: Float = await MainActor.run(resultType: Float.self, body: {
            UIDevice.current.isBatteryMonitoringEnabled = true
            return UIDevice.current.batteryLevel
        })
        if batteryLevel >= 0 && batteryLevel < 0.2 {
            var stats = loadStats()
            stats.skippedBattery += 1
                await saveStats(stats)
            return false
        }
        if await remainingAllowance() <= 0 {
            var stats = loadStats()
            stats.skippedThrottle += 1
            await saveStats(stats)
            return false
        }
        return true
    }

    private func remainingAllowance() async -> Int {
        let now = Date().timeIntervalSince1970
        let windowStart = now - 3600
        let timestamps = loadTimestamps().filter { $0 >= windowStart }
        await saveTimestamps(timestamps)
        return max(0, maxPerHour - timestamps.count)
    }

    private func recordRun() async {
        var timestamps = loadTimestamps()
        timestamps.append(Date().timeIntervalSince1970)
        await saveTimestamps(timestamps)
    }

    private func loadTimestamps() -> [TimeInterval] {
        UserDefaults.standard.array(forKey: timestampsKey) as? [TimeInterval] ?? []
    }

    private func saveTimestamps(_ timestamps: [TimeInterval]) async {
        await MainActor.run {
            UserDefaults.standard.set(timestamps, forKey: timestampsKey)
        }
    }

    private func resolveBody(for job: Job) async -> String? {
        let cachedBody = await MainActor.run {
            EmailCacheManager.shared.loadCachedEmailDetail(id: job.emailId)?.body
        }
        if let cachedBody {
            return cachedBody
        }

        let account = await MainActor.run(resultType: AuthService.Account?.self, body: {
            AuthService.shared.accounts.first { $0.email.lowercased() == job.accountEmail.lowercased() }
        })

        guard let account else {
            var stats = loadStats()
            stats.skippedNoAccount += 1
            await saveStats(stats)
            return nil
        }

        if let thread = try? await GmailService.shared.fetchThread(threadId: job.threadId, account: account) {
            let detail = thread.first(where: { $0.id == job.emailId }) ??
                thread.sorted(by: { $0.date > $1.date }).first
            if let detail {
                await MainActor.run {
                    EmailCacheManager.shared.cacheEmailDetail(EmailDetail(dto: detail))
                }
                return detail.body
            }
        }

        return job.snippet.isEmpty ? nil : job.snippet
    }

    private func loadStats() -> Stats {
        guard let data = UserDefaults.standard.data(forKey: statsKey),
              let stats = try? JSONDecoder().decode(Stats.self, from: data) else {
            return Stats()
        }
        return stats
    }

    private func saveStats(_ stats: Stats) async {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        await MainActor.run {
            UserDefaults.standard.set(data, forKey: statsKey)
        }
    }

    nonisolated static func statsSnapshot() -> Stats {
        guard let data = UserDefaults.standard.data(forKey: "summaryQueueStats"),
              let stats = try? JSONDecoder().decode(Stats.self, from: data) else {
            return Stats()
        }
        return stats
    }

    nonisolated static func resetStats() {
        UserDefaults.standard.removeObject(forKey: "summaryQueueStats")
    }

}
