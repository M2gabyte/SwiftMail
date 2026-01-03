# Email Preview Parser - Premium Implementation

## Overview

The `EmailPreviewParser` is a sophisticated email content parser designed to transform raw email previews into clean, meaningful text that users actually want to read. It strips away all the technical boilerplate, forwarded message headers, signatures, and quoted content to show only the human-written response.

## Why This Matters

**The Problem:**
- Raw email previews show users database-level content: "---------- Forwarded message ---------", "On Jan 1, 2024 John wrote:", "Sent from my iPhone"
- This makes the inbox feel unpolished and forces users to mentally parse through noise
- Premium email apps feel intelligent because they do this work for the user

**The Solution:**
- Intelligent parsing that detects and removes all boilerplate
- Smart extraction of the first meaningful sentence(s)
- Context-aware content filtering

## Features

### 1. Forwarded Message Detection
Strips all common forwarded message patterns:
- `---------- Forwarded message ---------`
- `Begin forwarded message:`
- `--- Forwarded message ---`
- Automatically detects forwarded blocks even without explicit markers

**Example:**
```
Input:  "FYI - see below. ---------- Forwarded message --------- From: john@example.com"
Output: "FYI - see below."
```

### 2. Reply Attribution Removal
Removes reply context lines that add no value:
- `On Mon, Jan 1, 2024 at 3:00 PM John Doe <john@example.com> wrote:`
- `John Doe wrote:`
- Reply headers (`From:`, `To:`, `Subject:`)

**Example:**
```
Input:  "On Jan 1, 2024 Jane wrote:\n\nI agree with your proposal."
Output: "I agree with your proposal."
```

### 3. Signature Block Stripping
Intelligently removes email signatures:
- RFC standard signature delimiter (`--`)
- Common sign-offs: "Best regards", "Thanks", "Cheers", "Sincerely"
- Device signatures: "Sent from my iPhone", "Get Outlook for iOS"

**Example:**
```
Input:  "See you tomorrow.\n\nBest regards,\nJohn Doe\nCEO, Example Corp"
Output: "See you tomorrow."
```

### 4. Quote Marker Removal
Strips quoted/replied content markers:
- `>` (email quote markers)
- `|` (pipe quotes)
- Stops parsing when quotes are encountered to show only new content

**Example:**
```
Input:  "That's a great idea.\n\n> Previous message\n> More quoted text"
Output: "That's a great idea."
```

### 5. Smart Content Extraction
- Removes prefixes like "Fwd:", "Re:", "Reply:"
- Extracts the first 1-3 meaningful sentences
- Caps preview length at ~150 characters
- Normalizes whitespace (collapses spaces, removes excess newlines)

## Implementation

### File Structure
```
SimpleMail/Sources/Utils/EmailPreviewParser.swift
SimpleMail/Tests/EmailPreviewParserTests.swift
```

### Integration Point
The parser is integrated into `GmailService.swift` at the `cleanPreviewText()` function:

```swift
private nonisolated func cleanPreviewText(_ text: String) -> String {
    var cleaned = decodeHTMLEntities(text)
    // ... HTML and MIME stripping ...

    // Premium parsing: strip forwarded headers, signatures, and extract meaningful content
    cleaned = EmailPreviewParser.extractMeaningfulPreview(from: cleaned)

    return cleaned
}
```

### API

#### Main Method
```swift
static func extractMeaningfulPreview(from text: String) -> String
```

**Parameters:**
- `text`: Raw email snippet or body text

**Returns:**
- Clean, meaningful preview text with all boilerplate removed

### Processing Pipeline

The parser uses a multi-stage pipeline:

1. **Strip Forwarded Blocks** - Remove all forwarded message markers and content
2. **Strip Reply Attributions** - Remove "On [date] wrote:" lines
3. **Strip Signature Blocks** - Remove signatures and sign-offs
4. **Strip Quote Markers** - Remove quoted/replied content
5. **Normalize Whitespace** - Clean up spacing and newlines
6. **Extract Meaningful Content** - Get first sentences, cap length

Each stage is independent and composable, making the parser maintainable and testable.

## Testing

The implementation includes comprehensive test coverage for all edge cases:

- ✅ Forwarded messages with various formats
- ✅ Reply attributions (simple and complex)
- ✅ RFC signatures and common sign-offs
- ✅ Quote markers (> and |)
- ✅ Prefix removal (Fwd:, Re:)
- ✅ Complex real-world scenarios
- ✅ Edge cases (empty, whitespace-only, short messages)
- ✅ Whitespace normalization

**Test Suite:** `SimpleMail/Tests/EmailPreviewParserTests.swift`

Run tests:
```bash
xcodebuild test \
  -project SimpleMail.xcodeproj \
  -scheme SimpleMail \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SimpleMailTests/EmailPreviewParserTests
```

## Examples

### Example 1: Forwarded Email
```swift
let input = """
FYI - please review.

---------- Forwarded message ---------
From: john@example.com
Date: Mon, Jan 1, 2024
Subject: Q4 Report
"""

let output = EmailPreviewParser.extractMeaningfulPreview(from: input)
// Output: "FYI - please review."
```

### Example 2: Reply with Signature
```swift
let input = """
On Jan 1, 2024 at 10:00 AM Jane wrote:

Yes, I'll be at the meeting.

Thanks,
Jane
Sent from my iPhone
"""

let output = EmailPreviewParser.extractMeaningfulPreview(from: input)
// Output: "Yes, I'll be at the meeting."
```

### Example 3: Quoted Reply
```swift
let input = """
I agree with your proposal.

> On Mon, Jan 1 John wrote:
> What do you think about moving forward?
"""

let output = EmailPreviewParser.extractMeaningfulPreview(from: input)
// Output: "I agree with your proposal."
```

## Performance Considerations

- **Stateless Design**: All methods are static with no shared state
- **Regex Efficiency**: Uses optimized regex patterns with minimal backtracking
- **Single Pass**: Each stage processes text once without multiple iterations
- **Memory Efficient**: Works on string slices where possible, minimal allocations
- **Thread Safe**: Can be called from any thread/actor context

## Design Principles

1. **Conservative Processing**: When in doubt, preserve content rather than strip it
2. **Context-Aware**: Signatures only stripped from the latter portion of emails
3. **Human-Focused**: Optimized for human readability, not technical accuracy
4. **Fail-Safe**: Never crashes on malformed input, always returns valid string
5. **Testable**: Each stage is independently testable and composable

## Future Enhancements

Potential improvements for future iterations:

- Machine learning model for signature detection
- Language-specific signature patterns (non-English)
- Thread-aware parsing (detect conversation boundaries)
- Attachment mention extraction ("Please find attached...")
- Meeting invitation detection
- Action item detection ("Please review by...")

## Impact

**Before:**
```
"---------- Forwarded message --------- From: john@example.com Date: Mon..."
```

**After:**
```
"Please review the Q4 report by Friday."
```

This transformation makes the inbox feel premium and intelligent, doing the cognitive work for the user instead of forcing them to parse raw database content.

## Maintainability

The parser is designed for long-term maintainability:

- Clear separation of concerns (one function per pattern type)
- Comprehensive documentation
- Extensive test coverage
- No external dependencies
- Pure Swift implementation
- Follows Swift API design guidelines

---

**Created:** January 3, 2026
**Author:** Claude Code
**Version:** 1.0
