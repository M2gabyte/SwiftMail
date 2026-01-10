# SimpleMail Speed Architecture

This document captures findings about performance bottlenecks and architectural decisions related to app speed.

---

## WebKit Process Architecture

When displaying HTML email bodies, we use `WKWebView`. WebKit runs in a multi-process architecture:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   App Process   │────▶│   GPU Process   │────▶│ WebContent Proc │
│  (SimpleMail)   │     │  (rendering)    │     │  (JS/layout)    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

### Cold Start Cost

Creating the **first** `WKWebView` triggers process launches:
- GPU Process: ~1000ms to launch (blocks main thread)
- WebContent Process: ~200-400ms

This is an iOS platform limitation. The GPU process launch is synchronous and cannot be avoided.

### Process Lifecycle

WebKit aggressively manages process lifecycle:
- Processes launch on first WKWebView creation
- Processes exit after idle timeout (`IdleExit`)
- Subsequent WKWebViews reuse existing processes (fast)

---

## Current Performance (After Fixes)

### Email Load Times

| Metric | Time |
|--------|------|
| EmailDetail.appear → threadLoaded | 170-230ms |
| EmailDetail.appear → bodySwap | 190-260ms |

**These are good times.** The email detail path is already fast.

### Key Insight

The first email open pays the WebKit cold-start cost (~1s), but this happens naturally as part of opening the email. **No pre-warming is needed** because:

1. Email detail is already fast (~250ms once WebKit is up)
2. The user just tapped, so a brief load is expected
3. Pre-warming causes random freezes during inbox browsing with no benefit

---

## Why Pre-Warming Doesn't Work

We tried several warmup strategies. None provided net benefit:

### Strategy 1: primeOnce() during inbox idle

```swift
// Created a throwaway WKWebView
func primeOnce() {
    let webView = makeWebView()
    webView.loadHTMLString("<html>...</html>", baseURL: nil)
} // <- webView dies here, GPU process may IdleExit before use
```

**Problems:**
- Caused 1-second main thread stall during inbox browsing
- The primed webView wasn't retained, so it was immediately deallocated
- Even if retained, GPU IdleExit can still happen when there's no GPU work
- Net result: pay 1-second cost for zero benefit

### Strategy 2: primeOnce() on row tap with delay

```swift
.onTapGesture {
    WKWebViewPool.shared.primeOnce()
    Task.sleep(for: .milliseconds(50))
    viewModel.openEmail(id: email.id)
}
```

**Problems:**
- 50ms wasn't enough (GPU takes ~1000ms)
- Would need ~1200ms delay, which makes UX worse
- Still doing main-thread WKWebView creation, just hiding behind arbitrary sleep

### Conclusion: Don't Pre-Warm

The warmup was net negative. Removed entirely.

---

## WKWebViewPool Implementation

Location: `Sources/Views/EmailDetailView.swift`

```swift
final class WKWebViewPool {
    static let shared = WKWebViewPool()
    private var pool: [WKWebView] = []
    private let maxSize = 3

    func dequeue() -> WKWebView {
        if let webView = pool.popLast() {
            reset(webView)
            return webView
        }
        return makeWebView()
    }

    func recycle(_ webView: WKWebView) {
        reset(webView)
        if pool.count < maxSize {
            pool.append(webView)
        }
    }

    private func reset(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.scrollView.setContentOffset(.zero, animated: false)
        // Don't loadHTMLString here - unnecessary navigation
    }
}
```

**Key fix:** `reset()` no longer calls `loadHTMLString()`. That was unnecessary churn - the real content will be loaded when the email body is set.

---

## Other Performance Fixes Applied

### SwiftData Actor Isolation

**Problem:** SwiftData `@Model` objects cannot cross actor boundaries.

**Symptoms:** Main thread stalls when passing Email objects to background tasks.

**Fix:** Build value types (DTOs, snapshots) on main thread BEFORE `Task.detached`:

```swift
// WRONG - passes @Model across actors
Task.detached {
    process(emails)  // emails are @Model objects
}

// CORRECT - extract values first
let snapshots = emails.map { EmailSnapshot(from: $0) }
Task.detached {
    process(snapshots)  // snapshots are value types
}
```

Files fixed:
- `InboxViewModel.scheduleSummaryCandidates()`
- `InboxViewModel.trimVisibleWindow()`
- Deleted `DisplayModelWorker` actor entirely

### HTML Processing Off Main Thread

**Problem:** `EmailBodyWebView` was doing HTML sanitization, regex, and string hashing on main thread.

**Fix:** Extended `BodyRenderActor` to do ALL processing off-main:

```swift
actor BodyRenderActor {
    func render(html: String, settings: RenderSettings) async -> RenderedBody {
        // All heavy work here (sanitize, block images, strip tracking, style)
        return RenderedBody(html: ..., plain: ..., styledHTML: ...)
    }
}
```

`EmailBodyWebView` now just receives pre-rendered `styledHTML` and loads it.

### Search Hydration Off Main Thread

**Problem:** `performLocalSearch()` was fetching SwiftData models on main actor.

**Fix:** Added `EmailCacheManager.loadCachedEmailDTOs()` that uses a background `ModelContext`:

```swift
nonisolated func loadCachedEmailDTOs(by ids: [String], accountEmail: String?) async -> [EmailDTO] {
    let backgroundContext = ModelContext(container)
    backgroundContext.autosaveEnabled = false
    // Fetch and convert to DTOs in background
}
```

### Staged Inbox Rendering

**Problem:** Loading 100+ emails in one frame caused long stalls.

**Fix:** Show first 20 emails immediately, append rest after delay:

```swift
if deduped.count > 20 {
    applyEmailUpdate(Array(deduped.prefix(20)))
    try? await Task.sleep(for: .milliseconds(200))
    applyEmailUpdate(deduped)
} else {
    applyEmailUpdate(deduped)
}
```

---

## Compose/Discard Flow Fixes

### Problem: Discard blocked on network

**Symptoms:** Tapping "Discard" waited for draft deletion API call.

**Fix:** Dismiss immediately, delete in background:

```swift
Button("Discard", role: .destructive) {
    let draftToDelete = viewModel.discardLocally()
    dismiss()  // Immediate
    if let id = draftToDelete {
        Task { try? await GmailService.shared.deleteDraft(draftId: id) }
    }
}
```

### Problem: Auto-save triggered on programmatic body loads

**Symptoms:** Opening a reply triggered auto-save before user made changes.

**Fix:** Added `isSeedingBody` and `hasUserEdited` flags:

```swift
private func scheduleAutoSave() {
    guard !isSeedingBody, hasUserEdited else { return }
    // ... schedule save
}
```

---

## Console Log Markers

Use `StallLogger.mark()` to trace timing:

```
STALL InboxView.appear t=0.000s
STALL InboxViewModel.computeState.start t=1.987s
STALL EmailDetail.appear t=16.884s
STALL EmailDetail.threadLoaded t=17.110s
STALL EmailDetail.bodySwap t=17.146s
```

Calculate deltas to find bottlenecks:
- `appear → threadLoaded`: Network + parsing time
- `threadLoaded → bodySwap`: Background HTML rendering time

### Better Instrumentation (if needed)

Add logs inside `WKWebViewPool.makeWebView()` to see where stalls come from:

```swift
private func makeWebView() -> WKWebView {
    logger.debug("WKPool.makeWebView START")
    let webView = WKWebView(frame: .zero, configuration: config)
    logger.debug("WKPool.makeWebView END")
    return webView
}
```

---

## Summary

| Area | Status | Notes |
|------|--------|-------|
| Email detail load | ✅ Fast | 190-260ms appear→bodySwap |
| WebKit warmup | ✅ Removed | Was net negative (1s stall, no benefit) |
| Pool reset | ✅ Fixed | No longer loads unnecessary HTML |
| SwiftData isolation | ✅ Fixed | Value types before Task.detached |
| HTML processing | ✅ Off-main | BodyRenderActor does all work |
| Search hydration | ✅ Off-main | Background ModelContext |
| Staged rendering | ✅ Enabled | First 20 rows, then rest |
| Compose/discard | ✅ Fixed | Dismiss immediately, network in background |

---

## Future Considerations

1. **Loading shimmer:** Show email detail skeleton immediately, render body when ready. Perceived performance may be better than waiting.

2. **Measure first-email-open:** Track in analytics to understand real-world cold-start impact.

3. **WebView pool size:** Currently maxSize=3. May need tuning based on memory pressure.
