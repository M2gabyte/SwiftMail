# Reply AI Feature Specification

## Overview

Reply AI provides **context-native, intent-based reply suggestions** when replying to emails. Unlike generic "AI Draft" flows, Reply AI analyzes *what the email is actually asking for* and provides actionable responses—including recognizing when no reply is needed.

## Core Principles

1. **Intent over tone** - Suggestions are based on what the email asks for, not generic positive/neutral/declining tones
2. **No reply is often the right answer** - Survey requests, FYIs, and info-sharing often don't need replies
3. **Blanks where needed** - Time-sensitive replies get `[[P1]]` `[[P2]]` placeholders for user input
4. **Voice profile enforcement** - Replies match the user's natural writing style, never corporate-speak

## Features

### 1. Recommended Action (Top Section)

When analysis determines no reply is needed:
- **"Take the survey—no reply needed"** with "Open Survey" deep-link button
- **"FYI only—no reply expected"** with "Archive" button
- User can still reply if they want (suggestions shown below)

### 2. Intent-Based Suggestions (2-3)

Instead of tone presets, suggestions match the email's actual request:

| Email Intent | Suggestion 1 | Suggestion 2 | Suggestion 3 |
|--------------|--------------|--------------|--------------|
| Survey Request | "I'll fill it out" | "Happy to chat instead [[P1]] [[P2]]" | — |
| Meeting Request | "Works for me" | "Suggest times [[P1]] [[P2]]" | "Can't make it" |
| Question | "Here's the answer [[P1]]" | "Let me check" | — |
| FYI/Info Sharing | "Got it, thanks" | — | — |
| Follow-up | "Here's an update [[P1]]" | "Still working on it" | — |
| Introduction | "Nice to meet you" | "Let's connect—[[P1]] work?" | — |
| Action Request | "On it" | "Done" | — |

### 3. Reply with Blanks

When a suggestion has `[[P1]]` or `[[P2]]` placeholders:
1. Tap shows "Complete Reply" sheet
2. Fields for each placeholder with context-aware labels:
   - Meeting times → "First time option" / "Second time option"
   - Questions → "Your response"
3. Live preview updates as user types
4. Insert button enabled when all blanks filled

### 4. Voice Profile (On-Device Learning)

Learned from the user's sent mail:
- **Greeting format**: "Hi {name}," vs "Hey {name}," vs "Hello,"
- **Sign-off**: "Thanks" vs "Best," vs "Cheers,\nMark"
- **Brevity**: Average word count (enforced as max)
- **Punctuation**: Exclamation mark usage
- **Banned words**: "thrilled", "commendable", "delighted", "appreciate your", "kindly", etc.

## Architecture

### Files

```
SimpleMail/Sources/
├── Services/
│   ├── VoiceProfileManager.swift   # On-device style learner
│   └── ReplyAIService.swift        # Intent detection + reply generation
├── Views/
│   └── ReplyAISheet.swift          # UI (RecommendedActionRow, SuggestionRow, FillBlanksSheet)
```

### Data Models

```swift
// What the email is asking for
enum EmailIntent: String {
    case surveyRequest      // Fill out a survey/feedback
    case meetingRequest     // Schedule a meeting/call
    case questionAsking     // Asking a direct question
    case infoSharing        // FYI, no response expected
    case actionRequest      // Asking user to do something specific
    case followUp           // Following up on something
    case introduction       // Intro/networking email
    case other
}

// Extracted link for deep-linking
struct ExtractedLink {
    let url: String
    let label: String       // "survey", "calendar", "document"
    let isActionable: Bool
}

// Recommended action
enum RecommendedAction {
    case noReplyNeeded(reason: String, links: [ExtractedLink])
    case replyRecommended(reason: String)
}

// A suggestion with optional blanks
struct SuggestedReply {
    let intent: String      // Action title: "I'll fill it out"
    let body: String
    let hasBlanks: Bool     // Has [[P1]], [[P2]] placeholders
}

// Full result
struct ReplyAIResult {
    let emailIntent: EmailIntent
    let recommendedAction: RecommendedAction
    let suggestedReplies: [SuggestedReply]
    let extractedLinks: [ExtractedLink]
}
```

### Context (Input)

```swift
struct ReplyAIContext {
    let accountEmail: String?
    let userName: String
    let senderName: String
    let subject: String
    let latestInboundPlainText: String
    let latestInboundHTML: String?  // For link extraction
}
```

## Intent Detection

Links and text patterns determine intent:

| Pattern | Detected Intent |
|---------|-----------------|
| survey/typeform/forms.gle link, "fill out", "feedback" | surveyRequest |
| calendly/cal.com link, "schedule", "meeting", "call", "available" | meetingRequest |
| "?" with "could you", "can you", "would you" | questionAsking |
| "FYI", "update", "just wanted to let you know" | infoSharing |
| "following up", "checking in" | followUp |
| "my name is", "reaching out", "introduce" | introduction |
| "please" + "send"/"provide"/"review"/"confirm" | actionRequest |

## Link Extraction

URLs are extracted and classified:
- **survey**: typeform, forms.gle, surveymonkey, airtable.com/shr, or context mentions "survey"
- **calendar**: calendly, cal.com, doodle
- **document**: docs.google, notion, dropbox, drive.google
- **unsubscribe**: opt-out links (not actionable)

## Voice Profile Enforcement

### Strict Rules in Prompts

```
STRICT STYLE RULES:
- Start with: Hi Amol,
- End with: Thanks
- MAX 40 words total (be brief!)
- NO exclamation marks
- Sound like a real person, not a corporate assistant
- NEVER use: thrilled, commendable, delighted, appreciate your, kindly, rest assured
```

### Banned Words List

```swift
private let bannedWords = [
    "commendable", "thrilled", "delighted", "esteemed", "appreciate your",
    "I wanted to reach out", "circle back", "synergy", "leverage", "utilize",
    "per our conversation", "as per", "pursuant to", "aforementioned",
    "please do not hesitate", "at your earliest convenience", "kindly",
    "rest assured", "I trust this", "please be advised"
]
```

## UI Behavior

### Entry Point
- **Reply/Reply-All mode**: Tap sparkles (✨) button in compose toolbar
- **New compose mode**: Sparkles shows AI Draft (unchanged)

### ReplyAISheet Layout

```
┌────────────────────────────────────┐
│         AI Reply                   │
├────────────────────────────────────┤
│ ✨ Recommended                      │
│ ┌────────────────────────────────┐ │
│ │ ✓ Take the survey—no reply     │ │
│ │   needed                       │ │
│ │ [Open Survey] [Archive]        │ │
│ └────────────────────────────────┘ │
├────────────────────────────────────┤
│ 💬 Or reply anyway                 │
│ ┌────────────────────────────────┐ │
│ │ 👍 I'll fill it out            │ │
│ │ Hi Amol,                       │ │
│ │ Will do.                       │ │
│ │ Thanks                         │ │
│ └────────────────────────────────┘ │
│ ┌────────────────────────────────┐ │
│ │ 📅 Happy to chat instead [Fill]│ │
│ │ Hi Amol,                       │ │
│ │ Happy to chat if that's more...│ │
│ └────────────────────────────────┘ │
└────────────────────────────────────┘
```

### Fill Blanks Sheet

```
┌────────────────────────────────────┐
│ Cancel   Complete Reply    Insert  │
├────────────────────────────────────┤
│ Preview                            │
│ Hi Amol,                           │
│ Happy to chat if that's more       │
│ useful. [[P1]] or [[P2]] work?     │
│ Thanks                             │
├────────────────────────────────────┤
│ Fill in the blanks                 │
│ 🕐 First time option               │
│ [Tuesday 2pm________________]      │
│ 🕐 Second time option              │
│ [Thursday morning___________]      │
└────────────────────────────────────┘
```

## Error Handling

- **Device without Apple Intelligence**: Shows fallback suggestions (still intent-based)
- **AI timeout (30s)**: Returns fallback suggestions
- **Empty email body**: Shows error with retry button

## Privacy

- **On-device only**: Voice profile computed locally
- **No telemetry**: Sent emails never transmitted
- **Per-account isolation**: Separate profiles per account
- **Link extraction**: URLs extracted locally, only opened when user taps

## Testing Checklist

- [ ] Survey email → Shows "No reply needed" with "Open Survey" button
- [ ] Meeting request → Shows time suggestion with [[P1]] [[P2]] blanks
- [ ] FYI email → Shows "No reply expected"
- [ ] Tap "Open Survey" → Opens link and dismisses compose
- [ ] Tap suggestion with blanks → Shows Fill Blanks sheet
- [ ] Fill blanks → Preview updates live
- [ ] Insert filled reply → Prepends to compose body
- [ ] No corporate-speak words in any suggestion
- [ ] Suggestions match user's greeting/sign-off style
- [ ] Works when Apple Intelligence unavailable (fallbacks)
