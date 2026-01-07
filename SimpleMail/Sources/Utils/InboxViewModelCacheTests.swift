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

    static func runAllTests() {
        print("=== InboxViewModel Cache Tests ===")

        var results: [TestResult] = []
        results.append(contentsOf: testRecomputesAfterFilterChange())
        results.append(contentsOf: testRecomputesAfterEmailsChange())

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

    private static func totalEmailCount(_ sections: [EmailSection]) -> Int {
        sections.reduce(0) { $0 + $1.emails.count }
    }
}
#endif
