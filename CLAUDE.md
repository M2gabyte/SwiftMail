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

### Styling / Theming
- Do not apply global modifiers that change control appearance across the app (examples below).
- If a toolbar looks "wrong," assume a **global style leak** first—do not "fix" by wrapping toolbar icons in custom circles/pills.

### Testing
- Do not reintroduce old UI (e.g., tabs) to satisfy tests. Update tests only when explicitly asked.

---

## Design Principles (General)

### 1) Default to Apple-native before inventing UI
- Prefer system primitives and defaults over custom UI.
- If Apple provides a standard pattern, use it even if a custom version seems "cleaner."
- Goal: "looks like it shipped with iOS," not "concept mock."

### 2) Don't fight the OS — follow the current iOS version
- Treat the OS's default visual language as source of truth (e.g., iOS 26 toolbar glass/shared backgrounds).
- Only override system appearance when fixing a real issue (legibility, hierarchy, accessibility), not aesthetics.

### 3) Use SwiftUI primitives; avoid custom chrome
**Use:** `NavigationStack`, `List`, `.toolbar`, `.searchable`, `Menu`, `Picker(.segmented)`, `swipeActions`, `.sheet`

**Avoid:** custom bottom bars, floating buttons, overlay toolbars, any UI that mimics nav bars/toolbars via `ZStack` overlays.

> Clarification: overlays are allowed only for **transient** UI (toasts, banners, skeleton loading), not persistent navigation/actions.

### 4) Toolbars are system toolbars (and should look system)
- Top actions live in `.toolbar` with correct placements (`.topBarTrailing`, etc.)
- Bottom actions live in `ToolbarItemGroup(placement: .bottomBar)`
- Do NOT add custom backgrounds/shadows/clipShapes around toolbar icons.
- Do NOT force toolbar icons to look like older iOS versions.

### 5) Navigation title is the header; don't rebuild it in content
- Use `.navigationTitle` + `.navigationBarTitleDisplayMode(.large)`
- Avoid duplicating the title as a giant `Text` inside the view.
- Mailbox switching uses `.toolbarTitleMenu` rather than a custom picker control.

### 6) Search must be native
- Use `.searchable` for inbox search UX (pull-down drawer behavior).
- Do NOT create separate "Search screens" unless the user explicitly requests a product-level change.
- If you include a search button, it should only focus/activate `.searchable`.

### 7) Custom UI must be quieter than system UI
- Custom controls (e.g., triage chips) must not compete with OS chrome (toolbars, navigation title).
- Prefer subtle emphasis (thin material, light strokes, low-contrast backgrounds) over strong filled capsules.
- Keep the number of high-salience controls per screen low.

### 8) Use system typography, spacing, and motion
- Use Apple font styles (`.headline`, `.subheadline`, `.body`, etc.) and standard paddings.
- Avoid heavy shadows and large custom blur effects unless the OS is already doing it.
- Favor boring defaults; adjust only when there's a clear readability/hierarchy gain.

### 9) Interactions should be standard and fast
- Use native `swipeActions` for row actions (archive, read/unread, etc.).
- Avoid custom gesture recognizers when the platform provides the gesture.
- Optimize for one-handed use without adding non-native affordances.

### 10) Accessibility and Dynamic Type are not optional
- Respect Dynamic Type; avoid fixed heights that truncate content.
- Ensure tappable targets meet minimum size.
- Use semantic labels for icon-only buttons.

### 11) Avoid global styling that causes UI drift
Do not set these globally at the app root / ContentView / shared containers:
- `.buttonStyle(...)`
- `controlSize(...)`
- `buttonBorderShape(...)`
- `.toolbarRole(...)`
- `environment(\.buttonStyle, ...)`
- `environment(\.controlSize, ...)`

If styling is needed, scope it to the smallest possible view.

### 12) Be explicit about platform/version behavior
- When a behavior differs by iOS version, prefer `#available` gates rather than hacks.
- Document any version-specific decisions briefly in code comments.

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
