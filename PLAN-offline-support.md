# Offline Email Support Implementation Plan

## Overview

Add Gmail/Apple Mail-style offline functionality:
1. **Read emails offline** - View previously-fetched emails when offline
2. **Send emails offline** - Queue outgoing emails and send when back online

---

## Current State Analysis

### What Already Works
- **SwiftData persistence** - `Email` and `EmailDetail` models are already persisted locally
- **Email caching** - `EmailCacheManager` caches inbox metadata
- **Background sync** - `BackgroundSyncManager` fetches emails periodically
- **Network retry** - `NetworkRetry` handles transient failures with exponential backoff

### Gaps to Fill
| Gap | Description |
|-----|-------------|
| Email body not always cached | `EmailDetail` only fetched when user opens an email |
| No persistent outbound queue | `PendingSendManager` is in-memory only, lost on restart |
| No network monitoring | App doesn't know when it's offline |
| No offline UI feedback | No visual indication of offline state or pending sends |

---

## Implementation Plan

### Phase 1: Network Connectivity Monitoring

**New File**: `SimpleMail/Sources/Services/NetworkMonitor.swift`

Create a network reachability service using `NWPathMonitor`:

```swift
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isConnected: Bool = true
    private(set) var connectionType: ConnectionType = .unknown

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    enum ConnectionType {
        case wifi, cellular, wired, unknown
    }

    func start() { ... }
    func stop() { ... }
}
```

**Integration Points**:
- Start monitoring in `SimpleMailApp.init()`
- Inject into environment for SwiftUI views
- Use in `GmailService` to fail fast when offline

---

### Phase 2: Proactive Email Body Caching

**Goal**: Ensure email bodies are available offline for recently-viewed and important emails.

#### 2a. Cache Strategy

Modify `EmailCacheManager` to support body prefetching:

1. **On inbox fetch**: Queue body prefetch for top N emails (e.g., 50)
2. **On email open**: Already caches body (existing behavior)
3. **Background sync**: Prefetch bodies for new emails

**New Method in EmailCacheManager**:
```swift
func prefetchBodiesIfNeeded(for emails: [Email], limit: Int = 50) async
```

#### 2b. Body Prefetch Queue

**New File**: `SimpleMail/Sources/Services/BodyPrefetchQueue.swift`

Similar to `SummaryQueue` but for email bodies:
- Respects battery level
- Prioritizes unread/starred emails
- Uses `TaskGroup` for parallel fetching
- Skips already-cached bodies

---

### Phase 3: Offline Send Queue (Core Feature)

**New File**: `SimpleMail/Sources/Models/QueuedEmail.swift`

```swift
@Model
final class QueuedEmail {
    var id: UUID
    var accountEmail: String
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var body: String
    var bodyHtml: String?
    var attachments: [AttachmentData]  // Stored as file URLs
    var inReplyTo: String?
    var references: String?
    var threadId: String?
    var createdAt: Date
    var status: QueueStatus  // pending, sending, failed
    var lastError: String?
    var retryCount: Int
}

enum QueueStatus: String, Codable {
    case pending, sending, failed
}
```

**New File**: `SimpleMail/Sources/Services/OutboxManager.swift`

```swift
@MainActor
@Observable
final class OutboxManager {
    static let shared = OutboxManager()

    private(set) var pendingCount: Int = 0
    private(set) var isSyncing: Bool = false

    // Queue email for sending (works offline)
    func queue(email: QueuedEmail) async throws

    // Process queue when online
    func processQueue() async

    // Retry failed email
    func retry(id: UUID) async

    // Delete queued email
    func delete(id: UUID) async

    // Get all queued emails for UI
    func fetchQueued(for account: String) -> [QueuedEmail]
}
```

**Integration with NetworkMonitor**:
```swift
// When network becomes available
NetworkMonitor.shared.$isConnected
    .filter { $0 }
    .sink { _ in
        Task { await OutboxManager.shared.processQueue() }
    }
```

---

### Phase 4: Modify Email Sending Flow

**File**: `SimpleMail/Sources/Services/GmailService.swift`

Wrap `sendEmail()` to support offline queuing:

```swift
func sendEmailWithOfflineSupport(...) async throws -> String? {
    if NetworkMonitor.shared.isConnected {
        // Try direct send
        return try await sendEmail(...)
    } else {
        // Queue for later
        try await OutboxManager.shared.queue(...)
        return nil  // Indicates queued, not sent
    }
}
```

**File**: `SimpleMail/Sources/Views/Compose/ComposeViewModel.swift`

Update send logic to:
1. Call `sendEmailWithOfflineSupport()`
2. Show "Queued" toast instead of "Sent" when offline
3. Return success either way (user doesn't need to retry manually)

---

### Phase 5: Background Queue Processing

**File**: `SimpleMail/Sources/Services/BackgroundSync.swift`

Add outbox processing to background sync:

```swift
// New BGTask identifier
static let outboxTaskIdentifier = "com.simplemail.outbox"

func handleOutboxTask(_ task: BGProcessingTask) async {
    guard NetworkMonitor.shared.isConnected else {
        task.setTaskCompleted(success: false)
        return
    }

    await OutboxManager.shared.processQueue()
    task.setTaskCompleted(success: true)
}
```

Register in `SimpleMailApp`:
```swift
BGTaskScheduler.shared.register(
    forTaskWithIdentifier: BackgroundSyncManager.outboxTaskIdentifier,
    using: nil
) { task in ... }
```

---

### Phase 6: UI Updates

#### 6a. Offline Banner

**File**: `SimpleMail/Sources/Views/Inbox/InboxView.swift`

Add subtle offline indicator:
```swift
if !networkMonitor.isConnected {
    HStack {
        Image(systemName: "wifi.slash")
        Text("Offline")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
}
```

#### 6b. Outbox Section (Optional)

Could add an "Outbox" mailbox showing queued emails:
- Shows pending count badge
- Allows viewing/editing/deleting queued emails
- Manual retry button for failed sends

#### 6c. Send Button Feedback

In compose view, update send button:
- Online: "Send" → sends immediately
- Offline: "Send" → shows "Will send when online" toast

---

### Phase 7: SwiftData Schema Update

**File**: `SimpleMail/Sources/SimpleMailApp.swift`

Add `QueuedEmail` to ModelContainer:

```swift
let schema = Schema([
    Email.self,
    EmailDetail.self,
    SnoozedEmail.self,
    SenderPreference.self,
    QueuedEmail.self  // NEW
])
```

---

## File Changes Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `Services/NetworkMonitor.swift` | NEW | Network reachability monitoring |
| `Models/QueuedEmail.swift` | NEW | Outbox email model (SwiftData) |
| `Services/OutboxManager.swift` | NEW | Outbox queue management |
| `Services/BodyPrefetchQueue.swift` | NEW | Background body prefetching |
| `Services/EmailCacheManager.swift` | MODIFY | Add body prefetch support |
| `Services/GmailService.swift` | MODIFY | Add offline-aware send wrapper |
| `Services/BackgroundSync.swift` | MODIFY | Add outbox task processing |
| `Views/Compose/ComposeViewModel.swift` | MODIFY | Use offline-aware sending |
| `Views/Inbox/InboxView.swift` | MODIFY | Add offline indicator |
| `SimpleMailApp.swift` | MODIFY | Register NetworkMonitor, update schema |

---

## Implementation Order

1. **NetworkMonitor** - Foundation for all offline features
2. **QueuedEmail model** - SwiftData persistence for outbox
3. **OutboxManager** - Core queuing logic
4. **Modify send flow** - Wire up offline sending
5. **Background processing** - Auto-send when back online
6. **UI feedback** - Offline banner + send confirmation
7. **Body prefetching** - Enhanced offline reading (can be Phase 2)

---

## Testing Considerations

- Enable Airplane Mode in Simulator to test offline behavior
- Test app restart with queued emails (persistence)
- Test background wake to process queue
- Test failed sends and retry logic
- Test multi-account outbox isolation

---

## Questions for User

1. **Outbox UI**: Should there be a visible "Outbox" folder showing queued emails, or just a subtle badge/indicator?
2. **Body prefetch limit**: How many email bodies to prefetch? (50? 100? Configurable?)
3. **Failed send behavior**: Auto-retry forever, or max retries then require manual action?
4. **Attachments**: Large attachments could consume storage - any size limits for offline queue?
