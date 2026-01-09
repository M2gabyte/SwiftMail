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
    private let noReplyPatterns: [NSRegularExpression] = {
        let patterns = [
            "noreply", "no-reply", "donotreply", "do-not-reply",
            "notifications?@", "notify@", "info@", "marketing@",
            "newsletter@", "updates@", "mailer-daemon", "postmaster"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private let askPatterns: [NSRegularExpression] = {
        let patterns = [
            "can\\s+you", "could\\s+you", "would\\s+you", "please\\s+",
            "let\\s+me\\s+know", "need\\s+you\\s+to", "request",
            "confirm", "send\\s+me", "share", "follow\\s+up"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private let deadlinePatterns: [NSRegularExpression] = {
        let patterns = [
            "\\btoday\\b", "\\btomorrow\\b", "\\beod\\b",
            "\\bend\\s+of\\s+day\\b", "\\bdue\\b", "\\bdeadline\\b",
            "\\bby\\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b",
            "\\bby\\s+\\d{1,2}/\\d{1,2}\\b"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private let moneyPatterns: [NSRegularExpression] = {
        let patterns = [
            "\\binvoice\\b", "\\bpayment\\b", "\\bcharged\\b", "\\bcharge\\b",
            "\\brefund\\b", "\\breceipt\\b", "\\bsubscription\\b", "\\brenewal\\b",
            "\\baction\\s+required\\b", "\\bpay\\b"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

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
        let shortlist = Array(candidates.prefix(4))

        let hits = shortlist.map { $0.hit }
        let extraction = await extractItems(from: hits)
        var cleaned = filterAndNormalize(items: extraction.items, hits: hits)
        if cleaned.isEmpty {
            let fallback = deterministicFallback(from: hits)
            cleaned = filterAndNormalize(items: fallback, hits: hits)
        }

        let ranked = rank(items: cleaned, hits: hits)
        let debugInfo = BriefingDebugInfo(
            candidateCount: candidates.count,
            shortlistCount: hits.count,
            aiItemCount: extraction.items.count,
            keptItemCount: ranked.count
        )
        let snapshot = BriefingSnapshot(
            items: ranked,
            sources: hits,
            generatedAt: Date(),
            scopeDays: scopeDays,
            generationNote: extraction.note,
            debugInfo: debugInfo
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
            let senderEmail = EmailParser.extractSenderEmail(from: email.from).lowercased()
            if isNoReply(senderEmail) { return nil }
            if EmailFilters.isBulk(email) { return nil }
            if !EmailFilters.looksLikeHumanSender(email) { return nil }

            let snippet = email.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = fetchExcerptIfNeeded(messageId: email.id, fallbackSnippet: snippet)
            let evidenceText = ((snippet + " " + (excerpt ?? "")).trimmingCharacters(in: .whitespacesAndNewlines))
            if !matchesAny(evidenceText, patterns: askPatterns + deadlinePatterns + moneyPatterns) {
                return nil
            }

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
            if matchesAny(evidenceText, patterns: deadlinePatterns) { score += 3 }
            if matchesAny(evidenceText, patterns: askPatterns) { score += 2 }
            if matchesAny(evidenceText, patterns: moneyPatterns) { score += 2 }
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
        return String(normalized.prefix(80))
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
            var merged: [BriefingItem] = []
            var lastError: String?
            let batches = stride(from: 0, to: hits.count, by: 2).map {
                Array(hits[$0..<min($0 + 2, hits.count)])
            }
            for batch in batches {
                let prompt = buildPrompt(hits: batch)
                do {
                    let session = LanguageModelSession()
                    let response = try await session.respond(to: prompt)
                    let text = String(describing: response.content)
                    if let json = extractJSON(from: text),
                       let data = json.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode(AIResponse.self, from: data) {
                        merged.append(contentsOf: decoded.items)
                    }
                } catch {
                    lastError = error.localizedDescription
                    logger.error("Briefing AI extraction failed: \(error.localizedDescription)")
                }
            }
            if !merged.isEmpty {
                return ExtractionResult(items: merged, note: nil)
            }
            return ExtractionResult(items: [], note: "Apple Intelligence failed to generate a briefing.")
        }
        #endif

        // Simulator: skip AI to avoid stalls
        #if targetEnvironment(simulator)
        return ExtractionResult(items: [], note: "Simulator: AI skipped, using fallback.")
        #endif

        return ExtractionResult(items: [], note: "Apple Intelligence is unavailable on this device.")
    }

    private struct AINarrowHit: Codable {
        let threadId: String
        let messageId: String
        let from: String
        let subject: String
        let snippet: String
        let excerpt: String?
    }

    private func buildPrompt(hits: [BriefingThreadHit]) -> String {
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let compactHits = hits.map { hit in
            AINarrowHit(
                threadId: hit.threadId,
                messageId: hit.messageId,
                from: String(hit.from.prefix(50)),
                subject: String(hit.subject.prefix(50)),
                snippet: String(hit.snippet.prefix(80)),
                excerpt: hit.snippet.count > 60 ? nil : hit.excerpt.map { String($0.prefix(80)) }
            )
        }
        let data = (try? JSONEncoder().encode(compactHits)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        Extract action items from the JSON thread hits. Current time: \(nowISO)

        Return JSON only with schema:
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

        Thread hits JSON (fields: threadId, messageId, from, subject, snippet, excerpt):
        \(data)
        """
    }

    // MARK: - Deterministic fallback (no AI)

    private func deterministicFallback(from hits: [BriefingThreadHit]) -> [BriefingItem] {
        var items: [BriefingItem] = []
        for hit in hits {
            let evidenceText = (hit.snippet + " " + (hit.excerpt ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !evidenceText.isEmpty else { continue }

            if let quote = extractQuote(from: evidenceText, patterns: deadlinePatterns) {
                let item = BriefingItem(
                    id: "",
                    type: .deadline,
                    title: "Handle: \(shortTitle(from: hit.subject))",
                    whyQuote: quote,
                    sourceThreadId: hit.threadId,
                    sourceMessageIds: [hit.messageId],
                    confidence: .medium,
                    dueAt: inferredDueDate(from: quote)
                )
                items.append(item)
                continue
            }

            if let quote = extractQuote(from: evidenceText, patterns: askPatterns) {
                let sender = EmailParser.extractSenderName(from: hit.from)
                let item = BriefingItem(
                    id: "",
                    type: .oweReply,
                    title: "Reply to \(sender): \(shortTitle(from: hit.subject))",
                    whyQuote: quote,
                    sourceThreadId: hit.threadId,
                    sourceMessageIds: [hit.messageId],
                    confidence: .medium,
                    dueAt: inferredDueDate(from: quote)
                )
                items.append(item)
                continue
            }

            if let quote = extractQuote(from: evidenceText, patterns: moneyPatterns) {
                let item = BriefingItem(
                    id: "",
                    type: .money,
                    title: "Review payment: \(shortTitle(from: hit.subject))",
                    whyQuote: quote,
                    sourceThreadId: hit.threadId,
                    sourceMessageIds: [hit.messageId],
                    confidence: .medium,
                    dueAt: nil
                )
                items.append(item)
                continue
            }
        }

        return items
    }

    private func shortTitle(from subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No subject" }
        return String(trimmed.prefix(40))
    }

    private func isNoReply(_ email: String) -> Bool {
        matchesAny(email, patterns: noReplyPatterns)
    }

    private func matchesAny(_ text: String, patterns: [NSRegularExpression]) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
    }

    private func extractQuote(from text: String, patterns: [NSRegularExpression]) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            if let match = pattern.firstMatch(in: text, options: [], range: range),
               let matchRange = Range(match.range, in: text) {
                let snippet = extractSentence(from: text, around: matchRange)
                return String(snippet.prefix(140))
            }
        }
        return nil
    }

    private func extractSentence(from text: String, around range: Range<String.Index>) -> String {
        let start = text[..<range.lowerBound].lastIndex(of: ".") ?? text.startIndex
        let end = text[range.upperBound...].firstIndex(of: ".") ?? text.endIndex
        let slice = text[start..<end]
        return slice.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func inferredDueDate(from quote: String) -> String? {
        let lower = quote.lowercased()
        if lower.contains("tomorrow") {
            if let date = calendar.date(byAdding: .day, value: 1, to: Date()) {
                return ISO8601DateFormatter().string(from: date)
            }
        }
        if lower.contains("today") || lower.contains("eod") || lower.contains("end of day") {
            return ISO8601DateFormatter().string(from: Date())
        }
        return nil
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
