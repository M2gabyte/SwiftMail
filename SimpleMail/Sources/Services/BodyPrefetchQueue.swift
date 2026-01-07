import Foundation
import UIKit
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.simplemail.app", category: "BodyPrefetchQueue")

/// Queue for prefetching email bodies in the background for offline access
actor BodyPrefetchQueue {
    static let shared = BodyPrefetchQueue()

    struct Candidate: Sendable {
        let emailId: String
        let threadId: String
        let accountEmail: String
        let date: Date
        let isUnread: Bool
        let isStarred: Bool
        let listUnsubscribe: String?
    }

    private struct Job: Sendable {
        let emailId: String
        let threadId: String
        let accountEmail: String
        let date: Date
        let isUnread: Bool
        let isStarred: Bool
        let listUnsubscribe: String?
    }

    private var queue: [Job] = []
    private var queuedIds: Set<String> = []
    private var isProcessing = false

    /// Maximum emails to prefetch per session
    private let maxPrefetchPerSession = 50

    /// Concurrent fetch limit
    private let concurrentFetchLimit = 3

    private init() {}

    /// Enqueue emails for body prefetching
    /// Prioritizes unread and starred emails
    func enqueueCandidates(_ candidates: [Candidate]) async {
        guard !candidates.isEmpty else { return }

        // Filter out already queued and prioritize
        let prioritized = prioritize(candidates)

        for email in prioritized.prefix(maxPrefetchPerSession) {
            if queuedIds.contains(email.emailId) {
                continue
            }

            // Check if body is already cached
            let isCached = await MainActor.run {
                EmailCacheManager.shared.hasDetailCached(emailId: email.emailId)
            }

            if isCached {
                continue
            }

            queuedIds.insert(email.emailId)
            queue.append(Job(
                emailId: email.emailId,
                threadId: email.threadId,
                accountEmail: email.accountEmail,
                date: email.date,
                isUnread: email.isUnread,
                isStarred: email.isStarred,
                listUnsubscribe: email.listUnsubscribe
            ))
        }

        await processIfNeeded()
    }

    /// Process the prefetch queue
    private func processIfNeeded() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        while !queue.isEmpty {
            // Check conditions before processing
            if !(await canRunNow()) {
                logger.debug("Stopping prefetch - conditions not met")
                return
            }

            // Process in batches for efficiency
            let batch = Array(queue.prefix(concurrentFetchLimit))
            queue.removeFirst(min(concurrentFetchLimit, queue.count))

            await withTaskGroup(of: Void.self) { group in
                for job in batch {
                    group.addTask {
                        await self.fetchAndCacheBody(job)
                    }
                }
            }
        }
    }

    /// Fetch email body and cache it
    private func fetchAndCacheBody(_ job: Job) async {
        queuedIds.remove(job.emailId)

        do {
            // Find account
            guard let account = await MainActor.run(body: {
                AuthService.shared.accounts.first {
                    $0.email.lowercased() == job.accountEmail.lowercased()
                }
            }) else {
                return
            }

            // Fetch thread to get full body
            let messages = try await GmailService.shared.fetchThread(
                threadId: job.threadId,
                account: account
            )

            // Cache all messages in the thread
            await MainActor.run {
                for message in messages {
                    EmailCacheManager.shared.cacheEmailDetail(message)
                }
            }

            logger.debug("Prefetched body for email \(job.emailId)")
        } catch {
            logger.warning("Failed to prefetch body for \(job.emailId): \(error.localizedDescription)")
        }
    }

    /// Prioritize emails for prefetching
    private func prioritize(_ emails: [Candidate]) -> [Candidate] {
        // Extract priority data before sorting to avoid Sendable issues
        struct PriorityInfo {
            let index: Int
            let score: Int
            let date: Date
        }

        let infos = emails.enumerated().map { index, email in
            var score = 0
            if email.isUnread { score += 3 }
            if email.isStarred { score += 2 }
            if email.listUnsubscribe == nil { score += 1 }
            return PriorityInfo(index: index, score: score, date: email.date)
        }

        let sortedInfos = infos.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.date > rhs.date
            }
            return lhs.score > rhs.score
        }

        return sortedInfos.map { emails[$0.index] }
    }

    /// Check if conditions are right for prefetching
    private func canRunNow() async -> Bool {
        // Don't prefetch if offline
        let isConnected = await MainActor.run {
            NetworkMonitor.shared.isConnected
        }
        guard isConnected else { return false }

        // Don't prefetch in low power mode
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return false
        }

        // Don't prefetch if battery is low
        let batteryLevel: Float = await MainActor.run(resultType: Float.self) {
            UIDevice.current.isBatteryMonitoringEnabled = true
            return UIDevice.current.batteryLevel
        }

        if batteryLevel >= 0 && batteryLevel < 0.2 {
            return false
        }

        return true
    }
}
