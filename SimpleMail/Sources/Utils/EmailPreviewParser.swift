import Foundation

/// Premium email preview parser that strips forwarded headers, signatures, and boilerplate
/// to show only the meaningful content in inbox previews.
///
/// This parser ensures the inbox feels intelligent by hiding technical details and
/// showing users the actual human-written content they care about.
enum EmailPreviewParser {

    // MARK: - Public API

    /// Extract a clean, meaningful preview from email text
    /// - Parameter text: Raw email snippet or body text
    /// - Returns: The first meaningful sentence(s) without boilerplate
    static func extractMeaningfulPreview(from text: String) -> String {
        guard !text.isEmpty else { return "" }

        var cleaned = text

        // Step 1: Strip forwarded message blocks
        cleaned = stripForwardedBlocks(from: cleaned)

        // Step 2: Strip reply attribution lines
        cleaned = stripReplyAttributions(from: cleaned)

        // Step 3: Strip signature blocks
        cleaned = stripSignatureBlocks(from: cleaned)

        // Step 4: Strip quote markers (>, |)
        cleaned = stripQuoteMarkers(from: cleaned)

        // Step 5: Normalize whitespace
        cleaned = normalizeWhitespace(cleaned)

        // Step 6: Extract first meaningful sentence(s)
        cleaned = extractFirstMeaningfulContent(from: cleaned)

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Forwarded Message Stripping

    /// Strip forwarded message blocks
    /// Patterns:
    /// - "---------- Forwarded message ---------"
    /// - "Begin forwarded message:"
    /// - "--- Forwarded message ---"
    private static func stripForwardedBlocks(from text: String) -> String {
        var result = text

        // Pattern 1: ---------- Forwarded message ---------
        let forwardedPattern1 = "(?i)-+\\s*forwarded message\\s*-+.*"
        result = result.replacingOccurrences(of: forwardedPattern1, with: "", options: .regularExpression)

        // Pattern 2: Begin forwarded message:
        let forwardedPattern2 = "(?i)(begin forwarded message|forwarded message):.*"
        result = result.replacingOccurrences(of: forwardedPattern2, with: "", options: .regularExpression)

        // Pattern 3: --- Forwarded message --- (with optional dashes)
        let forwardedPattern3 = "(?i)-+\\s*forwarded\\s+-+.*"
        result = result.replacingOccurrences(of: forwardedPattern3, with: "", options: .regularExpression)

        // Pattern 4: Remove everything after a forwarded delimiter
        // If we find a forwarded block, take only the content before it
        let lines = result.components(separatedBy: .newlines)
        var cleanedLines: [String] = []
        var hitForwardedBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            // Check if this line starts a forwarded block
            if lower.contains("forwarded message") ||
               lower.hasPrefix("from:") && cleanedLines.isEmpty && trimmed.count < 100 ||
               (lower.hasPrefix("date:") && cleanedLines.count < 3) {
                hitForwardedBlock = true
                break
            }

            if !hitForwardedBlock {
                cleanedLines.append(line)
            }
        }

        return cleanedLines.joined(separator: "\n")
    }

    // MARK: - Reply Attribution Stripping

    /// Strip reply attribution lines like "On [Date], [Name] wrote:"
    /// Patterns:
    /// - "On Mon, Jan 1, 2024 at 3:00 PM John Doe <john@example.com> wrote:"
    /// - "On 01/01/2024, John Doe wrote:"
    /// - "John Doe <john@example.com> wrote:"
    private static func stripReplyAttributions(from text: String) -> String {
        var result = text

        // Pattern 1: "On [date/time] [name] wrote:"
        let onDateWrotePattern = "(?im)^\\s*on\\s+.{1,100}\\s+wrote:\\s*$"
        result = result.replacingOccurrences(of: onDateWrotePattern, with: "", options: .regularExpression)

        // Pattern 2: "[Name] <email> wrote:" or "[Name] wrote:"
        let nameWrotePattern = "(?im)^\\s*.{1,80}\\s+wrote:\\s*$"
        result = result.replacingOccurrences(of: nameWrotePattern, with: "", options: .regularExpression)

        // Pattern 3: Common reply headers that appear at the start
        let replyHeaderPattern = "(?im)^\\s*(from|to|sent|date|subject):\\s*.+$"
        result = result.replacingOccurrences(of: replyHeaderPattern, with: "", options: .regularExpression)

        // Pattern 4: Remove lines that are just "From:" "To:" etc. followed by email addresses
        let emailHeaderPattern = "(?im)^\\s*(from|to|cc|sent|date|subject):\\s*[^\\n]{0,150}$"
        result = result.replacingOccurrences(of: emailHeaderPattern, with: "", options: .regularExpression)

        return result
    }

    // MARK: - Signature Block Stripping

    /// Strip signature blocks
    /// Common patterns:
    /// - Lines starting with "-- " (RFC standard)
    /// - "Best regards", "Regards", "Cheers", "Thanks"
    /// - "Sent from my iPhone/Android"
    private static func stripSignatureBlocks(from text: String) -> String {
        var lines = text.components(separatedBy: .newlines)

        // Find the signature delimiter (-- ) or common signature phrases
        var signatureIndex: Int?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            // RFC signature delimiter
            if trimmed == "--" || trimmed.hasPrefix("-- ") {
                signatureIndex = index
                break
            }

            // Common signature phrases (only if in the last 40% of the message)
            let threshold = Int(Double(lines.count) * 0.6)
            if index >= threshold {
                if lower.hasPrefix("best regards") ||
                   lower.hasPrefix("kind regards") ||
                   lower.hasPrefix("regards,") ||
                   lower.hasPrefix("best,") ||
                   lower.hasPrefix("thanks,") ||
                   lower.hasPrefix("thank you,") ||
                   lower.hasPrefix("cheers,") ||
                   lower.hasPrefix("sincerely,") ||
                   lower.hasPrefix("sent from my") ||
                   lower.hasPrefix("get outlook for") ||
                   lower.hasPrefix("download outlook") {
                    signatureIndex = index
                    break
                }
            }
        }

        // Trim everything after signature
        if let idx = signatureIndex {
            lines = Array(lines[..<idx])
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Quote Marker Stripping

    /// Strip quote markers (>, |, etc.)
    /// These indicate quoted/replied-to content
    private static func stripQuoteMarkers(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var cleanedLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip lines that are purely quote markers
            if trimmed.hasPrefix(">") || trimmed.hasPrefix("|") {
                // If we haven't found meaningful content yet, skip
                if cleanedLines.isEmpty {
                    continue
                }
                // If we found meaningful content, this is quoted reply - stop here
                break
            }

            cleanedLines.append(line)
        }

        return cleanedLines.joined(separator: "\n")
    }

    // MARK: - Content Extraction

    /// Extract the first meaningful sentence(s) from cleaned text
    /// Returns the first 1-3 sentences that contain actual content
    private static func extractFirstMeaningfulContent(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Remove common prefixes that aren't meaningful
        var cleaned = trimmed
        let prefixes = ["fwd:", "fw:", "re:", "reply:", "forward:"]
        for prefix in prefixes {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        // Split into sentences (approximate)
        let sentences = cleaned.components(separatedBy: .newlines)
            .joined(separator: " ")
            .split(whereSeparator: { char in
                // Split on newlines or sentence boundaries
                char.isNewline
            })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 10 } // Filter out tiny fragments

        if sentences.isEmpty {
            // If no clear sentences, return the first reasonable chunk
            let words = cleaned.split(separator: " ")
            if words.count > 20 {
                return words.prefix(20).joined(separator: " ") + "..."
            }
            return cleaned
        }

        // Return first 1-2 sentences, but cap at ~150 chars for preview
        var preview = ""
        for sentence in sentences.prefix(3) {
            let potentialPreview = preview.isEmpty ? sentence : preview + " " + sentence
            if potentialPreview.count > 150 {
                break
            }
            preview = potentialPreview

            // If we have a good amount of content, stop
            if preview.count > 80 {
                break
            }
        }

        return preview.isEmpty ? sentences[0] : preview
    }

    // MARK: - Whitespace Normalization

    /// Normalize whitespace (collapse multiple spaces, remove excessive newlines)
    private static func normalizeWhitespace(_ text: String) -> String {
        var result = text

        // Collapse multiple newlines into at most one blank line
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        // Collapse multiple spaces into single space
        result = result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)

        // Remove spaces at the start of lines
        result = result.replacingOccurrences(of: "(?m)^\\s+", with: "", options: .regularExpression)

        // Remove spaces at the end of lines
        result = result.replacingOccurrences(of: "(?m)\\s+$", with: "", options: .regularExpression)

        return result
    }
}
