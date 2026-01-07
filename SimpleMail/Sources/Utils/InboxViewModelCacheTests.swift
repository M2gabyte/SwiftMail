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

    static func runAllTests() -> String {
        print("=== InboxViewModel Cache Tests ===")

        var results: [TestResult] = []
        results.append(contentsOf: testRecomputesAfterFilterChange())
        results.append(contentsOf: testRecomputesAfterEmailsChange())
        results.append(contentsOf: testRecomputesAfterTabChange())
        results.append(contentsOf: testRecomputesAfterPinnedChange())
        results.append(contentsOf: testRecomputesAfterFilterVersionChange())

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

    private static func testRecomputesAfterFilterChange() -> [TestResult] {
        var results: [TestResult] = []

        let viewModel = InboxViewModel()
        let now = Date()
        let unread = Email(id: "1", threadId: "t1", date: now, isUnread: true)
        let read = Email(id: "2", threadId: "t2", date: now, isUnread: false)
        viewModel.emails = [unread, read]

        viewModel.activeFilter = nil
        let allCount = totalEmailCount(viewModel.emailSections)

        viewModel.activeFilter = .unread
        let unreadCount = totalEmailCount(viewModel.emailSections)

        results.append(TestResult(
            name: "Recompute after activeFilter change",
            passed: allCount == 2 && unreadCount == 1,
            message: "all=\(allCount), unread=\(unreadCount)"
        ))

        return results
    }

    private static func testRecomputesAfterEmailsChange() -> [TestResult] {
        var results: [TestResult] = []

        let viewModel = InboxViewModel()
        let now = Date()
        let first = Email(id: "1", threadId: "t1", date: now, isUnread: true)
        let second = Email(id: "2", threadId: "t2", date: now, isUnread: true)

        viewModel.emails = [first]
        let initialCount = totalEmailCount(viewModel.emailSections)

        viewModel.emails = [first, second]
        let updatedCount = totalEmailCount(viewModel.emailSections)

        results.append(TestResult(
            name: "Recompute after emails change",
            passed: initialCount == 1 && updatedCount == 2,
            message: "initial=\(initialCount), updated=\(updatedCount)"
        ))

        return results
    }

    private static func testRecomputesAfterTabChange() -> [TestResult] {
        var results: [TestResult] = []

        let viewModel = InboxViewModel()
        let now = Date()
        let nonPrimary = Email(
            id: "nonprimary",
            threadId: "tnonprimary",
            subject: "System Update",
            snippet: "FYI",
            from: "Acme Updates <no-reply@acme.example>",
            date: now
        )
        viewModel.emails = [nonPrimary]

        viewModel.currentTab = .all
        let allCount = totalEmailCount(viewModel.emailSections)

        viewModel.currentTab = .primary
        let primaryCount = totalEmailCount(viewModel.emailSections)

        results.append(TestResult(
            name: "Recompute after tab change",
            passed: allCount == 1 && primaryCount == 0,
            message: "all=\(allCount), primary=\(primaryCount)"
        ))

        return results
    }

    private static func testRecomputesAfterPinnedChange() -> [TestResult] {
        var results: [TestResult] = []

        let viewModel = InboxViewModel()
        let now = Date()
        let invoice = Email(
            id: "money",
            threadId: "tmoney",
            subject: "Invoice due",
            snippet: "Payment due",
            from: "Billing <billing@example.com>",
            date: now
        )
        viewModel.emails = [invoice]

        viewModel.currentTab = .pinned
        viewModel.pinnedTabOption = .money
        let moneyCount = totalEmailCount(viewModel.emailSections)

        viewModel.pinnedTabOption = .deadlines
        let deadlineCount = totalEmailCount(viewModel.emailSections)

        results.append(TestResult(
            name: "Recompute after pinned option change",
            passed: moneyCount == 1 && deadlineCount == 0,
            message: "money=\(moneyCount), deadlines=\(deadlineCount)"
        ))

        return results
    }

    private static func testRecomputesAfterFilterVersionChange() -> [TestResult] {
        var results: [TestResult] = []

        let viewModel = InboxViewModel()
        let now = Date()
        let blocked = Email(id: "blocked", threadId: "tblocked", from: "Blocked Sender <blocked@example.com>", date: now)
        viewModel.emails = [blocked]

        let before = totalEmailCount(viewModel.emailSections)

        let accountEmail = AuthService.shared.currentAccount?.email
        let previousBlocked = AccountDefaults.stringArray(for: "blockedSenders", accountEmail: accountEmail)
        AccountDefaults.setStringArray(["blocked@example.com"], for: "blockedSenders", accountEmail: accountEmail)

        viewModel.refreshFiltersForTest()
        let after = totalEmailCount(viewModel.emailSections)

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
