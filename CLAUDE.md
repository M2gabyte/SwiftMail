# Claude Code Instructions for SimpleMail (Swift)

This file defines **durable rules** for how to work in this repo. When in doubt: choose the most "shipped with iOS" solution, minimize custom chrome, and avoid global styling that causes UI drift.

---

## Operating Mode

- Delegate to sub-agents when tasks can be broken down.
- Parallelize independent work streams when possible.
- Provide enough context in each change so the next iteration is straightforward.

---

## Apple Documentation

Use the `applekb` CLI tool to search Apple developer documentation when working with iOS/macOS APIs:

```bash
applekb query "WKWebView contentInset"
applekb query "safeAreaInset SwiftUI"
```

Use this for UIKit, SwiftUI, WebKit, and other Apple framework questions.

---

## Task Management

- Always use a TODO list for any multi-step task.
- If the user sends a request mid-task, add it to the TODO list immediately.
- Mark todos `in_progress` when starting work, and `completed` immediately when done.

---

## Source of Truth: Current Product Decisions

These are **decisions**, not suggestions. Do not "improve" them without an explicit user request.

### Inbox (Native Triage)
- App is single-view (no TabView).
- Inbox is a single `List` with a **scrollable** header block (not pinned, not overlay).
- Search uses a **bottom command surface** (`BottomCommandSurface`) matching iOS 26 Mail's bottom search pattern. Tapping search opens a full-screen `SearchOverlayView` with recent searches and live results.
- Mailbox switching uses a **location sheet** triggered from the top-left toolbar button.
- Top-right is `gearshape` opening **Settings** as a sheet.
- iOS 26+: accept system "Liquid Glass" styling for toolbars; do not fight it.
- Triage filters stay as chips in the header, visually quiet (no loud filled capsules competing with toolbar glass).

---

## Hard Constraints (Must Not Violate)

### UI / Navigation
- Bottom command surface (`BottomCommandSurface`) is the only custom bottom bar allowed - contains search, compose, and filter actions.
- No floating action buttons.
- No persistent UI chrome implemented via `ZStack` overlays (no overlay toolbars, overlay nav bars) - except the bottom command surface.
- Search overlay (`SearchOverlayView`) is the designated search experience - do not add additional search screens.
- Do not rebuild the navigation title inside content.

### Feature Changes
- **NEVER remove features or functionality without explicit user permission.**
- If a feature causes issues, fix the issue - don't remove the feature.
- If you're uncertain how to fix something, ask the user before removing functionality.

### Testing
- Do not reintroduce old UI (e.g., tabs) to satisfy tests. Update tests only when explicitly asked.

---

## Testing

This project has XCUITest infrastructure. **Only run tests when explicitly asked.**

### Running Tests
```bash
# Command line
xcodebuild test -project SimpleMail.xcodeproj -scheme SimpleMail \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SimpleMailUITests

# Xcode: ⌘+U
```
