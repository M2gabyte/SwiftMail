# SimpleMail iOS - Architecture Documentation

## Overview

SimpleMail is a native iOS email client built with SwiftUI and SwiftData, designed for Gmail integration with high‑performance scrolling, offline support, and Apple Intelligence integration.

## Tech Stack

| Component | Technology |
|-----------|------------|
| UI Framework | SwiftUI |
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
│   ├── SimpleMailApp.swift          # App entry point, scene management, graceful error handling
│   ├── Info.plist                   # App configuration, OAuth config
│   ├── SimpleMail.entitlements      # Keychain, background modes
│   │
│   ├── Config/
│   │   ├── Config.swift             # OAuth credentials from Info.plist
│   │   └── TimeoutConfig.swift      # Centralized timeout values
│   │
│   ├── Models/
│   │   ├── Email.swift              # Core email models (SwiftData)
│   │   ├── Briefing.swift           # Briefing/digest models
│   │   ├── InboxTab.swift           # All / Primary / Pinned tab enum
│   │   ├── PinnedTabOption.swift    # Pinned tab option (Other/Money/etc)
│   │   └── PrimaryRule.swift        # Primary tab rule toggles
│   │
│   ├── ViewModels/
│   │   ├── InboxViewModel.swift     # Inbox UI orchestration + actions
│   │   ├── InboxStore.swift         # Actor for inbox filtering + sectioning
│   │   ├── InboxViewState.swift     # Lightweight derived state for inbox UI
│   │   └── EmailSection.swift       # Shared section model (moved from InboxView)
│   │
│   ├── Views/
│   │   ├── InboxView.swift          # Main inbox UI
│   │   ├── EmailDetailView.swift    # Thread/conversation view
│   │   ├── ComposeView.swift        # Email composition
│   │   ├── SettingsView.swift       # Settings & Gmail sync
│   │   ├── PrimaryInboxRulesView.swift # Primary rule toggles UI
│   │   ├── PinnedTabSettingsView.swift # Pinned tab selection UI
│   │   ├── SnoozePickerSheet.swift  # Snooze time picker
│   │   ├── AttachmentViewer.swift   # QuickLook attachment preview
│   │   ├── BatchOperations.swift    # Multi-select & batch actions
│   │   ├── SmartAvatarView.swift    # Avatar with fallback chain
│   │   └── ErrorBanner.swift        # Reusable error display component
│   │
│   ├── Services/
│   │   ├── AuthService.swift        # OAuth authentication
│   │   ├── GmailService.swift       # Gmail API client
│   │   ├── PeopleService.swift      # Google People API (contacts)
│   │   ├── AvatarService.swift      # Avatar resolution + caching
│   │   ├── SummaryQueue.swift       # Precompute summary queue + throttling
│   │   ├── SummaryService.swift     # Summarization + fallbacks
│   │   ├── SummaryCache.swift       # Summary persistence (AccountDefaults)
│   │   ├── BrandRegistry.swift      # Brand domain registry (JSON-backed)
│   │   ├── DomainNormalizer.swift   # Email + domain normalization
│   │   ├── BackgroundSync.swift     # Background refresh + notifications
│   │   ├── SnoozeManager.swift      # Snooze persistence
│   │   ├── ScheduledSendManager.swift # Scheduled send queue
│   │   └── EmailCache.swift         # Offline caching
│   │
│   ├── Engine/
│   │   └── BriefingEngine.swift     # Email categorization/briefing
│   │
│   ├── Utils/
│   │   ├── JSONCoding.swift         # Shared JSON encoders/decoders
│   │   ├── Color+Hex.swift          # Hex string to Color utilities
│   │   ├── EmailFilters.swift       # Email classification (human/bulk detection)
│   │   ├── InboxPreferences.swift   # Primary/pinned preferences + notifications
│   │   ├── InboxFilterEngine.swift  # Pure inbox filtering + sectioning pipeline
│   │   └── NetworkRetry.swift       # Exponential backoff retry utility
│   │
│   ├── Resources/
│   │   └── brand_registry.json      # Domain registry data
│   │
│   └── Assets.xcassets/             # Images, colors, app icon
│
├── SimpleMailUITests/
│   ├── SimpleMailUITests.swift      # XCUITest UI automation tests
│   └── SimpleMailUITestsLaunchTests.swift  # Launch performance tests
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
- Multi-account support with atomic update pattern (race-condition safe)
- Secure Keychain storage via KeychainServiceSync with NSLock
- Thread-safe with `@MainActor`
- `MainActor.assumeIsolated` for safe nonisolated protocol callbacks
- HTTP status code validation on all API responses
- Comprehensive error handling (invalidResponse, userInfoFetchFailed, rateLimited)

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
struct MIMEHeaderBuilder {
    static func buildBlock(_ components: [MIMEHeader]...) -> [MIMEHeader] {
        components.flatMap { $0 }
    }
    static func buildOptional(_ component: [MIMEHeader]?) -> [MIMEHeader] {
        component ?? []
    }
    static func buildExpression(_ expression: MIMEHeader) -> [MIMEHeader] {
        [expression]
    }
}

struct MIMEHeader: Sendable {
    let name: String
    let value: String
    var rendered: String { "\(name): \(value)" }
}

struct MIMEMessage: Sendable {
    @MIMEHeaderBuilder
    private var headers: [MIMEHeader] {
        MIMEHeader(name: "To", value: to.joined(separator: ", "))
        if !cc.isEmpty {
            MIMEHeader(name: "Cc", value: cc.joined(separator: ", "))
        }
        MIMEHeader(name: "Subject", value: subject)
        MIMEHeader(name: "MIME-Version", value: "1.0")
    }

    func build() -> String {
        // Renders headers + body as RFC 2822 message
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

**Rate Limiting & Retry:**
- Batched requests (3 concurrent max)
- 20-second timeout per request
- Automatic retry on 429 via `NetworkRetry` utility

### 3. Summary Precompute Pipeline (SummaryQueue.swift / SummaryService.swift / SummaryCache.swift)

**Goal:** precompute summaries in the background so the detail view can display instantly, without draining battery.

**How it works (best‑practice mode):**
- **Foreground‑first:** enqueue candidates after inbox load; compute while app is active.
- **Batch + throttle:** max 10 summaries per hour (sliding 1‑hour window).
- **Battery guard:** skip if Low Power Mode is enabled or battery < 20%.
- **Priority ordering:** unread + starred + non‑bulk candidates first.
- **Skip short emails:** plain‑text length < ~350 chars are not summarized.
- **Per‑account opt‑out:** settings toggle disables precompute for that account.

**Data flow:**
1. InboxViewModel enqueues candidates after `loadEmails()`.
2. BackgroundSync (BGAppRefresh) enqueues candidates after syncing and caching emails.
2. SummaryQueue applies throttling + battery checks.
3. SummaryService generates summary:
   - Apple Intelligence when available.
   - Extractive fallback if AI unavailable.
4. SummaryCache persists summaries per messageId (AccountDefaults scoped).
5. EmailDetailView reads from cache first, falls back to on‑demand summarization.

**User control:**
- Settings → Smart Features: **“Precompute Summaries (Recommended)”** toggle.
- Settings → Smart Features: **“Aggressive Background Summaries”** toggle (BGProcessing task).

**Aggressive background processing (optional):**
- **BGProcessingTask** (`com.simplemail.app.summaries`) runs on iOS schedule.
- Loads cached inbox items per account and enqueues SummaryQueue.
- Requires network connectivity; respects the same throttling + battery guards.
- Enabled only when **Aggressive Background Summaries** is on.

**Threading / concurrency note:**
- SummaryQueue writes stats/timestamps on the main actor to avoid background publishing warnings.

### 4. Inbox Tabs + Preferences (InboxStore.swift / InboxPreferences.swift)

**Goal:** allow a user‑customizable Primary tab and a configurable third tab, while keeping counts consistent.

**Tabs:**
- **All**: all non‑blocked emails.
- **Primary**: rule‑based, user‑configurable inclusion.
- **Pinned**: a single user‑selected view (Other/Money/Deadlines/Needs Reply/Unread/Newsletters/People).

**Preferences storage:**
- `InboxPreferences` persists pinned tab selection and rule toggles in UserDefaults with **global scope** (`accountEmail: nil`) so Unified Inbox is consistent.
- Changes broadcast via `Notification.Name.inboxPreferencesDidChange`.

**Primary rules:**
- `PrimaryRule` defines the toggles and defaults (People/VIP/Security/Money/Deadlines enabled by default).
- `InboxStore.isPrimary(_:)` returns true if **any enabled rule** matches.

**Pinned tab:**
- `PinnedTabOption` defines the third tab label and filter predicate.
- `InboxStore.matchesPinned(_:)` maps the selected option to the appropriate predicate (e.g. money, deadlines, people).

**Filtering pipeline:**
1. Blocked senders removed.
2. Tab context applied (All / Primary / Pinned).
3. Drawer filter applied (Unread / Needs Reply / Deadlines / Money / Newsletters).

**Counts:**
- Filter counts are computed **after** blocked + tab context, but **before** the active drawer filter.

### 5. Undoable Archive/Trash (InboxViewModel.swift / EmailDetailView.swift)

**Goal:** consistent undo‑timer UX for list and detail actions.

**How it works:**
- Archive/trash from the thread view posts a notification (`archiveThreadRequested` / `trashThreadRequested`).
- InboxViewModel receives this and executes the same undoable bulk action pipeline used by list selection.
- Undo toast is rendered in InboxView above the bottom search bar; countdown uses the user’s undo delay setting.

## Risks & Mitigations

**Search filter reuse**
- **Risk:** caching the parsed search filter could show stale highlights if the cached value isn’t tied to the latest `debouncedSearchText`.
- **Mitigation:** `InboxView` derives `parsedSearchFilter` directly from `debouncedSearchText` each render and reuses it for both local filtering and highlight terms, so invalidation is automatic.

**Cached inbox sections**
- **Risk:** caching `emailSections` could show stale grouping if the cache isn’t invalidated when inbox context changes.
- **Mitigation:** `InboxStore` tracks a `sectionsDirty` flag and invalidates on all relevant state changes (`emails`, `currentTab`, `pinnedTabOption`, `activeFilter`, `filterVersion`) before recomputing.

**NetworkRetry Utility (NetworkRetry.swift):**
```swift
struct NetworkRetry {
    static func execute<T>(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        operation: () async throws -> T
    ) async throws -> T

    // Checks GmailError.rateLimited, PeopleError.rateLimited, URLError codes
    static func isRetryable(_ error: Error) -> Bool
}
```

**Features:**
- Exponential backoff with jitter (prevents thundering herd)
- Handles `GmailError.rateLimited` and `PeopleError.rateLimited`
- Retries on network timeouts and connection failures
- Configurable max attempts, base delay, and max delay

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
    var listUnsubscribe: String?  // For unsubscribe functionality
}

@Model
final class SnoozedEmail {
    var snoozeUntil: Date
}
```

### 4. Inbox Store + View Model (InboxStore.swift / InboxViewModel.swift)

**State Management with @Observable (iOS 17+):**
```swift
@MainActor
@Observable
final class InboxViewModel {
    // No @Published needed - automatic observation
    var emails: [Email] = []
    var currentTab: InboxTab = .all
    var pinnedTabOption: PinnedTabOption = .other
    var activeFilter: InboxFilter? = nil
    var currentMailbox: Mailbox = .inbox
    var isLoading = false
    var error: Error?
}
```
`InboxViewModel` keeps a lightweight `InboxViewState` (sections + filter counts) in sync with `InboxStore`.

**InboxStore actor (derived state):**
```swift
@MainActor
actor InboxStore {
    func setEmails(_ emails: [Email])
    func setCurrentTab(_ tab: InboxTab)
    func setPinnedTabOption(_ option: PinnedTabOption)
    func setActiveFilter(_ filter: InboxFilter?)
    func bumpFilterVersion()

    var sections: [EmailSection] { get }
    var counts: [InboxFilter: Int] { get }
}
```

**InboxFilterEngine (pure pipeline):**
- Stateless helpers for classification, tab context, filters, and date sectioning.
- Used by `InboxStore` to keep UI logic deterministic and testable.

**Usage in Views:**
```swift
struct InboxView: View {
    @State private var viewModel = InboxViewModel()  // Not @StateObject

    var body: some View {
        List(viewModel.emailSections) { section in ... }
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
  → remove blocked senders
  → applyTabContext(All/Primary/Pinned)
  → applyFilters(filter: unread/needsReply/etc)
  → groupEmailsByDate(today/yesterday/thisWeek/earlier)
  → display as sections
```
Implemented by `InboxFilterEngine`, invoked from `InboxStore`.

### 5. Offline Caching (EmailCache.swift)

**Strategy:**
- Cache on every fetch
- Serve cached data immediately
- Refresh in background
- Handle conflicts with server truth

**Cache Operations:**
```swift
EmailCacheManager.shared.cacheEmails(emails)      // Save (batch fetch for O(1) lookups)
EmailCacheManager.shared.loadCachedEmails()       // Load
EmailCacheManager.shared.searchCachedEmails(q)    // Offline search
EmailCacheManager.shared.clearCache()             // Clear all
```

**Performance Optimizations:**
- Batch fetch of existing emails before update (avoids N+1 queries)
- Dictionary lookup for O(1) existing email checks
- Safe array access patterns (`.first` instead of `[0]`)
- Proper error logging via OSLog

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
Process scheduled sends → Gmail API
    ↓
Schedule next task
```

**Cancellation Handling:**
```swift
// Task expiration triggers cancellation
task.expirationHandler = {
    logger.warning("Task expiring - cancelling work")
    syncTask.cancel()
}

// Sync functions check for cancellation at key points
private func performSync() async throws {
    try Task.checkCancellation()  // Before network call
    let (emails, _) = try await GmailService.shared.fetchInbox(maxResults: 50)
    try Task.checkCancellation()  // Before cache update
    await EmailCacheManager.shared.cacheEmails(emails)
}

// Loop processing checks isCancelled for graceful termination
for email in newEmails {
    if Task.isCancelled { break }
    // ... process notification
}

// Explicit CancellationError handling
} catch is CancellationError {
    logger.info("Task was cancelled due to expiration")
    task.setTaskCompleted(success: false)
}
```

**Notification Key Pruning:**
- Notification de-dupe keys (`notified_{emailId}`) are pruned after 7 days
- Prevents unbounded UserDefaults growth
- Called during each background notification check

### 7. Scheduled Send Manager (ScheduledSendManager.swift)

**Schedule Send Flow:**
```
User composes email + sets send time
    ↓
Create ScheduledSend with all data (to, cc, bcc, subject, body, attachments)
    ↓
Save to UserDefaults (metadata) + attachment files to Application Support
    ↓
Background task checks for due sends
    ↓
When sendAt <= now: Send via Gmail API
    ↓
Remove from queue on success
```

**Data Structures:**
```swift
struct ScheduledSend: Codable, Identifiable {
    let id: UUID
    let accountEmail: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let body: String
    let bodyHtml: String?
    let attachments: [ScheduledAttachment]
    let sendAt: Date
}

struct ScheduledAttachment: Codable, Identifiable {
    let id: UUID
    let filename: String
    let mimeType: String
    let dataBase64: String?
    let filePath: String?
}
```

**Features:**
- Persists scheduled sends to UserDefaults (metadata)
- Attachments stored as files in Application Support for size safety
- Processed during background notification checks
- Proper error logging on encode/decode failures

### 8. Snooze Manager (SnoozeManager.swift)

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
    └── NavigationStack (authenticated)
    └── InboxView
        ├── Scrollable header block (greeting → tab segmented control → triage pills)
        └── → EmailDetailView (push)
            ├── EmailMessageCard (expandable)
            ├── AttachmentsListView
            └── → ComposeView (sheet)
    └── SettingsView (sheet)
        ├── VacationResponderView
        ├── LabelsManagementView
        ├── FiltersManagementView
        └── SnoozedEmailsView
```

### Key UI Components

**InboxView:**
- Single List with scrollable header block (greeting → tab segmented control → triage pills)
- Full-screen SearchSheet activated by bottom toolbar search button (hidden until tapped)
- Mailbox switching via navigation title menu (.toolbarTitleMenu)
- Top trailing gear opens Settings (sheet)
- Bottom toolbar (search + compose) for thumb access
- Pull-to-refresh + infinite scroll pagination
- Swipe actions: trailing = Archive (green, full swipe), leading = Toggle Read (blue)
- Undo toast for archive actions (4-second window)

**EmailDetailView:**
- Thread view with expandable messages
- WebView for HTML email body with dynamic height calculation
- AI summary card with Apple Intelligence (iOS 26+) and extractive fallback
- Attachment previews with QuickLook
- Action footer (reply, reply all, forward, archive)
- Tab bar hidden for full-screen experience
- Action toolbar positioned at bottom (replaces tab bar)
- Block sender, unsubscribe, report spam actions in overflow menu

**Email HTML Rendering Pipeline:**
- Quoted-printable decode + HTML entity normalization before summarization
- Hidden/preheader content removal to avoid summary noise
- HTMLSanitizer strips scripts/iframes/handlers/meta refresh
- Remote images blocked via `data-blocked-src` and CSS
- WebView height updates via JS + Resize/Mutation observers
- **Readability clamp:** JS detects low-contrast text in email HTML and bumps it to a readable color (>= ~3:1 contrast) without overriding normal styling. Runs on load and DOM changes.

**ComposeView:**
- FlowLayout recipient chips + CC/BCC toggle
- Google People autocomplete + email validation (local@domain.tld format)
- Rich-text editor (bold/italic/underline, lists, links, font size, remove formatting)
- Attachment picker (photos + files) with chips and MIME multipart send
- AI draft with tone/length controls + preview insert
- Templates (save/insert per account)
- Undo Send delay + Schedule Send queue
- Auto-save drafts with recovery banner
- Reply threading with In-Reply-To headers

**SmartAvatarView:**
- Three-layer fallback: Contact Photo → Brand Logo → Initials
- Resolves via AvatarService with normalized email + brand domain
- AsyncImage for lazy loading; brand logos render on white circle
- Marks logo success/failure to avoid re-requesting dead domains
- Deterministic colors based on email hash + optional brand color override

### 8. Google People API (PeopleService.swift)

**Contact Autocomplete:**
```swift
actor PeopleService {
    static let shared = PeopleService()

    struct Contact: Identifiable, Hashable {
        let id: String
        let name: String
        let email: String
        let photoURL: String?
    }

    func fetchContacts() async throws -> [Contact]
    func searchContacts(query: String) async -> [Contact]
    func preloadContacts() async
    func getPhotoURL(for email: String) async -> URL?
    func getPhotoURLs(for emails: [String]) async -> [String: URL]
}
```

**Features:**
- Fetches user's Google contacts and "other contacts" (people you've emailed)
- 5-minute cache to reduce API calls
- Preloads on app launch for faster compose autocomplete
- Deduplicates contacts by email address
- Photo URL lookup for avatar display (single and batch)

**OAuth Scope Required:**
```
https://www.googleapis.com/auth/contacts.readonly
```

### 9. Avatar Service (AvatarService.swift)

**Smart Avatar Resolution (data-driven + cached):**
```swift
actor AvatarService {
    struct AvatarResolution: Sendable {
        let email: String
        let initials: String
        let backgroundColorHex: String
        let brandLogoURL: URL?
        let contactPhotoURL: URL?
        let brandDomain: String?
        let source: AvatarSource
    }

    func resolveAvatar(email: String, name: String, accountEmail: String? = nil) async -> AvatarResolution
    func prefetch(contacts: [(email: String, name: String)], accountEmail: String? = nil)
    func markBrandLogoLoaded(_ domain: String, success: Bool)
    nonisolated static func avatarColorHex(for email: String) -> String
}
```

**Resolution flow:**
1. Normalize sender with `DomainNormalizer` (lowercase, Gmail plus-tag stripping, alias mapping).
2. Compute root domain via public suffix list; determine `brandDomain` only for non-personal domains.
3. Return cached `AvatarResolution` if within TTL (7 days).
4. Fetch contact photo from `PeopleService` (highest priority).
5. If no photo and brand domain is eligible, request brand logo URL.
6. Apply brand color override if provided; otherwise use deterministic hash color.
7. Cache resolution + record logo success/failure to avoid repeated dead logo fetches.

**BrandRegistry (BrandRegistry.swift):**
- JSON-backed registry (`Resources/brand_registry.json`).
- Controls:
  - `personalDomains` (skip brand logos)
  - `domainAliases` (alias → primary domain)
  - `logoOverrides` (explicit logo URL per domain)
  - `brandColors` (hex color overrides)
  - `publicSuffixes` (root domain extraction)

**DomainNormalizer (DomainNormalizer.swift):**
- Extracts raw email from headers like `"Name <email@domain>"`.
- Normalizes Gmail-style plus tags (`john+promo@gmail.com` → `john@gmail.com`).
- Uses public suffix list for accurate root domain selection.

**Brand Logo URL (default):**
```
https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=http://{domain}&size=256
```

**SmartAvatarView integration:**
- Always renders initials base layer.
- Overlays brand logo with white circle background.
- Overlays contact photo (highest priority).
- On logo failure, marks domain as failed and re-resolves to drop the logo.

### 10. Email Filters (EmailFilters.swift)

**Pure Functions for Email Classification:**
```swift
enum EmailFilters {
    /// Detects if sender looks like a real person
    static func looksLikeHumanSender(_ email: Email) -> Bool

    /// Detects if email is bulk/newsletter/automated
    static func isBulk(_ email: Email) -> Bool

    /// Filters emails to only show those from real people
    static func filterForPeopleScope(_ emails: [Email]) -> [Email]
}
```

**looksLikeHumanSender() Detection:**
| Signal | Type | Examples |
|--------|------|----------|
| No-reply patterns | Negative | noreply@, notifications@, alerts@ |
| Brand sender names | Negative | "LinkedIn Team", "Uber" |
| "via" patterns | Negative | "John via Calendly" |
| Personal domains | Positive | gmail.com, icloud.com, outlook.com |
| First+Last name | Positive | "Chelsea Hart" (2-4 words) |
| Single-word names | Negative | "Experian", "Bloomberg" |

**isBulk() Detection:**
| Signal | Source | Examples |
|--------|--------|----------|
| Gmail categories | Labels | CATEGORY_PROMOTIONS, CATEGORY_SOCIAL |
| List headers | Headers | List-Unsubscribe, List-ID |
| Precedence header | Headers | bulk, list, junk |
| Auto-Submitted | Headers | anything except "no" |
| Marketing domains | Email | mailchimp.com, sendgrid.net |
| Brand sender patterns | Name | "The X Team", "X.com" |

**People Heuristics (`isPeople`):**
```
true if:
  looksLikeHumanSender(email) AND !isBulk(email)
  (optionally boosted by conversation evidence like SENT labels where needed)
```

**Usage in InboxViewModel:**
```swift
// Used by Primary rules and the Pinned "People" tab option
if isPeople(email) { ... }
```

### 11. App Initialization (SimpleMailApp.swift)

**Graceful ModelContainer Handling:**
```swift
@main
struct SimpleMailApp: App {
    /// Result of ModelContainer initialization - allows graceful error handling instead of fatalError
    private let modelContainerResult: Result<ModelContainer, Error>

    var sharedModelContainer: ModelContainer? {
        try? modelContainerResult.get()
    }

    init() {
        let schema = Schema([Email.self, EmailDetail.self, SnoozedEmail.self, ...])
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            self.modelContainerResult = .success(container)
        } catch {
            logger.error("Failed to create ModelContainer: \(error.localizedDescription)")
            self.modelContainerResult = .failure(error)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container = sharedModelContainer {
                ContentView()
                    .modelContainer(container)
            } else {
                DatabaseErrorView()  // Fallback UI with error message
            }
        }
    }
}
```

**Benefits:**
- No crash on database initialization failure
- User sees helpful error message instead of blank screen
- Error is logged for debugging
- App remains functional for error reporting

### 12. Theme Manager (ThemeManager)

**Appearance Settings:**
```swift
@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var currentTheme: AppTheme = .system

    var colorScheme: ColorScheme? {
        switch currentTheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppTheme: String, Codable {
    case system, light, dark
}
```

**Features:**
- Persists theme setting to UserDefaults
- Applied via `.preferredColorScheme()` on root view
- Immediate UI update on change

### 13. Biometric Authentication (BiometricAuthManager)

**Face ID / Touch ID Lock:**
```swift
@MainActor
class BiometricAuthManager: ObservableObject {
    static let shared = BiometricAuthManager()

    @Published var isLocked: Bool = false

    func lockIfNeeded()  // Called when app enters background
    func authenticate() async  // Uses LAContext
}
```

**Flow:**
```
App enters background
    ↓
If biometricLock setting enabled
    ↓
Set isLocked = true
    ↓
App becomes active
    ↓
Show LockScreenView overlay
    ↓
Prompt Face ID / Touch ID
    ↓
On success: isLocked = false
```

**Features:**
- Respects user's "Require Face ID" setting
- Falls back to device passcode if biometric fails
- Adaptive icon/name for Face ID vs Touch ID vs Optic ID

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
| `InboxView` | Settings loading, UI state |
| `SnoozeManager` | Snooze scheduling, notifications |
| `AuthService` | OAuth flow, token refresh, account management |
| `BackgroundSync` | Background task execution, cancellation |
| `PeopleService` | Contacts fetch, search, photo lookup |
| `AvatarService` | Avatar cache operations |
| `EmailCache` | Cache operations, batch updates |
| `EmailDetail` | Thread loading, AI summaries |
| `BrandRegistry` | Brand registry JSON loading |
| `ScheduledSend` | Scheduled send queue operations |
| `Settings` | Settings sync, label management |
| `Search` | Search queries and results |
| `Briefing` | Briefing item interactions |
| `Attachments` | Attachment downloads |
| `BatchOperations` | Multi-select and print jobs |
| `SimpleMailApp` | URL handling, notifications, ModelContainer |
| `Keychain` | Keychain storage operations |

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
- HTMLSanitizer security functions
- Summary text normalization (quoted-printable decode + entity cleanup)

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

### UI Tests (XCUITest)

**Test Target:** `SimpleMailUITests`

**18 Automated Tests:**
| Test | Coverage |
|------|----------|
| `testAppLaunches` | App startup |
| `testLoginScreenAppears` | Auth state detection |
| `testTabBarExists` | Tab bar presence |
| `testCanSwitchToBriefingTab` | Briefing navigation |
| `testCanSwitchToSettingsTab` | Settings navigation |
| `testInboxLoads` | Inbox display |
| `testCanPullToRefresh` | Pull-to-refresh gesture |
| `testCanOpenSearch` | Search sheet presentation |
| `testCanOpenCompose` | Compose view |
| `testCanDismissCompose` | Compose dismissal |
| `testCanOpenEmail` | Email detail navigation |
| `testCanNavigateBackFromEmail` | Back navigation |
| `testSettingsShowsAccountInfo` | Settings content |
| `testCanSwipeEmailForActions` | Swipe gestures |
| `testLaunchPerformance` | Launch time measurement |
| `testLaunch` (4x) | Launch reliability |

**Accessibility Identifiers:**
```swift
// InboxView
.accessibilityIdentifier("inboxList")
.accessibilityIdentifier("searchButton")
.accessibilityIdentifier("composeButton")

// EmailDetailView
.accessibilityIdentifier("emailDetailView")

// ComposeView
.accessibilityIdentifier("composeView")
.accessibilityIdentifier("cancelCompose")
.accessibilityIdentifier("sendButton")
```

**Running Tests:**
```bash
# Command line
xcodebuild test -project SimpleMail.xcodeproj -scheme SimpleMail \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SimpleMailUITests

# Xcode: ⌘+U
```

## Future Enhancements

### Planned Features
- [x] Apple Intelligence summarization (iOS 26+ with extractive fallback)
- [x] Email signature formatting (bold, italic, links)
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

### Open Decisions
- [ ] Decide whether to keep LightSweep animation effects
  - Currently using subtle animations on email interactions
  - Consider performance impact on lower-end devices
  - Evaluate if it adds value to UX

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

## Swift Concurrency Patterns

### Sendable DTOs for Cross-Actor Transfer

SwiftData `@Model` types cannot be `Sendable`. Use lightweight DTOs for safe data transfer:

```swift
/// Lightweight, Sendable representation of an email
struct EmailDTO: Sendable, Identifiable, Hashable {
    let id: String
    let threadId: String
    let subject: String
    // ... all value-type properties

    var senderEmail: String {
        EmailParser.extractSenderEmail(from: from)
    }
}

// Conversion from SwiftData model
extension Email {
    func toDTO() -> EmailDTO {
        EmailDTO(id: id, threadId: threadId, ...)
    }
}
```

### Actor-Based Keychain Service

Thread-safe keychain access using Swift actors:

```swift
actor KeychainService {
    static let shared = KeychainService()

    func save(key: String, data: Data) throws
    func read(key: String) -> Data?
    func delete(key: String)
    func exists(key: String) -> Bool
    func clearAll()
}

// Synchronous wrapper for @MainActor contexts (NSLock for thread safety)
final class KeychainServiceSync: @unchecked Sendable {
    static let shared = KeychainServiceSync()
    private let lock = NSLock()

    func save(key: String, data: Data)   // Lock-protected direct Security API
    func read(key: String) -> Data?       // Lock-protected direct Security API
    func delete(key: String)              // Lock-protected direct Security API
}
```

### Nonisolated Methods for Performance

Parser methods don't access actor state, avoiding unnecessary hops:

```swift
actor GmailService {
    // Parsing doesn't need actor isolation
    private nonisolated func parseEmail(from message: MessageResponse) -> Email
    private nonisolated func parseDate(_ dateString: String) -> Date?
    private nonisolated func extractBody(from payload: Payload?) -> String

    // Static cached formatters for performance
    private static let dateFormatters: [DateFormatter] = { ... }()
}
```

---

*Last updated: January 2026*
*Architecture version: 2.4*

**Changelog:**
- v2.4:
  - **iOS 26 Native Search & Toolbar:**
    - Search uses native `.searchable` with `@FocusState` binding
    - Bottom toolbar search button focuses the native search drawer (no separate screen)
    - Toolbar buttons render with iOS 26 Liquid Glass styling (native behavior)
    - Removed custom SearchSheet in favor of native `.searchable` pattern
- v2.3:
  - **Search UI Refactor:**
    - Replaced inline `.searchable` bar with full-screen `SearchSheet`
    - Search is now completely hidden until user taps the search button (cleaner inbox UI)
    - SearchSheet combines cached + API results for fast initial display with comprehensive follow-up
    - Removed deprecated BriefingScreenView and standalone SearchView components
- v2.2:
  - **Email Rendering Fixes:**
    - Fixed remote images not loading - WKWebView requires baseURL for cross-origin resources
    - Wired up "Block Remote Images" setting from Privacy & Security to EmailBodyView
    - Setting now controls whether images load in email body (default: load images)
- v2.1:
  - **Critical Fixes:**
    - Replaced `fatalError` in SimpleMailApp.swift with graceful ModelContainer error handling
    - Added `DatabaseErrorView` fallback UI when ModelContainer fails to initialize
    - Fixed DispatchQueue.main.sync deadlock risk in AuthService's `presentationAnchor` using `MainActor.assumeIsolated`
    - Fixed token refresh race condition with proper task cleanup (removes task from dictionary on both success and failure)
    - Added cache clearing on account switch (AvatarService + PeopleService caches invalidated)
  - **Network Resilience:**
    - Added `NetworkRetry.swift` utility with exponential backoff and jitter
    - Fixed rate limiting bypass: now handles `GmailError.rateLimited` and `PeopleError.rateLimited`
    - Configurable retry attempts, base delay, and max delay
  - **Background Sync Improvements:**
    - Added `Task.checkCancellation()` at key points in `performSync()` and `checkForNewEmails()`
    - Added `Task.isCancelled` check in notification processing loop for graceful termination
    - Improved expiration handlers with logging when tasks expire
    - Added explicit `CancellationError` handling to distinguish cancellation from failures
  - **Error Handling & Logging:**
    - Replaced all silent `try?` with proper `do/catch` blocks and OSLog logging:
      - EmailCache.swift: account email count fetch
      - BrandRegistry.swift: JSON file loading (brand_registry.json)
      - ScheduledSendManager.swift: encode/decode scheduled sends
      - InboxView.swift: settings decode
      - EmailDetailView.swift: auto-summarize settings
      - BackgroundSync.swift: settings loading
    - Added OSLog loggers to InboxView.swift and BrandRegistry.swift
  - **Memory Safety:**
    - Fixed undoTask cancellation in InboxViewModel deinit using `MainActor.assumeIsolated`
    - Added `@unchecked Sendable` documentation to KeychainServiceSync explaining NSLock thread safety
  - **New Files:**
    - `Utils/NetworkRetry.swift` - Configurable network retry with exponential backoff
    - `Views/ErrorBanner.swift` - Reusable error display component
  - **Code Quality:**
    - Fixed FormatButton call syntax in ComposeView.swift
    - Renamed `body` state variable to `templateBody` in NewTemplateSheet to avoid shadowing View.body
- v2.0:
  - Added XCUITest framework with 18 automated UI tests
  - Tests cover: app launch, tab navigation, inbox, search, compose, email detail, settings, swipe actions, performance
  - Added accessibility identifiers to key UI elements (inboxList, searchButton, composeButton, emailDetailView, composeView, cancelCompose, sendButton)
  - Fixed AI summary threshold to use plain text length instead of HTML length
  - Added EmailTextHelper.plainTextLength() to strip HTML before counting characters
  - Lowered threshold from 500 to 300 chars (plain text is more compact than HTML)
  - Enhanced HTMLSanitizer with additional security measures:
    - Improved event handler regex to handle quoted and unquoted attributes
    - Added meta refresh and base href redirect removal
    - Added external stylesheet blocking (can contain tracking pixels)
    - Added srcset stripping from images
    - Added background-image URL neutralization in inline styles
    - Added @import URL removal from style blocks
  - Added MessageDateFormatters enum for cached date formatters in EmailMessageCard
  - Added ResizeObserver and MutationObserver for dynamic WebView height updates
- v1.9:
  - Added EmailFilters utility for People scope filtering (ported from React briefingEngine)
  - looksLikeHumanSender(): Detects real people vs automated senders
  - isBulk(): Detects newsletters/marketing/automated emails using Gmail categories, headers, domains
  - filterForPeopleScope(): Combines both + keeps conversation threads (SENT label)
  - InboxViewModel now uses EmailFilters.filterForPeopleScope() for People tab
  - Replaces simplified inline check with sophisticated detection matching React implementation
- v1.8:
  - Added Config directory with Config.swift (OAuth from Info.plist) and TimeoutConfig.swift (centralized timeouts)
  - Fixed KeychainServiceSync to use NSLock for proper thread-safe synchronous access
  - Added HTTP status validation to fetchUserInfo in AuthService
  - Added new AuthError cases: invalidResponse, userInfoFetchFailed(Int), rateLimited
  - Fixed account management race condition with atomic update pattern
  - Fixed N+1 query in EmailCache.cacheEmails() using batch fetch with dictionary lookup
  - Fixed unsafe array access (labelIds.first instead of labelIds[0])
  - Replaced all print() with OSLog Logger across 9 files
  - Replaced silent try? with proper error handling and logging
  - Added email validation in ComposeView (validates local@domain.tld format)
  - Added OAuth config keys to Info.plist for build settings
- v1.7:
  - Added SmartAvatarView with three-layer fallback chain (Contact Photo → Brand Logo → Initials)
  - Added AvatarService actor for avatar caching and domain detection
  - Brand logos fetched via Google's high-quality favicon service (256px)
  - Personal domain detection to skip brand logos for gmail.com, outlook.com, etc.
  - Domain alias mapping for correct branding (vzw.com → verizon.com, etc.)
  - Added getPhotoURL() and getPhotoURLs() to PeopleService for contact photo lookup
  - Replaced old AvatarView in InboxView, EmailDetailView, ComposeView, BatchOperations
  - Deterministic color selection for initials based on email hash
- v1.6:
  - Fixed email body rendering with dynamic WebView height calculation using JavaScript message handlers
  - WebView now measures content height after load and image load events
  - Fixed WebView memory leak with WeakScriptMessageHandler wrapper (breaks WKScriptMessageHandler retain cycle)
  - Added block sender functionality (saves to UserDefaults blocked list)
  - Blocked senders are filtered out in InboxViewModel.applyFilters()
  - BlockedSendersView in Settings allows viewing and unblocking senders
  - VIPSendersView now properly loads/saves from UserDefaults with add functionality
  - Added unsubscribe support (parses List-Unsubscribe header, prefers https over mailto)
  - Added report spam action (uses Gmail API to move to spam)
  - Added listUnsubscribe field to EmailDetail model and DTO
  - AI summary now filters common boilerplate text (view in browser, unsubscribe links, etc.)
- v1.5:
  - Implemented Undo Toast for archive actions with 4-second timeout and optimistic UI updates
  - Added UndoToast component with animated slide-up/down transitions
  - Email is removed immediately on swipe, restored at exact index on undo
  - EmailDetailView now hides main tab bar using `.toolbar(.hidden, for: .tabBar)`
  - Action toolbar (Reply/Archive) repositioned to bottom of screen with shadow
  - Improved email body extraction to check for whitespace-only content
  - Added debug logging for body attachment fetching
- v1.4:
  - Added Google People API integration (PeopleService) for email autocomplete with contact suggestions
  - Added Google Contacts scope (`contacts.readonly`) to OAuth
  - Added Theme Manager for Light/Dark/System appearance settings with persistence
  - Added Biometric Auth Manager for Face ID/Touch ID lock functionality
  - Added lock screen view with biometric authentication on app resume
  - Improved email body extraction with recursive part search for deeply nested MIME structures
  - Added async fetching for email body attachments (when body has attachmentId)
  - Simplified swipe actions: trailing = Archive (green), leading = Toggle Read (blue)
  - Removed Trash/Star/Snooze from swipe actions for cleaner UX
  - Fixed date parsing to use Gmail's `internalDate` (milliseconds since epoch)
  - Added HTML entity decoding for email snippets
  - Fixed compose recipient field with pending input handling
  - Contacts preloaded on app launch for faster autocomplete
- v1.3: Fixed MIME builder types (concrete MIMEHeader vs protocol), SwiftData predicate variable capture, MainActor.assumeIsolated for OAuth callbacks
- v1.2: Added Sendable DTOs, actor-based Keychain, nonisolated optimizations
- v1.1: Added @Observable migration, MIME Result Builder, Base64URL utilities, OSLog integration, protocol-based testing
- v1.0: Initial architecture documentation
