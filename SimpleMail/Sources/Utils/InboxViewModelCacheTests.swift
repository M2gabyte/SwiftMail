import Foundation

#if DEBUG
/// Debug-only test harness for InboxViewModel section caching.
/// Run via InboxViewModelCacheTests.runAllTests() in debug builds.
@MainActor
enum InboxViewModelCacheTests {

    struct TestResult {
        let name: String
        let passed: Bool
        let message: String
    }

    static func runAllTests() async -> String {
        print("=== InboxViewModel Cache Tests ===")

        var results: [TestResult] = []
        results.append(contentsOf: await testRecomputesAfterFilterChange())
        results.append(contentsOf: await testRecomputesAfterEmailsChange())
        results.append(contentsOf: await testRecomputesAfterTabChange())
        results.append(contentsOf: await testRecomputesAfterFilterVersionChange())

        let passed = results.filter { $0.passed }.count
        let failed = results.filter { !$0.passed }.count

        print("\n=== Results ===")
        for result in results {
            let status = result.passed ? "PASS" : "FAIL"
            print("[\(status)] \(result.name): \(result.message)")
        }

        print("\n\(passed) passed, \(failed) failed")

        if failed > 0 {
            assertionFailure("InboxViewModel cache tests failed")
        }

        return "Passed: \(passed)  Failed: \(failed)"
    }

    // MARK: - Tests

    private static func testRecomputesAfterFilterChange() async -> [TestResult] {
        var results: [TestResult] = []

        let viewModel = InboxViewModel()
        let now = Date()
        let unread = Email(id: "1", threadId: "t1", date: now, isUnread: true)
        let read = Email(id: "2", threadId: "t2", date: now, isUnread: false)
        viewModel.emails = [unread, read]

        viewModel.activeFilter = nil
        let allState = await viewModel.refreshViewStateForTests()
        let allCount = totalEmailCount(allState.sections)

        viewModel.activeFilter = .unread
        let unreadState = await viewModel.refreshViewStateForTests()
        let unreadCount = totalEmailCount(unreadState.sections)

        results.append(TestResult(
            name: "Recompute after activeFilter change",
            passed: allCount == 2 && unreadCount == 1,
            message: "all=\(allCount), unread=\(unreadCount)"
        ))

        return results
    }

    private static func testRecomputesAfterEmailsChange() async -> [TestResult] {
        var results: [TestResult] = []

        let viewModel = InboxViewModel()
        let now = Date()
        let first = Email(id: "1", threadId: "t1", date: now, isUnread: true)
        let second = Email(id: "2", threadId: "t2", date: now, isUnread: true)

        viewModel.emails = [first]
        let initialState = await viewModel.refreshViewStateForTests()
        let initialCount = totalEmailCount(initialState.sections)

        viewModel.emails = [first, second]
        let updatedState = await viewModel.refreshViewStateForTests()
        let updatedCount = totalEmailCount(updatedState.sections)

        results.append(TestResult(
            name: "Recompute after emails change",
            passed: initialCount == 1 && updatedCount == 2,
            message: "initial=\(initialCount), updated=\(updatedCount)"
        ))

        return results
    }

    private static func testRecomputesAfterTabChange() async -> [TestResult] {
        var results: [TestResult] = []

        let viewModel = InboxViewModel()
        let now = Date()
        let nonPrimary = Email(
            id: "nonprimary",
            threadId: "tnonprimary",
            snippet: "FYI",
            subject: "System Update",
            from: "Acme Updates <no-reply@acme.example>",
            date: now
        )
        viewModel.emails = [nonPrimary]

        viewModel.currentTab = .all
        let allState = await viewModel.refreshViewStateForTests()
        let allCount = totalEmailCount(allState.sections)

        viewModel.currentTab = .primary
        let primaryState = await viewModel.refreshViewStateForTests()
        let primaryCount = totalEmailCount(primaryState.sections)

        results.append(TestResult(
            name: "Recompute after tab change",
            passed: allCount == 1 && primaryCount == 0,
            message: "all=\(allCount), primary=\(primaryCount)"
        ))

        return results
    }

    private static func testRecomputesAfterFilterVersionChange() async -> [TestResult] {
        var results: [TestResult] = []

        let viewModel = InboxViewModel()
        let now = Date()
        let blocked = Email(id: "blocked", threadId: "tblocked", from: "Blocked Sender <blocked@example.com>", date: now)
        viewModel.emails = [blocked]

        let beforeState = await viewModel.refreshViewStateForTests()
        let before = totalEmailCount(beforeState.sections)

        let accountEmail = AuthService.shared.currentAccount?.email
        let previousBlocked = AccountDefaults.stringArray(for: "blockedSenders", accountEmail: accountEmail)
        AccountDefaults.setStringArray(["blocked@example.com"], for: "blockedSenders", accountEmail: accountEmail)

        viewModel.refreshFiltersForTest()
        let afterState = await viewModel.refreshViewStateForTests()
        let after = totalEmailCount(afterState.sections)

        AccountDefaults.setStringArray(previousBlocked, for: "blockedSenders", accountEmail: accountEmail)

        results.append(TestResult(
            name: "Recompute after filterVersion change",
            passed: before == 1 && after == 0,
            message: "before=\(before), after=\(after)"
        ))

        return results
    }

    private static func totalEmailCount(_ sections: [EmailSection]) -> Int {
        sections.reduce(0) { $0 + $1.emails.count }
    }
}
#endif
