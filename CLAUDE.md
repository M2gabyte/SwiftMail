# Claude Code Instructions for SimpleMail (Swift)

## General Principles

- **Delegate to sub-agents** when tasks can be broken down
- **Parallelize when possible** - launch multiple agents concurrently for independent tasks
- **Provide effective context** - give agents enough information to work autonomously

## Task Management

- **Always use todo lists** for any multi-step task. This helps track progress and ensures nothing gets missed.
- If the user sends a request while I'm working on something, always add it to the todo list, even if it's a question that needs to be answered. This ensures nothing gets lost and the user can see that their request has been acknowledged.
- Mark todos as in_progress when starting work, and completed immediately when done.

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

### Test Location
UI tests live in `SimpleMailUITests/`:
- `SimpleMailUITests.swift` - Main UI automation tests
- `SimpleMailUITestsLaunchTests.swift` - Launch performance tests

### Current Test Count: 18 UI tests
- App launch and login detection
- Tab bar navigation (Inbox, Briefing, Settings)
- Pull-to-refresh, search, compose
- Email detail navigation
- Swipe actions
- Launch performance

### When NOT to Run Tests
- Don't run tests proactively - wait for user to ask
- Tests are a regression safety net, not a bug-finding tool
- Manual testing by the user is more valuable for this project

## Documentation Updates

After completing major updates (new features, refactors, architectural changes), update:

- **ARCHITECTURE.md** - Update relevant sections when:
  - Adding new screens, services, or components
  - Changing data flow or state management patterns
  - Modifying the project structure
  - Adding new dependencies
  - Changing API integrations
  - Bump version number and add changelog entry

## Performance Best Practices

### Parallelize API Calls
**Always parallelize independent API calls** for speed. Use Swift's structured concurrency.

**Bad - Sequential (slow):**
```swift
for id in ids {
    let result = try await fetchSomething(id)  // Waits for each one
    results.append(result)
}
```

**Good - Parallel with TaskGroup:**
```swift
try await withThrowingTaskGroup(of: Result.self) { group in
    for id in ids {
        group.addTask { try await fetchSomething(id) }
    }
    for try await result in group {
        results.append(result)
    }
}
```

**Good - Parallel with batching (rate limiting):**
```swift
let batchSize = 3
for batch in ids.chunked(into: batchSize) {
    let batchResults = try await withThrowingTaskGroup(of: Result.self) { group in
        for id in batch {
            group.addTask { try await fetchSomething(id) }
        }
        return try await group.reduce(into: []) { $0.append($1) }
    }
    results.append(contentsOf: batchResults)
}
```

This pattern is used throughout `GmailService.swift` for fetching emails and threads.

### Cached DateFormatters
**Never create DateFormatter inside loops or cell rendering.** Use static cached formatters:

```swift
private enum DateFormatters {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
```

### Actor Isolation
- Use `actor` for thread-safe services (GmailService, AvatarService, PeopleService)
- Use `nonisolated` for pure parsing functions that don't access actor state
- Use Sendable DTOs for cross-actor data transfer (SwiftData models aren't Sendable)

## Git Conventions

### Commit Messages
```
Short summary of change (imperative mood)

Optional longer description of what and why.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
```

### Commit Best Practices
- Use HEREDOC for multi-line commit messages to preserve formatting
- Don't commit `.xcuserstate` files (user-specific Xcode state)
- Don't commit `.build/` directories

## Design Principles

### 1. Default to "Apple-native" before inventing UI
- Prefer system primitives and defaults over custom UI
- If Apple provides a standard pattern, use it even if a custom version seems "cleaner"
- Goal is "looks like it shipped with iOS", not "looks like a concept mock"

### 2. Don't fight the OS — follow current iOS conventions
- Treat the OS's default visual language as source of truth (e.g., iOS 26 glass/shared toolbar backgrounds)
- Only override system appearance when it fixes a clear usability issue (legibility, hierarchy, accessibility), not for aesthetics

### 3. Use SwiftUI primitives; avoid custom chrome
**Use:** `NavigationStack`, `List`, `toolbar`, `.searchable`, `Menu`, `Picker(.segmented)`, `swipeActions`, `.sheet`

**Avoid:** custom bottom bars, floating action buttons, overlay toolbars, any UI that mimics nav bars/toolbars via ZStack overlays

### 4. Toolbars are system toolbars (and should look system)
- Top actions live in `.toolbar` with correct placements (`.topBarTrailing`, etc.)
- Bottom actions live in `ToolbarItemGroup(placement: .bottomBar)`
- Do NOT add custom backgrounds/shadows/clipShapes around toolbar icons
- Do NOT apply global button styling that changes toolbar item appearance

### 5. Navigation title is the header; don't rebuild it in content
- Use `.navigationTitle` + `.navigationBarTitleDisplayMode(.large)`
- Avoid duplicating the title as a giant Text inside the view
- Mailbox switching uses `.toolbarTitleMenu` rather than a custom picker control

### 6. Search must be native
- Use `.searchable` for search UX (pull-down drawer behavior)
- Do NOT create separate "Search screens" unless there is a compelling product requirement (rare)
- If you include a search button, it should only focus/activate the `.searchable` field

### 7. Custom UI should be quieter than system UI
- Custom controls (e.g., triage chips) must not compete with OS chrome (toolbars, navigation title)
- Prefer subtle emphasis (thin material, light strokes, low-contrast backgrounds) over strong filled capsules
- Keep the number of high-salience controls per screen low

### 8. Use system typography, spacing, and motion
- Use Apple font styles (`.headline`, `.subheadline`, `.body`, etc.) and standard paddings
- Avoid heavy shadows and large custom blur effects unless the OS is already doing it
- Favor "boring" defaults; adjust only when there's a clear readability/hierarchy gain

### 9. Interactions should be standard and fast
- Use native `swipeActions` for row actions (archive, read/unread, etc.)
- Avoid custom gesture recognizers when the platform provides the gesture
- Optimize for one-handed use without adding non-native affordances

### 10. Accessibility and dynamic type are not optional
- Respect Dynamic Type; avoid fixed heights that truncate content
- Ensure tappable targets meet minimum size
- Use semantic labels for icon-only buttons

### 11. Avoid global styling that causes UI drift
- Do NOT set `.buttonStyle`, `controlSize`, `buttonBorderShape`, or `toolbarRole` globally at the app root unless absolutely required
- If styling is needed, scope it to the smallest possible view

### 12. Be explicit about platform/version behavior
- When a behavior differs by iOS version, prefer `#available` gates rather than hacks
- Document any version-specific decisions briefly in code comments

## Code Style

### SwiftUI Views
- Use `@State` for local view state
- Use `@StateObject` for view models (or `@State` with `@Observable`)
- Add `.accessibilityIdentifier()` to key interactive elements for UI testing

### Error Handling
- Use OSLog for logging, not print()
- Handle errors gracefully with user-facing feedback
- Use `do/catch` with proper error logging, not silent `try?`

## Project-Specific Notes

### Apple Intelligence Summaries
- Uses FoundationModels `LanguageModelSession` on iOS 26+
- Falls back to extractive summarization on older iOS
- Threshold: 300+ characters of plain text (not HTML)

### HTML Email Security
- HTMLSanitizer strips scripts, iframes, event handlers
- Remote images blocked by default (user can load manually)
- Zero-width characters removed to fix rendering issues
