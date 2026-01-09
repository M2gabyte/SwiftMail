import Foundation
import OSLog
import CryptoKit
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class BriefingService {
    static let shared = BriefingService()

    private let logger = Logger(subsystem: "com.simplemail.app", category: "Briefing")
    private let snapshotKey = "briefingSnapshot"
    private let stateKey = "briefingUserState"
    private let calendar = Calendar.current

    private init() {}

    func loadCachedSnapshot(accountEmail: String?, scopeDays: Int) -> BriefingSnapshot? {
        guard let data = AccountDefaults.data(for: snapshotKey, accountEmail: accountEmail),
              let snapshot = try? JSONDecoder().decode(BriefingSnapshot.self, from: data),
              snapshot.scopeDays == scopeDays else {
            return nil
        }
        return snapshot
    }

    func saveSnapshot(_ snapshot: BriefingSnapshot, accountEmail: String?) {
        if let encoded = try? JSONEncoder().encode(snapshot) {
            AccountDefaults.setData(encoded, for: snapshotKey, accountEmail: accountEmail)
        }
    }

    func loadUserState(accountEmail: String?) -> BriefingUserState {
        guard let data = AccountDefaults.data(for: stateKey, accountEmail: accountEmail),
              let state = try? JSONDecoder().decode(BriefingUserState.self, from: data) else {
            return BriefingUserState()
        }
        return state
    }

    func saveUserState(_ state: BriefingUserState, accountEmail: String?) {
        if let encoded = try? JSONEncoder().encode(state) {
            AccountDefaults.setData(encoded, for: stateKey, accountEmail: accountEmail)
        }
    }

    func refreshSnapshot(scopeDays: Int, accountEmail: String?) async -> BriefingSnapshot {
        let candidates = collectCandidateThreads(scopeDays: scopeDays, accountEmail: accountEmail)
        let shortlist = Array(candidates.prefix(20))

        let hits = shortlist.map { $0.hit }
        let extraction = await extractItems(from: hits)
        let cleaned = filterAndNormalize(items: extraction.items, hits: hits)

        let ranked = rank(items: cleaned, hits: hits)
        let snapshot = BriefingSnapshot(
            items: ranked,
            sources: hits,
            generatedAt: Date(),
            scopeDays: scopeDays,
            generationNote: extraction.note
        )
        saveSnapshot(snapshot, accountEmail: accountEmail)
        return snapshot
    }

    // MARK: - Candidate selection

    private struct ThreadCandidate {
        let hit: BriefingThreadHit
        let score: Double
    }

    private func collectCandidateThreads(scopeDays: Int, accountEmail: String?) -> [ThreadCandidate] {
        let windowStart = calendar.date(byAdding: .day, value: -scopeDays, to: Date()) ?? Date.distantPast
        let raw = EmailCacheManager.shared.loadCachedEmails(
            mailbox: .inbox,
            limit: 500,
            accountEmail: accountEmail
        )
        let filtered = raw.filter { $0.date >= windowStart }

        var byThread: [String: Email] = [:]
        for email in filtered {
            if let existing = byThread[email.threadId] {
                if email.date > existing.date {
                    byThread[email.threadId] = email
                }
            } else {
                byThread[email.threadId] = email
            }
        }

        let sorted = byThread.values.sorted { $0.date > $1.date }
        let candidates = sorted.prefix(200).compactMap { email -> ThreadCandidate? in
            let snippet = email.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = fetchExcerptIfNeeded(messageId: email.id, fallbackSnippet: snippet)
            let hit = BriefingThreadHit(
                threadId: email.threadId,
                messageId: email.id,
                subject: email.subject,
                from: email.from,
                dateISO: ISO8601DateFormatter().string(from: email.date),
                snippet: snippet,
                isUnread: email.isUnread,
                labelIds: email.labelIds,
                accountEmail: email.accountEmail,
                excerpt: excerpt
            )

            var score = 0.0
            if email.isUnread { score += 6 }
            if email.labelIds.contains("IMPORTANT") { score += 4 }
            if email.labelIds.contains("CATEGORY_PERSONAL") { score += 3 }
            if email.isStarred { score += 2 }
            let ageHours = max(1.0, Date().timeIntervalSince(email.date) / 3600.0)
            score += max(0.0, 6.0 - log2(ageHours))

            return ThreadCandidate(hit: hit, score: score)
        }

        return candidates.sorted { $0.score > $1.score }
    }

    private func fetchExcerptIfNeeded(messageId: String, fallbackSnippet: String) -> String? {
        let trimmed = fallbackSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count < 80 else { return nil }
        guard let detail = EmailCacheManager.shared.loadCachedEmailDetail(id: messageId) else { return nil }
        let plain = SummaryService.plainText(detail.body)
        let normalized = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(320))
    }

    // MARK: - AI extraction

    private struct AIResponse: Codable {
        let items: [BriefingItem]
    }

    private struct ExtractionResult {
        let items: [BriefingItem]
        let note: String?
    }

    private func extractItems(from hits: [BriefingThreadHit]) async -> ExtractionResult {
        guard !hits.isEmpty else {
            return ExtractionResult(items: [], note: "No recent cached emails to analyze.")
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let prompt = buildPrompt(hits: hits)
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                let text = String(describing: response.content)
                if let json = extractJSON(from: text),
                   let data = json.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(AIResponse.self, from: data) {
                    return ExtractionResult(items: decoded.items, note: nil)
                }
            } catch {
                logger.error("Briefing AI extraction failed: \(error.localizedDescription)")
                return ExtractionResult(items: [], note: "Apple Intelligence failed to generate a briefing.")
            }
        }
        #endif

        return ExtractionResult(items: [], note: "Apple Intelligence is unavailable on this device.")
    }

    private func buildPrompt(hits: [BriefingThreadHit]) -> String {
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let data = (try? JSONEncoder().encode(hits)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        You are an on-device assistant extracting action items from email snippets.
        Current time: \(nowISO)

        Given the JSON array of thread hits below, return JSON only with this schema:
        {
          "items": [
            {
              "id": "stable-id",
              "type": "deadline|owe_reply|waiting|money",
              "title": "≤60 chars",
              "whyQuote": "verbatim quote ≤140 chars",
              "sourceThreadId": "thread id",
              "sourceMessageIds": ["msg id", "msg id?"],
              "confidence": "high|medium|low",
              "dueAt": "ISO8601 date or omit"
            }
          ]
        }

        Rules:
        - Use ONLY provided snippets/excerpts for evidence.
        - whyQuote must be verbatim from snippet/excerpt.
        - If no clear action or source, omit item.
        - Normalize relative dates to ISO8601 using current time.
        - Items must include sourceThreadId and 1-2 sourceMessageIds.

        Thread hits JSON:
        \(data)
        """
    }

    private func extractJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return nil
        }
        return String(text[start...end])
    }

    // MARK: - Validation + Ranking

    private func filterAndNormalize(items: [BriefingItem], hits: [BriefingThreadHit]) -> [BriefingItem] {
        let hitByThread = Dictionary(uniqueKeysWithValues: hits.map { ($0.threadId, $0) })
        var result: [BriefingItem] = []

        for item in items {
            guard !item.title.isEmpty,
                  item.title.count <= 60,
                  !item.whyQuote.isEmpty,
                  item.whyQuote.count <= 140,
                  hitByThread[item.sourceThreadId] != nil,
                  !item.sourceMessageIds.isEmpty else {
                continue
            }

            if let hit = hitByThread[item.sourceThreadId] {
                let evidence = (hit.snippet + " " + (hit.excerpt ?? "")).lowercased()
                if !evidence.contains(item.whyQuote.lowercased()) {
                    continue
                }
            }

            let stableId = stableItemId(item)
            var normalized = item
            normalized.id = stableId
            normalized.sourceMessageIds = Array(normalized.sourceMessageIds.prefix(2))
            result.append(normalized)
        }

        return result
    }

    private func stableItemId(_ item: BriefingItem) -> String {
        let basis = [
            item.sourceThreadId,
            item.type.rawValue,
            item.title.lowercased(),
            item.whyQuote.lowercased()
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(basis.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func rank(items: [BriefingItem], hits: [BriefingThreadHit]) -> [BriefingItem] {
        let hitByThread = Dictionary(uniqueKeysWithValues: hits.map { ($0.threadId, $0) })
        let now = Date()

        func dueDate(_ item: BriefingItem) -> Date? {
            guard let dueAt = item.dueAt else { return nil }
            return ISO8601DateFormatter().date(from: dueAt)
        }

        func typeWeight(_ item: BriefingItem) -> Int {
            switch item.type {
            case .oweReply: return 4
            case .deadline: return 3
            case .waiting: return 2
            case .money: return 1
            }
        }

        func score(_ item: BriefingItem) -> Double {
            var total = Double(typeWeight(item))
            if let due = dueDate(item) {
                let days = max(0, calendar.dateComponents([.day], from: now, to: due).day ?? 0)
                total += max(0, 10 - Double(days))
            }
            if let hit = hitByThread[item.sourceThreadId] {
                if hit.isUnread { total += 2 }
                if hit.labelIds.contains("IMPORTANT") { total += 2 }
                if hit.labelIds.contains("CATEGORY_PERSONAL") { total += 1 }
            }
            return total
        }

        return items.sorted { lhs, rhs in
            let lhsDue = dueDate(lhs)
            let rhsDue = dueDate(rhs)
            if let lhsDue, let rhsDue, lhsDue != rhsDue {
                return lhsDue < rhsDue
            }
            if lhsDue != nil && rhsDue == nil { return true }
            if lhsDue == nil && rhsDue != nil { return false }
            let lhsScore = score(lhs)
            let rhsScore = score(rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.title < rhs.title
        }
    }
}
