import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum SummaryService {
    static func summarizeIfNeeded(
        messageId: String,
        body: String,
        accountEmail: String?,
        minLength: Int = 350
    ) async -> String? {
        if let cached = SummaryCache.shared.summary(for: messageId, accountEmail: accountEmail) {
            return cached
        }

        let plain = plainText(body)
        guard plain.count >= minLength else {
            return nil
        }

        let summary: String
        do {
            summary = try await summarizeWithAppleIntelligence(plain)
        } catch {
            summary = extractKeySentences(from: plain, maxSentences: 3)
        }

        SummaryCache.shared.save(summary: summary, for: messageId, accountEmail: accountEmail)
        return summary
    }

    static func plainText(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&zwnj;", with: "")
            .replacingOccurrences(of: "&zwj;", with: "")
            .replacingOccurrences(of: "[\\u200B-\\u200D\\uFEFF]", with: "", options: .regularExpression)

        text = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text
    }

    static func extractKeySentences(from text: String, maxSentences: Int) -> String {
        let sentences = text.split(whereSeparator: { ".!?".contains($0) })
        let picked = sentences.prefix(maxSentences).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return picked.joined(separator: ". ") + (picked.isEmpty ? "" : ".")
    }

    static func summarizeWithAppleIntelligence(_ text: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let limited = String(trimmed.prefix(5000))
            let prompt = """
            Summarize this email in 2-3 concise sentences. Avoid fluff and keep key facts.
            \(limited)
            """
            let response = try await session.respond(to: prompt)
            let summaryText = String(describing: response.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !summaryText.isEmpty { return summaryText }
        }
        #endif
        throw SummaryError.unavailable
    }

    private enum SummaryError: Error {
        case unavailable
    }
}
