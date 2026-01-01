# Claude Code Instructions for SimpleMail (Swift)

This file defines **durable rules** for how to work in this repo. When in doubt: choose the most "shipped with iOS" solution, minimize custom chrome, and avoid global styling that causes UI drift.

---

## Operating Mode

- Delegate to sub-agents when tasks can be broken down.
- Parallelize independent work streams when possible.
- Provide enough context in each change so the next iteration is straightforward.

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
- Search is native `.searchable`. Any search button only **focuses** `.searchable`; no custom search screen.
- Mailbox switching uses the **navigation title menu** (`.toolbarTitleMenu`), not a custom picker in the header.
- Top-right is `ellipsis.circle` opening a `Menu` that includes **Settings** (Settings opens as a sheet).
- iOS 26+: accept system "glass/shared background" styling for toolbars; do not fight it.
- Triage filters stay as chips, but must be visually quiet (no loud filled capsules competing with toolbar glass).

---

## Hard Constraints (Must Not Violate)

### UI / Navigation
- No custom bottom bars.
- No floating action buttons.
- No persistent UI chrome implemented via `ZStack` overlays (no overlay toolbars, overlay nav bars).
- No separate "Search screen" for inbox search. Use `.searchable`.
- Do not rebuild the navigation title inside content.

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
