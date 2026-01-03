import XCTest
@testable import SimpleMail

/// Comprehensive tests for the EmailPreviewParser
/// These tests ensure the parser correctly handles all common email patterns
final class EmailPreviewParserTests: XCTestCase {

    // MARK: - Forwarded Message Tests

    func testStripForwardedMessageWithDashes() {
        let input = """
        Here is my response to your question.

        ---------- Forwarded message ---------
        From: John Doe <john@example.com>
        Date: Mon, Jan 1, 2024
        Subject: Original Subject
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertFalse(result.contains("Forwarded message"), "Should strip forwarded block")
        XCTAssertTrue(result.contains("response to your question"), "Should preserve actual content")
    }

    func testStripBeginForwardedMessage() {
        let input = """
        Begin forwarded message:
        From: Jane Smith
        To: Bob Johnson
        This is the forwarded content.
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertFalse(result.contains("Begin forwarded"), "Should strip begin forwarded marker")
    }

    func testContentBeforeForwardedMessage() {
        let input = """
        This is my actual response that should be shown.

        ---------- Forwarded message ---------
        Old forwarded stuff here that should be hidden.
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.contains("actual response"), "Should show content before forward")
        XCTAssertFalse(result.contains("Old forwarded"), "Should hide forwarded content")
    }

    // MARK: - Reply Attribution Tests

    func testStripOnDateWrote() {
        let input = """
        On Mon, Jan 1, 2024 at 3:00 PM John Doe <john@example.com> wrote:
        Thanks for your email. I'll review this tomorrow.
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertFalse(result.contains("wrote:"), "Should strip 'On...wrote:' line")
        XCTAssertTrue(result.contains("Thanks for your email"), "Should preserve actual message")
    }

    func testStripSimpleWroteAttribution() {
        let input = """
        John Doe wrote:
        I agree with your proposal.
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertFalse(result.contains("wrote:"), "Should strip wrote attribution")
        XCTAssertTrue(result.contains("agree with your proposal"), "Should preserve content")
    }

    func testStripReplyHeaders() {
        let input = """
        From: john@example.com
        To: jane@example.com
        Subject: Re: Meeting

        Let's schedule for Tuesday.
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertFalse(result.contains("From:"), "Should strip From header")
        XCTAssertFalse(result.contains("To:"), "Should strip To header")
        XCTAssertTrue(result.contains("schedule for Tuesday"), "Should preserve message")
    }

    // MARK: - Signature Block Tests

    func testStripRFCSignatureDelimiter() {
        let input = """
        Here is my message content.

        --
        John Doe
        CEO, Example Corp
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.contains("message content"), "Should preserve message")
        XCTAssertFalse(result.contains("CEO"), "Should strip signature")
    }

    func testStripBestRegards() {
        let input = """
        I'll send you the report by Friday.

        Best regards,
        John
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.contains("report by Friday"), "Should preserve message")
        XCTAssertFalse(result.contains("Best regards"), "Should strip signature")
    }

    func testStripSentFromDevice() {
        let input = """
        Sounds good, see you tomorrow.

        Sent from my iPhone
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.contains("see you tomorrow"), "Should preserve message")
        XCTAssertFalse(result.contains("Sent from my"), "Should strip device signature")
    }

    func testStripKindRegards() {
        let input = """
        Thank you for the update.

        Kind regards,
        Jane Smith
        Senior Manager
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.contains("Thank you"), "Should preserve message")
        XCTAssertFalse(result.contains("Kind regards"), "Should strip signature")
    }

    // MARK: - Quote Marker Tests

    func testStripQuoteMarkers() {
        let input = """
        I agree with your point.

        > This is quoted text from previous email
        > that should be hidden.
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.contains("agree with your point"), "Should preserve new content")
        XCTAssertFalse(result.contains("quoted text"), "Should strip quoted content")
    }

    func testStripPipeQuotes() {
        let input = """
        That's a great idea.

        | Previous message content
        | More quoted content
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.contains("great idea"), "Should preserve new content")
        XCTAssertFalse(result.contains("Previous message"), "Should strip pipe-quoted content")
    }

    // MARK: - Content Extraction Tests

    func testExtractFirstMeaningfulSentence() {
        let input = """
        This is the first meaningful sentence. This is the second sentence. This is the third sentence that might be too long for a preview.
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.contains("first meaningful sentence"), "Should include first sentence")
        // Should limit preview length
        XCTAssertTrue(result.count < 200, "Should limit preview length")
    }

    func testStripFwdPrefix() {
        let input = "Fwd: This is the actual message content"

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertFalse(result.hasPrefix("Fwd:"), "Should strip Fwd: prefix")
        XCTAssertTrue(result.contains("actual message content"), "Should preserve message")
    }

    func testStripRePrefix() {
        let input = "Re: Response to your question"

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertFalse(result.hasPrefix("Re:"), "Should strip Re: prefix")
        XCTAssertTrue(result.contains("Response to your question"), "Should preserve message")
    }

    // MARK: - Complex Real-World Tests

    func testComplexForwardedEmail() {
        let input = """
        FYI - see below.

        ---------- Forwarded message ---------
        From: John Doe <john@example.com>
        Date: Wed, Dec 1, 2024 at 2:30 PM
        Subject: Q4 Report
        To: Team <team@example.com>

        Please review the attached Q4 report.

        Thanks,
        John
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.contains("FYI"), "Should show the actual message")
        XCTAssertFalse(result.contains("Forwarded message"), "Should hide forwarded block")
        XCTAssertFalse(result.contains("Q4 Report"), "Should hide forwarded content")
    }

    func testComplexReplyWithQuotes() {
        let input = """
        On Tue, Jan 2, 2024 at 10:00 AM Jane Smith <jane@example.com> wrote:

        Yes, I can make it to the meeting on Thursday at 2pm.

        > On Mon, Jan 1, 2024 John Doe wrote:
        > Can you attend the meeting on Thursday?
        >
        > Best regards,
        > John
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.contains("make it to the meeting"), "Should show actual reply")
        XCTAssertFalse(result.contains("wrote:"), "Should strip attribution")
        XCTAssertFalse(result.contains("Can you attend"), "Should strip quoted content")
    }

    func testEmailWithSignatureAndForward() {
        let input = """
        Please see the forwarded message below and let me know your thoughts.

        Thanks,
        Bob

        ---------- Forwarded message ---------
        From: Alice
        Old message content here
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.contains("see the forwarded message"), "Should show actual content")
        XCTAssertFalse(result.contains("Thanks"), "Should strip signature")
        XCTAssertFalse(result.contains("Old message"), "Should strip forwarded content")
    }

    func testNewsletterLikeContent() {
        let input = """
        View this email in your browser

        Welcome to our weekly newsletter! Here are this week's top stories.

        Story 1: Important Update
        Story 2: New Feature Launch

        Unsubscribe | Manage Preferences
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.contains("weekly newsletter") || result.contains("top stories"), "Should show newsletter content")
    }

    // MARK: - Edge Cases

    func testEmptyString() {
        let result = EmailPreviewParser.extractMeaningfulPreview(from: "")
        XCTAssertEqual(result, "", "Should handle empty string")
    }

    func testWhitespaceOnly() {
        let result = EmailPreviewParser.extractMeaningfulPreview(from: "   \n\n   \t  ")
        XCTAssertEqual(result, "", "Should handle whitespace-only string")
    }

    func testShortMessage() {
        let input = "OK"
        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertEqual(result, "OK", "Should preserve short messages")
    }

    func testVeryLongMessage() {
        let input = String(repeating: "This is a very long message. ", count: 50)
        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertTrue(result.count < 200, "Should truncate very long messages")
        XCTAssertTrue(result.count > 0, "Should still return content")
    }

    func testMessageWithOnlySignature() {
        let input = """
        --
        John Doe
        CEO, Example Corp
        john@example.com
        """

        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        // Should handle gracefully - might be empty or show minimal content
        XCTAssertTrue(result.count < 50, "Should not show full signature as content")
    }

    // MARK: - Whitespace Normalization Tests

    func testCollapseMultipleSpaces() {
        let input = "This   has    multiple     spaces"
        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertFalse(result.contains("  "), "Should collapse multiple spaces")
    }

    func testCollapseMultipleNewlines() {
        let input = "Line 1\n\n\n\nLine 2"
        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertFalse(result.contains("\n\n\n"), "Should collapse excessive newlines")
    }

    func testTrimWhitespace() {
        let input = "   Content with leading and trailing spaces   "
        let result = EmailPreviewParser.extractMeaningfulPreview(from: input)
        XCTAssertFalse(result.hasPrefix(" "), "Should trim leading whitespace")
        XCTAssertFalse(result.hasSuffix(" "), "Should trim trailing whitespace")
    }
}
