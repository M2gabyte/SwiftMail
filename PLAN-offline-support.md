# Offline Email Support - Architecture Documentation

## Overview

SimpleMail now supports Gmail/Apple Mail-style offline functionality:
1. **Read emails offline** - Previously-fetched emails remain accessible when offline
2. **Send emails offline** - Outgoing emails queue locally and send automatically when online

---

## Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         SimpleMail                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────┐    ┌──────────────────┐                   │
│  │  NetworkMonitor  │───▶│  OutboxManager   │                   │
│  │  (NWPathMonitor) │    │  (Queue + Send)  │                   │
│  └────────┬─────────┘    └────────┬─────────┘                   │
│           │                       │                              │
│           ▼                       ▼                              │
│  ┌──────────────────┐    ┌──────────────────┐                   │
│  │ PendingSendMgr   │    │   QueuedEmail    │                   │
│  │ (Undo + Offline) │───▶│  (SwiftData)     │                   │
│  └──────────────────┘    └──────────────────┘                   │
│                                                                  │
│  ┌──────────────────┐    ┌──────────────────┐                   │
│  │BodyPrefetchQueue │───▶│   EmailDetail    │                   │
│  │ (Background)     │    │  (SwiftData)     │                   │
│  └──────────────────┘    └──────────────────┘                   │
│                                                                  │
│  ┌──────────────────┐                                           │
│  │BackgroundSyncMgr │  Processes outbox on wake                 │
│  │ (BGTasks)        │                                           │
│  └──────────────────┘                                           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## New Components

### 1. NetworkMonitor (`Services/NetworkMonitor.swift`)

Monitors network connectivity using Apple's `NWPathMonitor`.

**Key Features:**
- Singleton `@Observable` class for SwiftUI integration
- Tracks connection state (`isConnected`) and type (wifi/cellular/wired)
- Posts `networkConnectivityChanged` notification on state changes
- Automatically triggers `OutboxManager.processQueue()` when coming online

**Usage:**
```swift
// Start monitoring (called in app init)
NetworkMonitor.shared.start()

// Check connectivity
if NetworkMonitor.shared.isConnected {
    // Online
}

// React to changes in SwiftUI
if !networkMonitor.isConnected {
    OfflineBanner()
}
```

---

### 2. QueuedEmail (`Models/QueuedEmail.swift`)

SwiftData model for persisting outgoing emails when offline.

**Schema:**
| Field | Type | Description |
|-------|------|-------------|
| id | UUID | Unique identifier |
| accountEmail | String | Sender account |
| toRecipients | [String] | To addresses |
| ccRecipients | [String] | CC addresses |
| bccRecipients | [String] | BCC addresses |
| subject | String | Email subject |
| body | String | Plain text body |
| bodyHtml | String? | HTML body |
| attachmentsData | Data? | JSON-encoded attachments |
| inReplyTo | String? | Reply threading |
| threadId | String? | Gmail thread ID |
| createdAt | Date | Queue timestamp |
| statusRaw | String | pending/sending/failed |
| lastError | String? | Last failure reason |
| retryCount | Int | Retry attempts |

**Attachment Storage:**
- Attachments stored as files in `Documents/outbox_attachments/`
- `QueuedAttachmentStorage` helper handles save/load/cleanup
- File URLs stored in JSON, not inline data (memory efficient)

---

### 3. OutboxManager (`Services/OutboxManager.swift`)

Manages the offline email queue with send retry logic.

**Key Methods:**
```swift
// Queue an email for offline sending
func queue(accountEmail:to:cc:bcc:subject:body:...) async throws

// Process all pending emails (called when online)
func processQueue() async

// Retry a failed email
func retry(id: UUID) async

// Delete a queued email
func delete(id: UUID) async

// Get queued emails for display
func fetchQueued(for accountEmail: String) -> [QueuedEmailDTO]
```

**Retry Logic:**
- Max 3 retries before marking as `failed`
- Failed emails require manual retry
- Successful sends delete the queued email and attachment files

---

### 4. BodyPrefetchQueue (`Services/BodyPrefetchQueue.swift`)

Background queue for prefetching email bodies for offline reading.

**Behavior:**
- Enqueues top 50 emails from inbox fetches
- Prioritizes: unread > starred > non-newsletter
- Respects battery level (stops below 20%)
- Skips in low power mode
- Uses `TaskGroup` for concurrent fetching (3 at a time)
- Caches to `EmailDetail` SwiftData model

**Trigger Points:**
- Background sync (`performSync`)
- Manual refresh

---

## Modified Components

### PendingSendManager

**Changes:**
- Added `wasQueuedOffline` flag
- Added `accountEmail` to `PendingEmail` struct
- `queueSend()` now checks `NetworkMonitor.shared.isConnected`
- If offline, immediately queues to `OutboxManager`
- If online but loses connection during delay, queues to `OutboxManager`
- Added `clearQueuedOfflineFlag()` for UI toast dismissal

**Flow:**
```
User taps Send
     │
     ▼
┌─────────────────┐
│ Online?         │───No───▶ OutboxManager.queue() ──▶ "Queued" toast
└────────┬────────┘
         │ Yes
         ▼
   Wait N seconds (undo delay)
         │
         ▼
┌─────────────────┐
│ Still online?   │───No───▶ OutboxManager.queue() ──▶ "Queued" toast
└────────┬────────┘
         │ Yes
         ▼
   GmailService.sendEmail()
         │
         ▼
   Success ──▶ Haptic feedback
```

---

### BackgroundSyncManager

**New Task:**
- `com.simplemail.app.outbox` - BGProcessingTask for outbox
- Requires network connectivity
- Scheduled when pending emails exist

**Changes to Existing Tasks:**
- `checkForNewEmails()` now also processes outbox queue
- `performSync()` now enqueues to `BodyPrefetchQueue`

---

### SimpleMailApp

**Changes:**
- Added `QueuedEmail` to SwiftData schema
- ContentView now configures `OutboxManager`
- ContentView now starts `NetworkMonitor`

---

### InboxView

**UI Additions:**
- `offlineBannerContent` - Shows "You're offline" pill at top
- Updated `undoSendToastContent` to show "Queued" toast for offline sends

---

### ComposeView

**New Views:**
- `QueuedOfflineToast` - Orange toast showing "Queued - will send when online"
- `OfflineBanner` - Gray capsule showing "You're offline"

---

## Data Flow

### Offline Send Flow
```
1. User composes email and taps Send
2. PendingSendManager checks NetworkMonitor.isConnected
3. If offline:
   a. OutboxManager.queue() creates QueuedEmail
   b. Attachments saved to Documents/outbox_attachments/
   c. QueuedEmail inserted to SwiftData
   d. UI shows "Queued" toast
4. When network returns:
   a. NetworkMonitor posts notification
   b. OutboxManager.processQueue() triggered
   c. Each QueuedEmail sent via GmailService
   d. On success: QueuedEmail deleted, attachments cleaned up
   e. On failure: retryCount++, if >= 3 mark as failed
```

### Offline Read Flow
```
1. Background sync fetches inbox metadata
2. BodyPrefetchQueue.enqueueCandidates() called
3. Top 50 emails (prioritized) queued for body fetch
4. Bodies fetched and cached to EmailDetail (SwiftData)
5. When offline, user can:
   - View inbox list (Email model cached)
   - Open emails (EmailDetail model cached)
   - Bodies available for previously-synced emails
```

---

## Configuration

| Setting | Value | Location |
|---------|-------|----------|
| Body prefetch limit | 50 emails | BodyPrefetchQueue.maxPrefetchPerSession |
| Max retry attempts | 3 | OutboxManager.maxRetries |
| Concurrent body fetches | 3 | BodyPrefetchQueue.concurrentFetchLimit |
| Min battery for prefetch | 20% | BodyPrefetchQueue.canRunNow() |

---

## Testing

### Manual Testing Steps
1. **Offline Send:**
   - Enable Airplane Mode
   - Compose and send email
   - Verify "Queued" toast appears
   - Disable Airplane Mode
   - Verify email sends automatically

2. **Offline Read:**
   - Open app online, let it sync
   - Enable Airplane Mode
   - Verify can browse inbox
   - Verify can open previously-viewed emails

3. **Persistence:**
   - Queue email offline
   - Force-quit app
   - Relaunch app
   - Verify queued email still exists and sends when online

4. **Failed Sends:**
   - Queue email with invalid recipient
   - Verify retry logic (3 attempts)
   - Verify marked as failed after max retries

---

## File Summary

| File | Type | Description |
|------|------|-------------|
| `Services/NetworkMonitor.swift` | NEW | NWPathMonitor connectivity |
| `Models/QueuedEmail.swift` | NEW | Outbox SwiftData model |
| `Services/OutboxManager.swift` | NEW | Queue management |
| `Services/BodyPrefetchQueue.swift` | NEW | Background body caching |
| `Services/PendingSendManager.swift` | MOD | Offline queue fallback |
| `Services/BackgroundSync.swift` | MOD | Outbox BGTask + prefetch |
| `Views/ComposeView.swift` | MOD | Queued toast + banner |
| `Views/InboxView.swift` | MOD | Offline banner |
| `SimpleMailApp.swift` | MOD | Schema + init |
