import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.simplemail.app", category: "ReplyAI")

// MARK: - Models

struct ReplyAIContext: Sendable {
    let accountEmail: String?
    let userName: String        // User's display name
    let senderName: String      // Name of person who sent the email
    let subject: String
    let latestInboundPlainText: String
    let latestInboundHTML: String?  // For link extraction
}

/// What the email is actually asking for
enum EmailIntent: String, Codable, Sendable {
    case surveyRequest      // Fill out a survey/feedback
    case meetingRequest     // Schedule a meeting/call
    case questionAsking     // Asking a direct question
    case infoSharing        // FYI, no response expected
    case actionRequest      // Asking user to do something specific
    case followUp           // Following up on something
    case introduction       // Intro/networking email
    case other
}

/// Extracted link from email
struct ExtractedLink: Codable, Identifiable, Sendable {
    var id: String { url }
    let url: String
    let label: String       // "survey", "calendar", "document", etc.
    let isActionable: Bool  // Should we surface this as a button?
}

/// Recommended action for the user
enum RecommendedAction: Codable, Sendable {
    case noReplyNeeded(reason: String, links: [ExtractedLink])
    case replyRecommended(reason: String)

    var requiresReply: Bool {
        switch self {
        case .noReplyNeeded: return false
        case .replyRecommended: return true
        }
    }
}

struct SuggestedReply: Codable, Identifiable, Sendable {
    var id: String { intent + body.prefix(20) }
    let intent: String      // What this reply accomplishes (action-oriented title)
    let body: String
    let hasBlanks: Bool     // Whether this has [[P1]] etc. placeholders
}

struct ReplyPlaceholder: Codable, Identifiable, Sendable {
    var id: String { token }
    let token: String
    let label: String
    let kind: String
    let example: String?
}

struct ReplyWithBlanks: Codable, Sendable {
    let body: String
    let placeholders: [ReplyPlaceholder]
}

struct ReplyAIResult: Codable, Sendable {
    let emailIntent: EmailIntent
    let recommendedAction: RecommendedAction
    let suggestedReplies: [SuggestedReply]
    let extractedLinks: [ExtractedLink]
}

// MARK: - Errors

enum ReplyAIError: Error, LocalizedError {
    case unavailable
    case invalidResponse
    case emptyContext
    case timeout

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Intelligence is not available on this device."
        case .invalidResponse:
            return "Could not parse AI response. Please try again."
        case .emptyContext:
            return "No email content to analyze."
        case .timeout:
            return "Request timed out. Please try again."
        }
    }
}

// MARK: - Reply AI Service

actor ReplyAIService {
    static let shared = ReplyAIService()

    private let maxInboundLength = 4000
    private let responseTimeout: Duration = .seconds(30)

    // Words to never use in generated replies (corporate-speak)
    private let bannedWords = [
        "commendable", "thrilled", "delighted", "esteemed", "appreciate your",
        "I wanted to reach out", "circle back", "synergy", "leverage", "utilize",
        "per our conversation", "as per", "pursuant to", "aforementioned",
        "please do not hesitate", "at your earliest convenience", "kindly",
        "rest assured", "I trust this", "please be advised"
    ]

    /// Generate AI reply suggestions for an email
    func generate(context: ReplyAIContext, voiceProfile: VoiceProfile) async throws -> ReplyAIResult {
        let trimmedText = context.latestInboundPlainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw ReplyAIError.emptyContext
        }

        // Extract links first (doesn't need AI)
        let links = extractLinks(from: context)

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await generateWithFoundationModels(context: context, voiceProfile: voiceProfile, links: links)
        }
        #endif

        // Fallback for devices without Apple Intelligence
        return createFallbackResult(context: context, voiceProfile: voiceProfile, links: links)
    }

    /// Check if Apple Intelligence is available
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    // MARK: - Link Extraction

    private func extractLinks(from context: ReplyAIContext) -> [ExtractedLink] {
        var links: [ExtractedLink] = []
        let text = context.latestInboundHTML ?? context.latestInboundPlainText

        // URL pattern
        let urlPattern = #"https?://[^\s<>\"\']+"#
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)

            for match in matches {
                if let urlRange = Range(match.range, in: text) {
                    var urlString = String(text[urlRange])
                    // Clean trailing punctuation
                    urlString = urlString.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)>"))

                    let label = classifyLink(urlString, context: context)
                    let isActionable = ["survey", "calendar", "document", "form"].contains(label)

                    // Avoid duplicates
                    if !links.contains(where: { $0.url == urlString }) {
                        links.append(ExtractedLink(url: urlString, label: label, isActionable: isActionable))
                    }
                }
            }
        }

        return links
    }

    private func classifyLink(_ url: String, context: ReplyAIContext) -> String {
        let lower = url.lowercased()
        let subjectLower = context.subject.lowercased()
        let bodyLower = context.latestInboundPlainText.lowercased()

        // Survey/feedback links
        if lower.contains("survey") || lower.contains("typeform") || lower.contains("forms.gle") ||
           lower.contains("surveymonkey") || lower.contains("feedback") || lower.contains("airtable.com/shr") {
            return "survey"
        }

        // Check context for survey mentions
        if (subjectLower.contains("survey") || subjectLower.contains("feedback") ||
            bodyLower.contains("fill out") || bodyLower.contains("take this survey")) {
            return "survey"
        }

        // Calendar links
        if lower.contains("calendly") || lower.contains("cal.com") || lower.contains("doodle") ||
           lower.contains("calendar") || lower.contains("scheduling") {
            return "calendar"
        }

        // Document links
        if lower.contains("docs.google") || lower.contains("notion.") || lower.contains("dropbox") ||
           lower.contains("drive.google") {
            return "document"
        }

        // Unsubscribe (not actionable)
        if lower.contains("unsubscribe") || lower.contains("opt-out") {
            return "unsubscribe"
        }

        return "link"
    }

    // MARK: - Foundation Models Implementation

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func generateWithFoundationModels(context: ReplyAIContext, voiceProfile: VoiceProfile, links: [ExtractedLink]) async -> ReplyAIResult {
        let session = LanguageModelSession()
        let inbound = String(context.latestInboundPlainText.prefix(maxInboundLength))

        // Detect email intent
        let intent = detectIntent(from: inbound, subject: context.subject, links: links)

        // Determine if reply is needed
        let recommendedAction = determineRecommendedAction(intent: intent, links: links, context: context)

        // Generate intent-appropriate suggestions
        do {
            let prompt = buildIntentBasedPrompt(
                context: context,
                voiceProfile: voiceProfile,
                inboundText: inbound,
                intent: intent,
                links: links
            )

            let response = try await withTimeout {
                try await session.respond(to: prompt)
            }
            let responseText = String(describing: response.content)
            logger.debug("AI response: \(responseText.prefix(500))")

            let suggestions = parseIntentBasedSuggestions(
                responseText,
                context: context,
                voiceProfile: voiceProfile,
                intent: intent,
                links: links
            )

            return ReplyAIResult(
                emailIntent: intent,
                recommendedAction: recommendedAction,
                suggestedReplies: suggestions,
                extractedLinks: links.filter { $0.isActionable }
            )

        } catch {
            logger.error("AI generation failed: \(error.localizedDescription)")
            return createFallbackResult(context: context, voiceProfile: voiceProfile, links: links)
        }
    }

    @available(iOS 26.0, *)
    private func withTimeout<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: self.responseTimeout)
                throw ReplyAIError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    #endif

    // MARK: - Intent Detection

    private func detectIntent(from text: String, subject: String, links: [ExtractedLink]) -> EmailIntent {
        let lower = text.lowercased()
        let subjectLower = subject.lowercased()

        // Survey/feedback request
        if links.contains(where: { $0.label == "survey" }) ||
           lower.contains("fill out") || lower.contains("survey") ||
           lower.contains("feedback") || lower.contains("your experience") {
            return .surveyRequest
        }

        // Meeting/call request
        if links.contains(where: { $0.label == "calendar" }) ||
           lower.contains("schedule") || lower.contains("meeting") ||
           lower.contains("call") || lower.contains("chat") ||
           lower.contains("available") || lower.contains("free to talk") {
            return .meetingRequest
        }

        // Direct question
        if lower.contains("?") && (lower.contains("could you") || lower.contains("can you") ||
           lower.contains("would you") || lower.contains("do you")) {
            return .questionAsking
        }

        // FYI / info sharing
        if subjectLower.hasPrefix("fyi") || subjectLower.contains("update") ||
           lower.contains("just wanted to let you know") || lower.contains("fyi") ||
           lower.contains("no action needed") || lower.contains("for your information") {
            return .infoSharing
        }

        // Follow up
        if subjectLower.contains("follow") || lower.contains("following up") ||
           lower.contains("circling back") || lower.contains("checking in") {
            return .followUp
        }

        // Introduction
        if subjectLower.contains("intro") || lower.contains("my name is") ||
           lower.contains("i'm reaching out") || lower.contains("wanted to introduce") {
            return .introduction
        }

        // Action request
        if lower.contains("please") && (lower.contains("send") || lower.contains("provide") ||
           lower.contains("review") || lower.contains("confirm")) {
            return .actionRequest
        }

        return .other
    }

    private func determineRecommendedAction(intent: EmailIntent, links: [ExtractedLink], context: ReplyAIContext) -> RecommendedAction {
        switch intent {
        case .surveyRequest:
            let surveyLinks = links.filter { $0.label == "survey" }
            if !surveyLinks.isEmpty {
                return .noReplyNeeded(reason: "Take the survey—no reply needed", links: surveyLinks)
            }
            return .replyRecommended(reason: "Survey link may be missing")

        case .infoSharing:
            return .noReplyNeeded(reason: "FYI only—no reply expected", links: [])

        case .meetingRequest:
            return .replyRecommended(reason: "Confirm or suggest times")

        case .questionAsking:
            return .replyRecommended(reason: "Answer the question")

        case .followUp:
            return .replyRecommended(reason: "Respond to follow-up")

        case .introduction:
            return .replyRecommended(reason: "Acknowledge introduction")

        case .actionRequest:
            return .replyRecommended(reason: "Confirm you'll take action")

        case .other:
            return .replyRecommended(reason: "Reply may be expected")
        }
    }

    // MARK: - Name Helpers

    /// Extract first name only (e.g., "Amol Avasare" → "Amol")
    private func firstName(from fullName: String) -> String {
        let components = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        return components.first ?? fullName
    }

    /// Build sign-off with user's name (e.g., "Thanks,\nMark")
    private func buildSignoff(_ baseSignoff: String, userName: String) -> String {
        let base = baseSignoff.trimmingCharacters(in: .whitespacesAndNewlines)
        let userFirstName = firstName(from: userName)

        // If signoff already contains a name or is multi-line, use as-is
        if base.contains("\n") || base.lowercased().contains(userFirstName.lowercased()) {
            return base
        }

        // Add user's first name on new line
        return "\(base),\n\(userFirstName)"
    }

    // MARK: - Prompt Building

    private func buildIntentBasedPrompt(context: ReplyAIContext, voiceProfile: VoiceProfile, inboundText: String, intent: EmailIntent, links: [ExtractedLink]) -> String {
        let senderFirstName = firstName(from: context.senderName)
        let greeting = voiceProfile.preferredGreeting.replacingOccurrences(of: "{name}", with: senderFirstName)
        let signoff = buildSignoff(voiceProfile.preferredSignoff, userName: context.userName)
        let maxWords = max(30, min(50, voiceProfile.avgWordCount))  // Cap at 50 for brevity

        let intentGuidance = intentSpecificGuidance(intent, links: links, context: context)

        return """
        Write 2-3 SHORT email replies. Each must be a DISTINCT response to what's being asked.

        EMAIL:
        From: \(context.senderName)
        Subject: \(context.subject)
        ---
        \(inboundText)
        ---

        WHAT'S BEING ASKED: \(intent.rawValue)
        \(intentGuidance)

        STRICT STYLE RULES:
        - Start with: \(greeting)
        - End with: \(signoff)
        - MAX \(maxWords) words total (be brief!)
        - \(voiceProfile.usesExclamationOften ? "Exclamations OK" : "NO exclamation marks")
        - Sound like a real person, not a corporate assistant
        - NEVER use: thrilled, commendable, delighted, appreciate your, kindly, rest assured
        - If times/dates needed, use [[P1]] and [[P2]] placeholders

        FORMAT (exactly like this):
        ---REPLY---
        [intent: 2-4 word action title, e.g. "I'll do it" or "Suggest times"]
        [the reply body]
        ---REPLY---
        [intent: different action]
        [different reply body]
        """
    }

    private func intentSpecificGuidance(_ intent: EmailIntent, links: [ExtractedLink], context: ReplyAIContext) -> String {
        switch intent {
        case .surveyRequest:
            let hasSurveyLink = links.contains { $0.label == "survey" }
            if hasSurveyLink {
                return """
                SUGGESTIONS NEEDED:
                1. "I'll fill it out" - very short acknowledgment
                2. "Happy to chat instead" - offer call with time blanks [[P1]] [[P2]]
                """
            } else {
                return """
                SUGGESTIONS NEEDED:
                1. "I'll do it" - short acknowledgment
                2. "Send me the link" - ask for the survey link
                """
            }

        case .meetingRequest:
            return """
            SUGGESTIONS NEEDED:
            1. "Works for me" - confirm (use [[P1]] if specific time mentioned)
            2. "How about [[P1]] or [[P2]]?" - suggest times (user fills in)
            3. "Can't make it" - brief decline
            """

        case .questionAsking:
            return """
            SUGGESTIONS NEEDED:
            1. Direct answer (if obvious from context)
            2. "Let me check" - will follow up
            3. "Can you clarify?" - need more info
            """

        case .infoSharing:
            return """
            SUGGESTIONS NEEDED:
            1. "Got it, thanks" - brief acknowledgment
            2. "Quick question: [[P1]]" - if you have a question
            """

        case .followUp:
            return """
            SUGGESTIONS NEEDED:
            1. "Here's the update" with [[P1]] for status
            2. "Still working on it" - brief
            3. "Let's discuss—[[P1]] work?" - schedule call
            """

        case .introduction:
            return """
            SUGGESTIONS NEEDED:
            1. "Nice to meet you" - brief, friendly
            2. "Happy to connect—[[P1]] works for a call?" - offer time
            """

        case .actionRequest:
            return """
            SUGGESTIONS NEEDED:
            1. "On it" / "Will do" - confirm action
            2. "Done" - if action is simple
            3. "Need [[P1]] first" - missing info
            """

        case .other:
            return """
            SUGGESTIONS NEEDED:
            1. Brief acknowledgment
            2. Follow-up question if needed
            """
        }
    }

    // MARK: - Suggestion Validation

    /// Validates a suggestion is high-quality enough to show
    private func isValidSuggestion(_ reply: SuggestedReply) -> Bool {
        let body = reply.body

        // Extract the "meat" - strip greeting line and signoff
        let lines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Need at least 3 lines (greeting, content, signoff)
        guard lines.count >= 3 else { return false }

        // Get content lines (skip first greeting, last 1-2 signoff lines)
        let contentLines = lines.dropFirst().dropLast(2)

        // Content must exist and not be ONLY a placeholder
        let contentText = contentLines.joined(separator: " ")

        // Check if content is meaningful:
        // 1. Strip placeholders and check what's left
        let withoutPlaceholders = contentText
            .replacingOccurrences(of: "[[P1]]", with: "")
            .replacingOccurrences(of: "[[P2]]", with: "")
            .replacingOccurrences(of: "[[P3]]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Must have at least 5 chars of actual content besides placeholders
        if withoutPlaceholders.count < 5 {
            return false
        }

        // 2. Must contain at least one word that isn't a placeholder
        let words = withoutPlaceholders.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        if words.isEmpty {
            return false
        }

        return true
    }

    // MARK: - Response Parsing

    private func parseIntentBasedSuggestions(_ text: String, context: ReplyAIContext, voiceProfile: VoiceProfile, intent: EmailIntent, links: [ExtractedLink]) -> [SuggestedReply] {
        var suggestions: [SuggestedReply] = []

        // Parse ---REPLY--- blocks
        let replyPattern = /---REPLY---\s*\[?intent:?\s*([^\]\n]+)\]?\s*([\s\S]*?)(?=---REPLY|\z)/

        let matches = text.matches(of: replyPattern)
        for match in matches {
            let intentTitle = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            var body = String(match.2).trimmingCharacters(in: .whitespacesAndNewlines)

            // Clean up
            body = cleanReplyBody(body, voiceProfile: voiceProfile)

            if !intentTitle.isEmpty && body.count >= 10 {
                let hasBlanks = body.contains("[[P1]]") || body.contains("[[P2]]")
                let suggestion = SuggestedReply(
                    intent: intentTitle,
                    body: body,
                    hasBlanks: hasBlanks
                )

                // Only add if it passes validation
                if isValidSuggestion(suggestion) {
                    suggestions.append(suggestion)
                }
            }
        }

        // If parsing failed or all were invalid, use intent-specific fallbacks
        if suggestions.isEmpty {
            suggestions = createIntentFallbacks(context: context, voiceProfile: voiceProfile, intent: intent, links: links)
        }

        // Validate fallbacks too (filter out any bad ones)
        suggestions = suggestions.filter { isValidSuggestion($0) }

        // Top up with more fallbacks if needed (but cap at 3 attempts)
        var attempts = 0
        while suggestions.count < 2 && attempts < 3 {
            let more = createIntentFallbacks(context: context, voiceProfile: voiceProfile, intent: intent, links: links)
                .filter { isValidSuggestion($0) }
            suggestions.append(contentsOf: more)
            attempts += 1
        }

        return Array(suggestions.prefix(3))
    }

    private func cleanReplyBody(_ text: String, voiceProfile: VoiceProfile) -> String {
        var cleaned = text

        // Remove formatting artifacts
        cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        cleaned = cleaned.replacingOccurrences(of: "(?i)\\[intent:[^\\]]*\\]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?i)\\[body[^\\]]*\\]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?i)\\[title:[^\\]]*\\]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "---+", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\[Your Name\\]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\[your name\\]", with: "", options: .regularExpression)

        // Normalize BLANK tokens to P tokens
        cleaned = cleaned.replacingOccurrences(of: "[[BLANK1]]", with: "[[P1]]")
        cleaned = cleaned.replacingOccurrences(of: "[[BLANK2]]", with: "[[P2]]")
        cleaned = cleaned.replacingOccurrences(of: "[[BLANK3]]", with: "[[P3]]")

        // Remove banned corporate words
        for banned in bannedWords {
            cleaned = cleaned.replacingOccurrences(of: banned, with: "", options: .caseInsensitive)
        }

        // Clean up excessive whitespace
        cleaned = cleaned.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)

        // Enforce exclamation policy
        if !voiceProfile.usesExclamationOften {
            cleaned = cleaned.replacingOccurrences(of: "!", with: ".")
            cleaned = cleaned.replacingOccurrences(of: "..", with: ".")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Fallback Generation

    private func createFallbackResult(context: ReplyAIContext, voiceProfile: VoiceProfile, links: [ExtractedLink]) -> ReplyAIResult {
        let intent = detectIntent(from: context.latestInboundPlainText, subject: context.subject, links: links)
        let action = determineRecommendedAction(intent: intent, links: links, context: context)

        return ReplyAIResult(
            emailIntent: intent,
            recommendedAction: action,
            suggestedReplies: createIntentFallbacks(context: context, voiceProfile: voiceProfile, intent: intent, links: links),
            extractedLinks: links.filter { $0.isActionable }
        )
    }

    private func createIntentFallbacks(context: ReplyAIContext, voiceProfile: VoiceProfile, intent: EmailIntent, links: [ExtractedLink]) -> [SuggestedReply] {
        // Use first name only for greeting
        let senderFirstName = firstName(from: context.senderName)
        let greeting = voiceProfile.preferredGreeting.replacingOccurrences(of: "{name}", with: senderFirstName)
        let signoff = buildSignoff(voiceProfile.preferredSignoff, userName: context.userName)

        switch intent {
        case .surveyRequest:
            let hasSurveyLink = links.contains { $0.label == "survey" }
            if hasSurveyLink {
                return [
                    SuggestedReply(
                        intent: "I'll fill it out",
                        body: "\(greeting)\n\nWill do.\n\n\(signoff)",
                        hasBlanks: false
                    ),
                    SuggestedReply(
                        intent: "Happy to chat instead",
                        body: "\(greeting)\n\nHappy to chat if that's more useful. [[P1]] or [[P2]] work?\n\n\(signoff)",
                        hasBlanks: true
                    ),
                    SuggestedReply(
                        intent: "Quick question first",
                        body: "\(greeting)\n\nQuick question before I fill it out: [[P1]]\n\n\(signoff)",
                        hasBlanks: true
                    )
                ]
            } else {
                return [
                    SuggestedReply(
                        intent: "Send me the link",
                        body: "\(greeting)\n\nCan you send me the survey link?\n\n\(signoff)",
                        hasBlanks: false
                    ),
                    SuggestedReply(
                        intent: "Quick question first",
                        body: "\(greeting)\n\nQuick question: [[P1]]\n\n\(signoff)",
                        hasBlanks: true
                    )
                ]
            }

        case .meetingRequest:
            return [
                SuggestedReply(
                    intent: "Works for me",
                    body: "\(greeting)\n\nWorks for me.\n\n\(signoff)",
                    hasBlanks: false
                ),
                SuggestedReply(
                    intent: "Suggest times",
                    body: "\(greeting)\n\nHow about [[P1]] or [[P2]]?\n\n\(signoff)",
                    hasBlanks: true
                ),
                SuggestedReply(
                    intent: "Can't make it",
                    body: "\(greeting)\n\nCan't make that work. Any other times?\n\n\(signoff)",
                    hasBlanks: false
                )
            ]

        case .questionAsking:
            return [
                SuggestedReply(
                    intent: "Here's the answer",
                    body: "\(greeting)\n\n[[P1]]\n\n\(signoff)",
                    hasBlanks: true
                ),
                SuggestedReply(
                    intent: "Let me check",
                    body: "\(greeting)\n\nLet me check and get back to you.\n\n\(signoff)",
                    hasBlanks: false
                )
            ]

        case .infoSharing:
            return [
                SuggestedReply(
                    intent: "Got it",
                    body: "\(greeting)\n\nGot it, thanks.\n\n\(signoff)",
                    hasBlanks: false
                )
            ]

        case .followUp:
            return [
                SuggestedReply(
                    intent: "Here's an update",
                    body: "\(greeting)\n\n[[P1]]\n\n\(signoff)",
                    hasBlanks: true
                ),
                SuggestedReply(
                    intent: "Still working on it",
                    body: "\(greeting)\n\nStill working on this. Will follow up soon.\n\n\(signoff)",
                    hasBlanks: false
                )
            ]

        case .introduction:
            return [
                SuggestedReply(
                    intent: "Nice to meet you",
                    body: "\(greeting)\n\nNice to meet you.\n\n\(signoff)",
                    hasBlanks: false
                ),
                SuggestedReply(
                    intent: "Let's connect",
                    body: "\(greeting)\n\nHappy to connect. [[P1]] work for a quick call?\n\n\(signoff)",
                    hasBlanks: true
                )
            ]

        case .actionRequest:
            return [
                SuggestedReply(
                    intent: "On it",
                    body: "\(greeting)\n\nOn it.\n\n\(signoff)",
                    hasBlanks: false
                ),
                SuggestedReply(
                    intent: "Done",
                    body: "\(greeting)\n\nDone.\n\n\(signoff)",
                    hasBlanks: false
                )
            ]

        case .other:
            return [
                SuggestedReply(
                    intent: "Thanks",
                    body: "\(greeting)\n\nThanks for reaching out.\n\n\(signoff)",
                    hasBlanks: false
                ),
                SuggestedReply(
                    intent: "Let me know",
                    body: "\(greeting)\n\nLet me know if you need anything.\n\n\(signoff)",
                    hasBlanks: false
                )
            ]
        }
    }

    // MARK: - Placeholder Extraction

    /// Extract placeholder info from a reply body
    nonisolated func extractPlaceholders(from body: String, intent: EmailIntent) -> [ReplyPlaceholder] {
        var placeholders: [ReplyPlaceholder] = []

        if body.contains("[[P1]]") {
            let (label, kind, example) = placeholderInfo(index: 1, intent: intent)
            placeholders.append(ReplyPlaceholder(token: "[[P1]]", label: label, kind: kind, example: example))
        }
        if body.contains("[[P2]]") {
            let (label, kind, example) = placeholderInfo(index: 2, intent: intent)
            placeholders.append(ReplyPlaceholder(token: "[[P2]]", label: label, kind: kind, example: example))
        }
        if body.contains("[[P3]]") {
            let (label, kind, example) = placeholderInfo(index: 3, intent: intent)
            placeholders.append(ReplyPlaceholder(token: "[[P3]]", label: label, kind: kind, example: example))
        }

        return placeholders
    }

    private nonisolated func placeholderInfo(index: Int, intent: EmailIntent) -> (label: String, kind: String, example: String?) {
        // Get device timezone abbreviation
        let tz = TimeZone.current.abbreviation() ?? "local"

        switch intent {
        case .meetingRequest, .introduction:
            if index == 1 {
                return ("First time", "time", "Tuesday 2pm \(tz)")
            } else {
                return ("Second time", "time", "Thursday morning \(tz)")
            }

        case .questionAsking, .followUp:
            return ("Your response", "info", nil)

        case .surveyRequest:
            if index == 1 {
                return ("First time", "time", "Monday afternoon \(tz)")
            } else {
                return ("Second time", "time", "Wednesday \(tz)")
            }

        default:
            return ("Your input", "info", nil)
        }
    }
}
