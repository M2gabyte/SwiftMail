# SimpleMail iOS - Architecture Documentation

## Overview

SimpleMail is a native iOS email client built with SwiftUI and SwiftData, designed for Gmail integration with 120fps scroll performance, offline support, and Apple Intelligence integration.

## Tech Stack

| Component | Technology |
|-----------|------------|
| UI Framework | SwiftUI (iOS 17+) |
| Data Persistence | SwiftData |
| State Management | @Observable, @StateObject, @Published |
| Networking | URLSession + async/await |
| Authentication | OAuth 2.0 with PKCE via ASWebAuthenticationSession |
| Background Tasks | BGTaskScheduler |
| Notifications | UNUserNotificationCenter |
| Security | Keychain Services |

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

**Actor-based thread safety:**
```swift
actor GmailService {
    static let shared = GmailService()
    // All methods are thread-safe
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

**State Management:**
```swift
@MainActor
class InboxViewModel: ObservableObject {
    @Published var emails: [Email] = []
    @Published var scope: InboxScope = .all
    @Published var activeFilter: InboxFilter?
    @Published var currentMailbox: Mailbox = .inbox
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

### List Performance

- `LazyVStack` for large email lists
- Reusable `EmailRow` components
- Batch API requests (3 concurrent)
- Pagination (50 emails per page)

### Memory Management

- SwiftData auto-cleanup
- Attachment cache eviction
- WebView reuse in threads

### Network

- Request deduplication
- Token caching (1-hour expiry)
- Offline-first with cache

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
*Architecture version: 1.0*
