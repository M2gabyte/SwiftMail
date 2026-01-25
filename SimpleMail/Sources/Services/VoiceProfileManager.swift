import Foundation

// MARK: - Models

struct SentSample: Codable, Identifiable, Sendable {
    let id: String         // message-id or UUID
    let date: Date
    let subject: String
    let body: String       // plain text only
}

struct VoiceProfile: Codable, Sendable {
    var preferredGreeting: String          // e.g. "Hi {name},"
    var preferredSignoff: String           // e.g. "Thanks,\nMark"
    var avgWordCount: Int
    var usesExclamationOften: Bool
    var typicalParagraphCount: Int

    var styleInstruction: String {
        """
        Match my writing style:
        - Greeting format: \(preferredGreeting)
        - Sign-off format: \(preferredSignoff)
        - Brevity: target ~\(avgWordCount) words, ~\(typicalParagraphCount) paragraphs
        - Punctuation: \(usesExclamationOften ? "exclamation OK" : "avoid exclamation")
        """
    }

    static let `default` = VoiceProfile(
        preferredGreeting: "Hi {name},",
        preferredSignoff: "Thanks",
        avgWordCount: 90,
        usesExclamationOften: false,
        typicalParagraphCount: 2
    )
}

// MARK: - Voice Profile Manager

/// On-device style learner.
/// NOTE: This does not send your sent mail anywhere; it only computes aggregate preferences.
actor VoiceProfileManager {
    static let shared = VoiceProfileManager()

    private let samplesKey = "voiceProfile.sentSamples.v1"
    private let profileKey = "voiceProfile.profile.v1"
    private let maxSamples = 200
    private let minSamplesForProfile = 5

    // MARK: - Public API

    /// Record a successfully sent email for voice profile training
    func recordSentEmail(accountEmail: String?, subject: String, body: String) async {
        let acct = normalizedAccount(accountEmail)
        var samples = await loadSamples(accountEmail: acct)

        // Clean up plain text body
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip very short emails (likely auto-replies or minimal responses)
        guard trimmed.count >= 20 else { return }

        // Skip if we already have this exact body (duplicate sends)
        if samples.contains(where: { $0.body == trimmed }) { return }

        let sample = SentSample(
            id: UUID().uuidString,
            date: Date(),
            subject: subject,
            body: trimmed
        )

        samples.append(sample)

        // Maintain rolling buffer
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }

        await saveSamples(samples, accountEmail: acct)

        // Recompute profile with new data
        let profile = computeProfile(from: samples)
        await saveProfile(profile, accountEmail: acct)
    }

    /// Get current voice profile for account
    func currentProfile(accountEmail: String?) async -> VoiceProfile {
        let acct = normalizedAccount(accountEmail)

        if let cached = await loadProfile(accountEmail: acct) {
            return cached
        }

        // Return sensible defaults until we have enough samples
        let fallback = VoiceProfile.default
        await saveProfile(fallback, accountEmail: acct)
        return fallback
    }

    /// Get the number of samples collected for an account
    func sampleCount(accountEmail: String?) async -> Int {
        let acct = normalizedAccount(accountEmail)
        return await loadSamples(accountEmail: acct).count
    }

    /// Check if we have enough samples for meaningful profile
    func hasEnoughSamples(accountEmail: String?) async -> Bool {
        await sampleCount(accountEmail: accountEmail) >= minSamplesForProfile
    }

    // MARK: - Profile Computation

    private func computeProfile(from samples: [SentSample]) -> VoiceProfile {
        guard !samples.isEmpty else { return .default }

        let bodies = samples.map(\.body)

        // Extract greeting patterns
        let greetings = bodies.compactMap { extractGreeting($0) }
        let preferredGreeting = mostCommon(greetings) ?? VoiceProfile.default.preferredGreeting

        // Extract sign-off patterns
        let signoffs = bodies.compactMap { extractSignoff($0) }
        let preferredSignoff = mostCommon(signoffs) ?? VoiceProfile.default.preferredSignoff

        // Calculate word count statistics
        let wordCounts = bodies.map { wordCount($0) }
        let avgWords = max(40, wordCounts.reduce(0, +) / max(1, wordCounts.count))

        // Detect exclamation usage
        let exclamationCount = bodies.filter { $0.contains("!") }.count
        let usesExclamOften = exclamationCount >= max(2, bodies.count / 4)

        // Calculate paragraph statistics
        let paraCounts = bodies.map { paragraphCount($0) }
        let avgParas = max(1, paraCounts.reduce(0, +) / max(1, paraCounts.count))

        return VoiceProfile(
            preferredGreeting: preferredGreeting,
            preferredSignoff: preferredSignoff,
            avgWordCount: avgWords,
            usesExclamationOften: usesExclamOften,
            typicalParagraphCount: avgParas
        )
    }

    // MARK: - Text Analysis Helpers

    private func extractGreeting(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines.prefix(3) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let lower = trimmed.lowercased()

            // Match common greeting patterns
            if lower.hasPrefix("hi ") || lower.hasPrefix("hi,") ||
               lower.hasPrefix("hello ") || lower.hasPrefix("hello,") ||
               lower.hasPrefix("hey ") || lower.hasPrefix("hey,") ||
               lower.hasPrefix("dear ") || lower.hasPrefix("good morning") ||
               lower.hasPrefix("good afternoon") || lower.hasPrefix("good evening") {
                // Normalize name placeholder
                return normalizeGreeting(trimmed)
            }

            // Just "Hi," or "Hello," standalone
            if lower == "hi," || lower == "hello," || lower == "hey," {
                return trimmed
            }

            // If first non-empty line isn't a greeting, stop looking
            break
        }

        return nil
    }

    private func normalizeGreeting(_ greeting: String) -> String {
        // Replace specific names with {name} placeholder
        // Pattern: "Hi NAME," -> "Hi {name},"
        var result = greeting

        // Common patterns: "Hi John," "Hello Sarah," etc.
        let patterns = [
            ("^(Hi|Hello|Hey|Dear)\\s+([A-Z][a-z]+)", "$1 {name}"),
            ("^(Good\\s+(?:morning|afternoon|evening))\\s+([A-Z][a-z]+)", "$1 {name}")
        ]

        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }

        return result
    }

    private func extractSignoff(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let nonEmpty = lines.filter { !$0.isEmpty }

        guard nonEmpty.count >= 1 else { return nil }

        // Look at last 4 lines for sign-off pattern
        let tail = Array(nonEmpty.suffix(4))

        // Common sign-off keywords
        let signoffKeywords = ["thanks", "thank you", "best", "regards", "cheers", "sincerely",
                              "best regards", "kind regards", "warm regards", "take care",
                              "talk soon", "speak soon", "ttyl", "sent from"]

        // Find where sign-off starts
        var signoffStart: Int?
        for (i, line) in tail.enumerated() {
            let lower = line.lowercased()
            if signoffKeywords.contains(where: { lower.hasPrefix($0) || lower == $0 }) {
                signoffStart = i
                break
            }
        }

        guard let start = signoffStart else { return nil }

        // Collect sign-off lines (typically 1-3 lines)
        let signoffLines = Array(tail[start...])

        // Filter out signature noise (phone numbers, URLs, job titles)
        let cleanLines = signoffLines.filter { line in
            let lower = line.lowercased()
            // Skip lines that look like signature metadata
            if lower.contains("http") || lower.contains("www.") { return false }
            if lower.contains("sent from my") { return false }
            if line.range(of: "\\d{3}[-.]\\d{3}[-.]\\d{4}", options: .regularExpression) != nil { return false }
            return true
        }

        guard !cleanLines.isEmpty else { return nil }

        let signoff = cleanLines.joined(separator: "\n")

        // Limit sign-off length
        guard signoff.count <= 100 else { return nil }

        return signoff
    }

    private func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private func paragraphCount(_ text: String) -> Int {
        // Split on double newlines or single newlines with blank lines
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return max(1, paragraphs.count)
    }

    private func mostCommon(_ items: [String]) -> String? {
        guard !items.isEmpty else { return nil }

        var frequency: [String: Int] = [:]
        for item in items {
            frequency[item, default: 0] += 1
        }

        return frequency.max { $0.value < $1.value }?.key
    }

    private func normalizedAccount(_ email: String?) -> String {
        (email ?? "unknown").lowercased()
    }

    // MARK: - Storage (MainActor bridging)

    private func loadSamples(accountEmail: String) async -> [SentSample] {
        await MainActor.run {
            guard let data = AccountDefaults.data(for: samplesKey, accountEmail: accountEmail),
                  let decoded = try? JSONDecoder().decode([SentSample].self, from: data)
            else { return [] }
            return decoded
        }
    }

    private func saveSamples(_ samples: [SentSample], accountEmail: String) async {
        await MainActor.run {
            if let data = try? JSONEncoder().encode(samples) {
                AccountDefaults.setData(data, for: samplesKey, accountEmail: accountEmail)
            }
        }
    }

    private func loadProfile(accountEmail: String) async -> VoiceProfile? {
        await MainActor.run {
            guard let data = AccountDefaults.data(for: profileKey, accountEmail: accountEmail),
                  let decoded = try? JSONDecoder().decode(VoiceProfile.self, from: data)
            else { return nil }
            return decoded
        }
    }

    private func saveProfile(_ profile: VoiceProfile, accountEmail: String) async {
        await MainActor.run {
            if let data = try? JSONEncoder().encode(profile) {
                AccountDefaults.setData(data, for: profileKey, accountEmail: accountEmail)
            }
        }
    }
}
