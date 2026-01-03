import Foundation

#if DEBUG
/// Debug-only test harness for EmailPreviewNormalizer
/// Run via EmailPreviewNormalizerTests.runAllTests() in debug builds
enum EmailPreviewNormalizerTests {

    struct TestResult {
        let name: String
        let passed: Bool
        let message: String
    }

    /// Run all tests and log results
    static func runAllTests() {
        print("=== EmailPreviewNormalizer Tests ===")

        var results: [TestResult] = []

        // Subject normalization tests
        results.append(contentsOf: testSubjectNormalization())

        // Snippet normalization tests
        results.append(contentsOf: testSnippetNormalization())

        // Summary
        let passed = results.filter { $0.passed }.count
        let failed = results.filter { !$0.passed }.count

        print("\n=== Results ===")
        for result in results {
            let status = result.passed ? "PASS" : "FAIL"
            print("[\(status)] \(result.name): \(result.message)")
        }

        print("\n\(passed) passed, \(failed) failed")

        if failed > 0 {
            assertionFailure("EmailPreviewNormalizer tests failed")
        }
    }

    // MARK: - Subject Tests

    private static func testSubjectNormalization() -> [TestResult] {
        var results: [TestResult] = []

        // Test 1: Simple Fwd: prefix
        let test1Input = "Fwd: Get more from Claude"
        let test1Expected = "Get more from Claude"
        let test1Result = EmailPreviewNormalizer.normalizeSubjectForDisplay(test1Input)
        results.append(TestResult(
            name: "Subject: Remove Fwd:",
            passed: test1Result == test1Expected,
            message: "'\(test1Input)' -> '\(test1Result)' (expected: '\(test1Expected)')"
        ))

        // Test 2: Mixed Re: Fw: prefixes
        let test2Input = "RE: Fw: hello"
        let test2Expected = "hello"
        let test2Result = EmailPreviewNormalizer.normalizeSubjectForDisplay(test2Input)
        results.append(TestResult(
            name: "Subject: Remove RE: Fw:",
            passed: test2Result == test2Expected,
            message: "'\(test2Input)' -> '\(test2Result)' (expected: '\(test2Expected)')"
        ))

        // Test 3: Multiple nested prefixes
        let test3Input = "Fwd: Re: Fwd: Hello World"
        let test3Expected = "Hello World"
        let test3Result = EmailPreviewNormalizer.normalizeSubjectForDisplay(test3Input)
        results.append(TestResult(
            name: "Subject: Remove multiple prefixes",
            passed: test3Result == test3Expected,
            message: "'\(test3Input)' -> '\(test3Result)' (expected: '\(test3Expected)')"
        ))

        // Test 4: No prefix (should be unchanged)
        let test4Input = "Meeting tomorrow at 3pm"
        let test4Expected = "Meeting tomorrow at 3pm"
        let test4Result = EmailPreviewNormalizer.normalizeSubjectForDisplay(test4Input)
        results.append(TestResult(
            name: "Subject: No prefix unchanged",
            passed: test4Result == test4Expected,
            message: "'\(test4Input)' -> '\(test4Result)' (expected: '\(test4Expected)')"
        ))

        // Test 5: Case variations
        let test5Input = "FWD: RE: fwd: re: Test"
        let test5Expected = "Test"
        let test5Result = EmailPreviewNormalizer.normalizeSubjectForDisplay(test5Input)
        results.append(TestResult(
            name: "Subject: Case-insensitive",
            passed: test5Result == test5Expected,
            message: "'\(test5Input)' -> '\(test5Result)' (expected: '\(test5Expected)')"
        ))

        // Test 6: Extra whitespace
        let test6Input = "Fwd:  Re:   Hello"
        let test6Expected = "Hello"
        let test6Result = EmailPreviewNormalizer.normalizeSubjectForDisplay(test6Input)
        results.append(TestResult(
            name: "Subject: Handle extra whitespace",
            passed: test6Result == test6Expected,
            message: "'\(test6Input)' -> '\(test6Result)' (expected: '\(test6Expected)')"
        ))

        return results
    }

    // MARK: - Snippet Tests

    private static func testSnippetNormalization() -> [TestResult] {
        var results: [TestResult] = []

        // Test 1: Forwarded message separator
        let test1Input = """
        ---------- Forwarded message ----------
        From: John Doe <john@example.com>
        Date: Jan 1, 2024
        Subject: Hello

        Here is the actual message content.
        """
        let test1Result = EmailPreviewNormalizer.normalizeSnippetForDisplay(test1Input)
        let test1Passed = !test1Result.contains("Forwarded message") &&
                          !test1Result.contains("From:") &&
                          test1Result.contains("Here is the actual message content")
        results.append(TestResult(
            name: "Snippet: Remove forwarded header",
            passed: test1Passed,
            message: "Result: '\(test1Result)'"
        ))

        // Test 2: Quote attribution stops scanning
        let test2Input = """
        Thanks for letting me know.

        On Jan 1, 2024, John Doe wrote:
        > Original message here
        > More original content
        """
        let test2Result = EmailPreviewNormalizer.normalizeSnippetForDisplay(test2Input)
        let test2Passed = test2Result.contains("Thanks for letting me know") &&
                          !test2Result.contains("On Jan") &&
                          !test2Result.contains("Original message")
        results.append(TestResult(
            name: "Snippet: Stop at quote attribution",
            passed: test2Passed,
            message: "Result: '\(test2Result)'"
        ))

        // Test 3: Email headers filtered
        let test3Input = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Test Subject
        Date: January 1, 2024

        This is the actual email body content.
        """
        let test3Result = EmailPreviewNormalizer.normalizeSnippetForDisplay(test3Input)
        let test3Passed = test3Result.contains("This is the actual email body content") &&
                          !test3Result.lowercased().contains("from:") &&
                          !test3Result.lowercased().contains("to:")
        results.append(TestResult(
            name: "Snippet: Remove email headers",
            passed: test3Passed,
            message: "Result: '\(test3Result)'"
        ))

        // Test 4: Quoted lines filtered
        let test4Input = """
        I agree with this.
        > Previous message
        > More quoted text
        """
        let test4Result = EmailPreviewNormalizer.normalizeSnippetForDisplay(test4Input)
        let test4Passed = test4Result.contains("I agree with this") &&
                          !test4Result.contains("Previous message")
        results.append(TestResult(
            name: "Snippet: Remove quoted lines",
            passed: test4Passed,
            message: "Result: '\(test4Result)'"
        ))

        // Test 5: Dash separators filtered
        let test5Input = """
        ---------------------------------
        This is the content after dashes.
        """
        let test5Result = EmailPreviewNormalizer.normalizeSnippetForDisplay(test5Input)
        let test5Passed = test5Result.contains("This is the content after dashes") &&
                          !test5Result.contains("---")
        results.append(TestResult(
            name: "Snippet: Remove dash separators",
            passed: test5Passed,
            message: "Result: '\(test5Result)'"
        ))

        // Test 6: Original Message header
        let test6Input = """
        -----Original Message-----
        From: Someone
        Sent: Today

        The real content is here.
        """
        let test6Result = EmailPreviewNormalizer.normalizeSnippetForDisplay(test6Input)
        let test6Passed = test6Result.contains("The real content is here") &&
                          !test6Result.contains("Original Message")
        results.append(TestResult(
            name: "Snippet: Remove Original Message header",
            passed: test6Passed,
            message: "Result: '\(test6Result)'"
        ))

        // Test 7: Truncation with ellipsis
        let test7Input = String(repeating: "This is a very long message that should be truncated. ", count: 10)
        let test7Result = EmailPreviewNormalizer.normalizeSnippetForDisplay(test7Input)
        let test7Passed = test7Result.count <= 143 && test7Result.hasSuffix("...")
        results.append(TestResult(
            name: "Snippet: Truncate long content",
            passed: test7Passed,
            message: "Length: \(test7Result.count), ends with '...': \(test7Result.hasSuffix("..."))"
        ))

        // Test 8: Whitespace collapse
        let test8Input = "Hello    world   with    spaces"
        let test8Result = EmailPreviewNormalizer.normalizeSnippetForDisplay(test8Input)
        let test8Passed = test8Result == "Hello world with spaces"
        results.append(TestResult(
            name: "Snippet: Collapse whitespace",
            passed: test8Passed,
            message: "Result: '\(test8Result)'"
        ))

        // Test 9: Skip X-headers
        let test9Input = """
        X-Mailer: SomeSoftware
        X-Priority: 1
        Content-Type: text/plain

        Actual message content here.
        """
        let test9Result = EmailPreviewNormalizer.normalizeSnippetForDisplay(test9Input)
        let test9Passed = test9Result.contains("Actual message content") &&
                          !test9Result.contains("X-Mailer")
        results.append(TestResult(
            name: "Snippet: Skip X-headers",
            passed: test9Passed,
            message: "Result: '\(test9Result)'"
        ))

        return results
    }
}
#endif
