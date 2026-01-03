import Foundation

/// Utility for normalizing email subjects and snippets for clean inbox display.
/// This is display-only normalization - underlying stored data is not modified.
enum EmailPreviewNormalizer {

    // MARK: - Subject Normalization

    /// Remove repeated leading prefixes (Fwd:, Fw:, Re:) from subject for cleaner display.
    /// - Parameter subject: Raw email subject
    /// - Returns: Cleaned subject without prefix clutter
    static func normalizeSubjectForDisplay(_ subject: String) -> String {
        var result = subject.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pattern to match leading prefixes: Fwd:, Fw:, Re: (case-insensitive)
        // Repeat until no more prefixes at the start
        let prefixPattern = #"^(?:(?:fwd|fw|re)\s*:\s*)+"#

        if let regex = try? NSRegularExpression(pattern: prefixPattern, options: .caseInsensitive) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Snippet Normalization

    /// Clean up email snippet to show only meaningful content.
    /// Removes forwarded headers, reply boilerplate, and common junk.
    /// - Parameter snippet: Raw email snippet/preview text
    /// - Returns: Single line, max ~140 chars, with ellipsis if truncated
    static func normalizeSnippetForDisplay(_ snippet: String) -> String {
        guard !snippet.isEmpty else { return "" }

        // Convert Windows newlines to \n
        var text = snippet.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        // Split into lines
        let lines = text.components(separatedBy: "\n")

        var cleanedLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            guard !trimmed.isEmpty else { continue }

            // Check for "On ... wrote:" pattern (Gmail-style quote attribution)
            // Stop scanning when we hit this - everything after is quoted content
            if isQuoteAttribution(trimmed) {
                break
            }

            // Skip if line matches boilerplate patterns
            if isBoilerplate(trimmed) {
                continue
            }

            // Skip quoted reply lines starting with ">"
            if trimmed.hasPrefix(">") {
                continue
            }

            // Skip lines that are mostly punctuation/dashes/underscores (>= 60% non-alphanumeric)
            if isPunctuationHeavy(trimmed) {
                continue
            }

            // Skip lines that look like email headers
            if isEmailHeader(trimmed) {
                continue
            }

            cleanedLines.append(trimmed)
        }

        // Find first line with at least 6 alphanumeric characters and at least one letter
        var meaningfulLine: String? = nil
        for line in cleanedLines {
            if hasMeaningfulContent(line) {
                meaningfulLine = line
                break
            }
        }

        // Fallback to first non-empty line after filtering
        if meaningfulLine == nil, let firstLine = cleanedLines.first {
            meaningfulLine = firstLine
        }

        guard var result = meaningfulLine else { return "" }

        // Collapse internal whitespace to single spaces
        result = collapseWhitespace(result)

        // Truncate to 140 chars with ellipsis
        if result.count > 140 {
            let truncated = String(result.prefix(137))
            // Try to break at a word boundary
            if let lastSpace = truncated.lastIndex(of: " "), lastSpace > truncated.startIndex {
                result = String(truncated[..<lastSpace]) + "..."
            } else {
                result = truncated + "..."
            }
        }

        return result
    }

    // MARK: - Helper Functions

    /// Check if line is a quote attribution like "On Jan 1, 2024, John wrote:"
    private static func isQuoteAttribution(_ line: String) -> Bool {
        let lower = line.lowercased()

        // Pattern: "On [date/anything], [name] wrote:"
        if lower.hasPrefix("on ") && lower.hasSuffix("wrote:") {
            return true
        }

        // Pattern: "[Name] wrote:" at end
        if lower.hasSuffix("wrote:") && line.count < 150 {
            return true
        }

        return false
    }

    /// Check if line matches common boilerplate patterns
    private static func isBoilerplate(_ line: String) -> Bool {
        let lower = line.lowercased()
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Forwarded message separators
        let forwardedPatterns = [
            "---------- forwarded message ----------",
            "-----original message-----",
            "begin forwarded message",
            "forwarded message:",
            "--- forwarded message ---"
        ]
        for pattern in forwardedPatterns {
            if lower.contains(pattern) {
                return true
            }
        }

        // Lines starting with common email headers (in boilerplate context)
        let headerPrefixes = ["from:", "sent:", "to:", "subject:", "date:", "cc:", "bcc:"]
        for prefix in headerPrefixes {
            if lower.hasPrefix(prefix) {
                return true
            }
        }

        // Long dashed separators
        if trimmed.hasPrefix("---") && trimmed.filter({ $0 == "-" }).count > 5 {
            return true
        }
        if trimmed.hasPrefix("___") && trimmed.filter({ $0 == "_" }).count > 5 {
            return true
        }

        return false
    }

    /// Check if line looks like an email header (X-..., Message-ID:, etc.)
    private static func isEmailHeader(_ line: String) -> Bool {
        let lower = line.lowercased()

        // X-headers
        if lower.hasPrefix("x-") && line.contains(":") {
            return true
        }

        // Common technical headers
        let technicalHeaders = [
            "message-id:", "content-type:", "content-transfer-encoding:",
            "mime-version:", "return-path:", "received:", "dkim-signature:",
            "authentication-results:", "list-unsubscribe:", "list-id:",
            "precedence:", "auto-submitted:", "reply-to:", "in-reply-to:",
            "references:"
        ]
        for header in technicalHeaders {
            if lower.hasPrefix(header) {
                return true
            }
        }

        return false
    }

    /// Check if line is mostly punctuation (>= 60% non-alphanumeric)
    private static func isPunctuationHeavy(_ line: String) -> Bool {
        guard line.count >= 4 else { return false }

        let alphanumericCount = line.filter { $0.isLetter || $0.isNumber }.count
        let ratio = Double(alphanumericCount) / Double(line.count)

        return ratio < 0.4 // 60%+ non-alphanumeric
    }

    /// Check if line has meaningful content (at least 6 alphanumeric chars and 1 letter)
    private static func hasMeaningfulContent(_ line: String) -> Bool {
        let alphanumericCount = line.filter { $0.isLetter || $0.isNumber }.count
        let letterCount = line.filter { $0.isLetter }.count

        return alphanumericCount >= 6 && letterCount >= 1
    }

    /// Collapse multiple whitespace characters to single spaces
    private static func collapseWhitespace(_ text: String) -> String {
        let components = text.components(separatedBy: .whitespaces)
        return components.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
