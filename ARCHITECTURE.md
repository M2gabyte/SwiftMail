# SimpleMail iOS - Architecture Documentation

## Overview

SimpleMail is a native iOS email client built with SwiftUI and SwiftData, designed for Gmail integration with 120fps scroll performance, offline support, and Apple Intelligence integration.

## Tech Stack

| Component | Technology |
|-----------|------------|
| UI Framework | SwiftUI (iOS 17+) |
| Data Persistence | SwiftData |
| State Management | @Observable macro (iOS 17+) |
| Networking | URLSession + async/await |
| Authentication | OAuth 2.0 with PKCE via ASWebAuthenticationSession |
| Background Tasks | BGTaskScheduler |
| Notifications | UNUserNotificationCenter |
| Security | Keychain Services |
| Logging | OSLog (unified logging) |
| Concurrency | Swift actors + structured concurrency |

## Project Structure

```
SimpleMail/
├── Sources/
│   ├── SimpleMailApp.swift          # App entry point, scene management
│   ├── Info.plist                   # App configuration
│   ├── SimpleMail.entitlements      # Keychain, background modes
│   │
│   ├── Models/
│   │   ├── Email.swift              # Core email models (SwiftData)
│   │   └── Briefing.swift           # Briefing/digest models
│   │
│   ├── ViewModels/
│   │   └── InboxViewModel.swift     # Main inbox state management
│   │
│   ├── Views/
│   │   ├── InboxView.swift          # Main inbox UI
│   │   ├── EmailDetailView.swift    # Thread/conversation view
│   │   ├── ComposeView.swift        # Email composition
│   │   ├── SearchView.swift         # Search interface
│   │   ├── SettingsView.swift       # Settings & Gmail sync
│   │   ├── BriefingScreenView.swift # Daily digest view
│   │   ├── SnoozePickerSheet.swift  # Snooze time picker
│   │   ├── AttachmentViewer.swift   # QuickLook attachment preview
│   │   └── BatchOperations.swift    # Multi-select & batch actions
│   │
│   ├── Services/
│   │   ├── AuthService.swift        # OAuth authentication
│   │   ├── GmailService.swift       # Gmail API client
│   │   ├── BackgroundSync.swift     # Background refresh
│   │   ├── SnoozeManager.swift      # Snooze persistence
│   │   └── EmailCache.swift         # Offline caching
│   │
│   ├── Engine/
│   │   └── BriefingEngine.swift     # Email categorization/briefing
│   │
│   └── Assets.xcassets/             # Images, colors, app icon
│
└── SimpleMail.xcodeproj/
```

## Core Components

### 1. Authentication (AuthService.swift)

**OAuth 2.0 PKCE Flow:**
```
User taps "Sign In"
    ↓
Generate code_verifier (random 32 bytes)
    ↓
Create code_challenge = SHA256(code_verifier)
    ↓
Open ASWebAuthenticationSession
    ↓
User authenticates with Google
    ↓
Receive authorization code
    ↓
Exchange code + verifier for tokens
    ↓
Store tokens in Keychain
```

**Key Features:**
- Automatic token refresh when expired (5-minute buffer)
- Multi-account support
- Secure Keychain storage
- Thread-safe with `@MainActor`

### 2. Gmail Service (GmailService.swift)

**Actor-based thread safety with protocol abstraction:**
```swift
// Protocol for testability/mocking
protocol GmailAPIProvider: Sendable {
    func fetchInbox(...) async throws -> (emails: [Email], nextPageToken: String?)
    func sendEmail(...) async throws -> String
    // ... other methods
}

actor GmailService: GmailAPIProvider {
    static let shared = GmailService()
    // All methods are thread-safe
}
```

**Type-Safe MIME Builder (Result Builder Pattern):**
```swift
@resultBuilder
struct MIMEBuilder { ... }

struct MIMEMessage {
    @MIMEBuilder
    private var headers: [MIMEComponent] {
        MIMEHeader(name: "To", value: to.joined(separator: ", "))
        if !cc.isEmpty {
            MIMEHeader(name: "Cc", value: cc.joined(separator: ", "))
        }
        MIMEHeader(name: "Subject", value: subject)
        MIMEHeader(name: "MIME-Version", value: "1.0")
    }

    func encoded() -> String {
        Base64URL.encode(build().data(using: .utf8)!)
    }
}
```

**Base64URL Utilities:**
```swift
enum Base64URL {
    static func encode(_ data: Data) -> String
    static func decode(_ encoded: String) -> String?
    static func decodeToData(_ encoded: String) -> Data?
}
```

**API Methods:**
| Method | Endpoint | Purpose |
|--------|----------|---------|
| `fetchInbox()` | GET /messages | List emails with pagination |
| `fetchThread()` | GET /threads/{id} | Get conversation |
| `sendEmail()` | POST /messages/send | Send with MIME |
| `archive()` | POST /messages/{id}/modify | Remove INBOX label |
| `markAsRead()` | POST /messages/{id}/modify | Remove UNREAD label |
| `star()` | POST /messages/{id}/modify | Add STARRED label |
| `trash()` | POST /messages/{id}/trash | Move to trash |
| `reportSpam()` | POST /messages/{id}/modify | Add SPAM label |
| `fetchAttachment()` | GET /attachments/{id} | Download attachment |
| `search()` | GET /messages?q= | Gmail search syntax |

**Rate Limiting:**
- Batched requests (3 concurrent max)
- 20-second timeout per request
- Automatic retry on 429

### 3. Data Models (Email.swift)

**SwiftData Models:**
```swift
@Model
final class Email {
    @Attribute(.unique) var id: String
    var threadId: String
    var subject: String
    var from: String
    var date: Date
    var isUnread: Bool
    var isStarred: Bool
    var labelIds: [String]
    // Bulk detection headers
    var listUnsubscribe: String?
}

@Model
final class EmailDetail {
    // Full email with body, to, cc
}

@Model
final class SnoozedEmail {
    var snoozeUntil: Date
}
```

### 4. Inbox View Model (InboxViewModel.swift)

**State Management with @Observable (iOS 17+):**
```swift
@MainActor
@Observable
final class InboxViewModel {
    // No @Published needed - automatic observation
    var emails: [Email] = []
    var scope: InboxScope = .all
    var activeFilter: InboxFilter? = nil
    var currentMailbox: Mailbox = .inbox
    var isLoading = false
    var error: Error?
}
```

**Usage in Views:**
```swift
struct InboxView: View {
    @State private var viewModel = InboxViewModel()  // Not @StateObject

    var body: some View {
        List(viewModel.emails) { email in ... }
    }
}
```

**Optimistic Updates:**
1. Update UI immediately
2. Make API call in background
3. Rollback on failure

**Filtering Pipeline:**
```
emails
  → applyFilters(scope: all/people)
  → applyFilters(filter: unread/needsReply/etc)
  → groupEmailsByDate(today/yesterday/thisWeek/earlier)
  → display as sections
```

### 5. Offline Caching (EmailCache.swift)

**Strategy:**
- Cache on every fetch
- Serve cached data immediately
- Refresh in background
- Handle conflicts with server truth

**Cache Operations:**
```swift
EmailCacheManager.shared.cacheEmails(emails)      // Save
EmailCacheManager.shared.loadCachedEmails()       // Load
EmailCacheManager.shared.searchCachedEmails(q)    // Offline search
EmailCacheManager.shared.clearCache()             // Clear all
```

### 6. Background Sync (BackgroundSync.swift)

**BGTaskScheduler Tasks:**
| Task ID | Type | Interval | Purpose |
|---------|------|----------|---------|
| `com.simplemail.app.sync` | AppRefresh | 15 min | Fetch new emails |
| `com.simplemail.app.notification` | Processing | 5 min | Check for notifications |

**Sync Flow:**
```
App enters background
    ↓
Schedule BGAppRefreshTask
    ↓
System wakes app (opportunistic)
    ↓
Fetch emails → Cache to SwiftData
    ↓
Check for new unread → Send notification
    ↓
Schedule next task
```

### 7. Snooze Manager (SnoozeManager.swift)

**Snooze Flow:**
```
User selects snooze time
    ↓
Archive email via Gmail API
    ↓
Save SnoozedEmail to SwiftData
    ↓
Schedule local notification
    ↓
Timer checks every minute
    ↓
When expired: Unarchive + notify
```

## UI Architecture

### Navigation Flow

```
ContentView
├── SignInView (unauthenticated)
└── MainTabView (authenticated)
    ├── InboxTab
    │   └── InboxView
    │       ├── StickyInboxHeader
    │       ├── EmailListView
    │       └── → EmailDetailView (push)
    │           ├── EmailMessageCard (expandable)
    │           ├── AttachmentsListView
    │           └── → ComposeView (sheet)
    ├── BriefingScreenView
    └── SettingsView
        ├── VacationResponderView
        ├── LabelsManagementView
        ├── FiltersManagementView
        └── SnoozedEmailsView
```

### Key UI Components

**InboxView:**
- Sticky header with scope toggle + filter pills
- Pull-to-refresh
- Infinite scroll pagination
- Swipe actions (archive, trash, star, snooze, read)
- Multi-select batch mode

**EmailDetailView:**
- Thread view with expandable messages
- WebView for HTML email body
- Attachment previews with QuickLook
- Action footer (reply, reply all, forward, archive)

**ComposeView:**
- FlowLayout for recipient chips
- Auto-save drafts
- Reply threading with In-Reply-To headers

## Data Flow

### Email Fetch Cycle

```
┌─────────────────┐
│  InboxViewModel │
└────────┬────────┘
         │ loadEmails()
         ▼
┌─────────────────┐     ┌─────────────────┐
│  GmailService   │────▶│  EmailCache     │
│  (actor)        │     │  (SwiftData)    │
└────────┬────────┘     └─────────────────┘
         │
         ▼
┌─────────────────┐
│  Gmail REST API │
└─────────────────┘
```

### Action Flow (e.g., Archive)

```
User swipes to archive
         │
         ▼
┌─────────────────────────────────┐
│ 1. Optimistic: Remove from UI  │
│ 2. Haptic feedback             │
│ 3. Update filter counts        │
└────────────────┬────────────────┘
                 │
                 ▼ (async)
┌─────────────────────────────────┐
│ GmailService.archive()          │
│   → POST /modify                │
│   → removeLabelIds: ["INBOX"]   │
└────────────────┬────────────────┘
                 │
         ┌───────┴───────┐
         ▼               ▼
    [Success]       [Failure]
         │               │
         │               ▼
         │      ┌─────────────────┐
         │      │ Rollback:       │
         │      │ Reload emails   │
         │      │ Show error      │
         │      └─────────────────┘
         ▼
┌─────────────────┐
│ Update cache    │
└─────────────────┘
```

## Security

### Keychain Storage

```swift
// Stored securely
- OAuth access tokens
- OAuth refresh tokens
- Account information

// Accessibility
kSecAttrAccessibleAfterFirstUnlock
```

### App Transport Security

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
    <!-- Only allow googleapis.com -->
</dict>
```

### Privacy

- On-device email processing (no cloud)
- Face ID lock option
- Remote image blocking
- No analytics or tracking

## Performance Optimizations

### List Performance (120fps target)

- `LazyVStack` for large email lists
- Reusable `EmailRow` components
- Batch API requests (3 concurrent)
- Pagination (50 emails per page)

**Cached DateFormatters (Critical for scroll performance):**
```swift
private enum DateFormatters {
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static let calendar = Calendar.current

    // Single call per cell - no allocations
    static func formatEmailDate(_ date: Date) -> String {
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return dateFormatter.string(from: date)
    }
}
```

### Memory Management

- SwiftData auto-cleanup
- Attachment cache eviction
- WebView reuse in threads
- Timer invalidation in `deinit`

### Network

- Request deduplication
- Token caching (1-hour expiry)
- Offline-first with cache

## Logging & Debugging

**OSLog Integration:**
```swift
import OSLog

private let logger = Logger(subsystem: "com.simplemail.app", category: "GmailService")

// Usage
logger.info("Fetching inbox: labels=\(labelIds), max=\(maxResults)")
logger.error("Failed to decode attachment data")
logger.warning("Rate limited on \(url.path)")
```

**Log Categories:**
| Category | Purpose |
|----------|---------|
| `GmailService` | API calls, responses, errors |
| `InboxViewModel` | State changes, filtering |
| `SnoozeManager` | Snooze scheduling, notifications |
| `AuthService` | OAuth flow, token refresh |
| `BackgroundSync` | Background task execution |

**Viewing Logs:**
```bash
# Console.app or:
log stream --predicate 'subsystem == "com.simplemail.app"' --level debug
```

## Background Capabilities

### Info.plist Configuration

```xml
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>processing</string>
    <string>remote-notification</string>
</array>
```

### Entitlements

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.simplemail.app</string>
</array>
```

## Testing Strategy

### Unit Tests
- GmailService API parsing
- Email filtering logic
- Date grouping
- PKCE code generation
- MIME message building
- Base64URL encoding/decoding

**Protocol-Based Mocking:**
```swift
// Mock implementation for tests
final class MockGmailService: GmailAPIProvider {
    var mockEmails: [Email] = []
    var shouldFail = false

    func fetchInbox(...) async throws -> (emails: [Email], nextPageToken: String?) {
        if shouldFail { throw GmailError.serverError(500) }
        return (mockEmails, nil)
    }
}

// Usage in tests
let mockService = MockGmailService()
mockService.mockEmails = [testEmail1, testEmail2]
let viewModel = InboxViewModel(gmailService: mockService)
```

### Integration Tests
- OAuth flow (mock)
- SwiftData persistence
- Background task scheduling

### UI Tests
- Navigation flows
- Swipe actions
- Pull-to-refresh
- Compose flow

## Future Enhancements

### Planned Features
- [ ] Apple Intelligence summarization
- [ ] Smart reply suggestions
- [ ] Undo send (30-second window)
- [ ] Account switching UI
- [ ] Widget support
- [ ] Watch app
- [ ] Mac Catalyst support

### API Extensions
- [ ] Gmail push notifications (FCM)
- [ ] Vacation responder API
- [ ] Filter creation API
- [ ] Label CRUD API

## Deployment

### Requirements
- iOS 17.0+
- Xcode 15+
- Google Cloud project with Gmail API enabled
- OAuth 2.0 client ID (iOS type)

### Configuration
1. Replace `clientId` in `AuthService.swift`
2. Update URL scheme in `Info.plist`
3. Add Google OAuth client to Google Cloud Console
4. Enable Gmail API in Google Cloud Console

---

*Last updated: December 2025*
*Architecture version: 1.1*

**Changelog:**
- v1.1: Added @Observable migration, MIME Result Builder, Base64URL utilities, OSLog integration, protocol-based testing
- v1.0: Initial architecture documentation
