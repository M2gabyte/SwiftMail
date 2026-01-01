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
