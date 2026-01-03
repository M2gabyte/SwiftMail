import Foundation
import UIKit
import OSLog

private let logger = Logger(subsystem: "com.simplemail.app", category: "BodyPrefetchQueue")

/// Queue for prefetching email bodies in the background for offline access
actor BodyPrefetchQueue {
    static let shared = BodyPrefetchQueue()

    private struct Job: Sendable {
        let emailId: String
        let threadId: String
        let accountEmail: String
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
    func enqueueCandidates(_ emails: [Email]) async {
        guard !emails.isEmpty else { return }

        // Filter out already queued and prioritize
        let prioritized = prioritize(emails)

        for email in prioritized.prefix(maxPrefetchPerSession) {
            guard let accountEmail = email.accountEmail else { continue }

            if queuedIds.contains(email.id) {
                continue
            }

            // Check if body is already cached
            let isCached = await MainActor.run {
                EmailCacheManager.shared.hasDetailCached(emailId: email.id)
            }

            if isCached {
                continue
            }

            queuedIds.insert(email.id)
            queue.append(Job(
                emailId: email.id,
                threadId: email.threadId,
                accountEmail: accountEmail
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
    private func prioritize(_ emails: [Email]) -> [Email] {
        emails.sorted { lhs, rhs in
            let lhsScore = priorityScore(lhs)
            let rhsScore = priorityScore(rhs)
            if lhsScore == rhsScore {
                return lhs.date > rhs.date
            }
            return lhsScore > rhsScore
        }
    }

    /// Calculate priority score (higher = more important)
    private func priorityScore(_ email: Email) -> Int {
        var score = 0
        if email.isUnread { score += 3 }
        if email.isStarred { score += 2 }
        // Prefer non-newsletter emails
        if email.listUnsubscribe == nil { score += 1 }
        return score
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

// MARK: - EmailCacheManager Extension

extension EmailCacheManager {
    /// Check if email detail (body) is cached
    func hasDetailCached(emailId: String) -> Bool {
        guard let context = modelContext else { return false }

        let descriptor = FetchDescriptor<EmailDetail>(
            predicate: #Predicate { $0.id == emailId }
        )

        return (try? context.fetchCount(descriptor)) ?? 0 > 0
    }

    /// Cache email detail (body)
    func cacheEmailDetail(_ dto: EmailDetailDTO) {
        guard let context = modelContext else { return }

        // Check if already cached
        let descriptor = FetchDescriptor<EmailDetail>(
            predicate: #Predicate { $0.id == dto.id }
        )

        if let existing = try? context.fetch(descriptor).first {
            // Update existing
            existing.body = dto.body
            existing.to = dto.to
            existing.cc = dto.cc
        } else {
            // Insert new
            let detail = EmailDetail(dto: dto)
            context.insert(detail)
        }

        try? context.save()
    }
}
