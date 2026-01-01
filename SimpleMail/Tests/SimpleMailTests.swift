import XCTest
@testable import SimpleMail

// MARK: - HTML Sanitizer Tests

final class HTMLSanitizerTests: XCTestCase {

    // MARK: - Script Tag Removal

    func testRemovesScriptTags() throws {
        let html = "<p>Hello</p><script>alert('xss')</script><p>World</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<script"))
        XCTAssertFalse(result.contains("alert"))
        XCTAssertTrue(result.contains("<p>Hello</p>"))
        XCTAssertTrue(result.contains("<p>World</p>"))
    }

    func testRemovesScriptTagsWithAttributes() throws {
        let html = "<script type=\"text/javascript\" src=\"evil.js\"></script>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<script"))
    }

    func testRemovesMultilineScripts() throws {
        let html = """
        <script>
            var x = 1;
            document.cookie = x;
        </script>
        """
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<script"))
        XCTAssertFalse(result.contains("document.cookie"))
    }

    // MARK: - Event Handler Removal

    func testRemovesOnClickHandler() throws {
        let html = "<button onclick=\"stealCookies()\">Click me</button>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("onclick"))
        XCTAssertFalse(result.contains("stealCookies"))
        XCTAssertTrue(result.contains("<button"))
    }

    func testRemovesOnErrorHandler() throws {
        let html = "<img src=\"x\" onerror=\"alert('xss')\">"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("onerror"))
        XCTAssertFalse(result.contains("alert"))
    }

    func testRemovesOnLoadHandler() throws {
        let html = "<body onload=\"malicious()\">"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("onload"))
        XCTAssertFalse(result.contains("malicious"))
    }

    func testRemovesOnMouseOverHandler() throws {
        let html = "<div onmouseover=\"evil()\">Hover me</div>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("onmouseover"))
    }

    // MARK: - JavaScript URL Removal

    func testBlocksJavascriptURLs() throws {
        let html = "<a href=\"javascript:alert('xss')\">Click</a>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("javascript:"))
        XCTAssertTrue(result.contains("blocked:"))
    }

    func testBlocksJavascriptURLsCaseInsensitive() throws {
        let html = "<a href=\"JAVASCRIPT:alert('xss')\">Click</a>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.lowercased().contains("javascript:"))
    }

    func testBlocksJavascriptURLsWithSpaces() throws {
        let html = "<a href=\"javascript :alert('xss')\">Click</a>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("blocked"))
    }

    // MARK: - Iframe Removal

    func testRemovesIframeTags() throws {
        let html = "<p>Before</p><iframe src=\"evil.com\"></iframe><p>After</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<iframe"))
        XCTAssertFalse(result.contains("</iframe>"))
        XCTAssertTrue(result.contains("<p>Before</p>"))
        XCTAssertTrue(result.contains("<p>After</p>"))
    }

    func testRemovesSelfClosingIframe() throws {
        let html = "<iframe src=\"evil.com\"/>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<iframe"))
    }

    // MARK: - Object/Embed Removal

    func testRemovesObjectTags() throws {
        let html = "<object data=\"malware.swf\"></object>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<object"))
        XCTAssertFalse(result.contains("</object>"))
    }

    func testRemovesEmbedTags() throws {
        let html = "<embed src=\"malware.swf\">"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<embed"))
    }

    // MARK: - Form Tag Replacement

    func testReplacesFormTags() throws {
        let html = "<form action=\"phishing.com\"><input name=\"password\"></form>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<form"))
        XCTAssertFalse(result.contains("</form>"))
        XCTAssertTrue(result.contains("<div class=\"blocked-form\">"))
        XCTAssertTrue(result.contains("</div>"))
    }

    // MARK: - Safe Content Preservation

    func testPreservesSafeHTML() throws {
        let html = "<p>Hello <strong>World</strong></p><a href=\"https://example.com\">Link</a>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertEqual(result, html)
    }

    func testPreservesStyleTags() throws {
        let html = "<style>.red { color: red; }</style><p class=\"red\">Text</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("<style>"))
    }

    func testPreservesImages() throws {
        let html = "<img src=\"https://example.com/image.jpg\" alt=\"Image\">"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("<img"))
        XCTAssertTrue(result.contains("src="))
    }

    // MARK: - Image Blocking Tests

    func testBlockImagesReplacesRemoteSrc() throws {
        let html = "<img src=\"https://tracker.com/pixel.gif\">"
        let result = HTMLSanitizer.blockImages(html)
        // The original src= should be replaced with data-blocked-src=
        // and a new src= should point to the placeholder data URI
        XCTAssertTrue(result.contains("data-blocked-src=\"https://tracker.com"))
        XCTAssertTrue(result.contains("src=\"data:image/gif;base64"))
        XCTAssertFalse(result.contains(" src=\"https://tracker.com"))
    }

    func testBlockImagesHandlesHttpImages() throws {
        let html = "<img src=\"http://example.com/image.jpg\">"
        let result = HTMLSanitizer.blockImages(html)
        XCTAssertTrue(result.contains("data-blocked-src=\"http://example.com"))
    }

    func testBlockImagesPreservesAltAndOtherAttributes() throws {
        let html = "<img class=\"photo\" src=\"https://example.com/img.jpg\" alt=\"Photo\">"
        let result = HTMLSanitizer.blockImages(html)
        XCTAssertTrue(result.contains("class=\"photo\""))
        XCTAssertTrue(result.contains("alt=\"Photo\""))
    }

    // MARK: - Edge Cases

    func testHandlesEmptyString() throws {
        let html = ""
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertEqual(result, "")
    }

    func testHandlesPlainText() throws {
        let text = "Just plain text with no HTML"
        let result = HTMLSanitizer.sanitize(text)
        XCTAssertEqual(result, text)
    }

    func testHandlesNestedMaliciousContent() throws {
        let html = "<div><script>evil()</script><p onclick=\"bad()\">Text</p></div>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<script"))
        XCTAssertFalse(result.contains("onclick"))
        XCTAssertTrue(result.contains("<div>"))
        XCTAssertTrue(result.contains("<p"))
    }
}

// MARK: - Account Defaults Tests

final class AccountDefaultsTests: XCTestCase {

    let testAccountEmail = "test@example.com"
    let testKey = "testKey"

    override func setUp() {
        super.setUp()
        // Clean up any existing test data
        AccountDefaults.remove(key: testKey, accountEmail: testAccountEmail)
        AccountDefaults.remove(key: testKey, accountEmail: nil as String?)
    }

    override func tearDown() {
        // Clean up after tests
        AccountDefaults.remove(key: testKey, accountEmail: testAccountEmail)
        AccountDefaults.remove(key: testKey, accountEmail: nil as String?)
        super.tearDown()
    }

    // MARK: - String Tests

    func testSetAndGetString() throws {
        let value = "test value"
        AccountDefaults.setString(value, for: testKey, accountEmail: testAccountEmail)
        let result = AccountDefaults.string(for: testKey, accountEmail: testAccountEmail)
        XCTAssertEqual(result, value)
    }

    func testGetStringReturnsNilWhenNotSet() throws {
        let result = AccountDefaults.string(for: "nonexistent", accountEmail: testAccountEmail)
        XCTAssertNil(result)
    }

    func testStringsAreAccountScoped() throws {
        let value1 = "account1 value"
        let value2 = "account2 value"

        AccountDefaults.setString(value1, for: testKey, accountEmail: "account1@test.com")
        AccountDefaults.setString(value2, for: testKey, accountEmail: "account2@test.com")

        XCTAssertEqual(AccountDefaults.string(for: testKey, accountEmail: "account1@test.com"), value1)
        XCTAssertEqual(AccountDefaults.string(for: testKey, accountEmail: "account2@test.com"), value2)

        // Clean up
        AccountDefaults.remove(key: testKey, accountEmail: "account1@test.com")
        AccountDefaults.remove(key: testKey, accountEmail: "account2@test.com")
    }

    // MARK: - Bool Tests

    func testSetAndGetBool() throws {
        AccountDefaults.setBool(true, for: testKey, accountEmail: testAccountEmail)
        XCTAssertTrue(AccountDefaults.bool(for: testKey, accountEmail: testAccountEmail))

        AccountDefaults.setBool(false, for: testKey, accountEmail: testAccountEmail)
        XCTAssertFalse(AccountDefaults.bool(for: testKey, accountEmail: testAccountEmail))
    }

    func testGetBoolDefaultsToFalse() throws {
        let result = AccountDefaults.bool(for: "nonexistent", accountEmail: testAccountEmail)
        XCTAssertFalse(result)
    }

    // MARK: - Date Tests

    func testSetAndGetDate() throws {
        let date = Date()
        AccountDefaults.setDate(date, for: testKey, accountEmail: testAccountEmail)
        let result = AccountDefaults.date(for: testKey, accountEmail: testAccountEmail)
        XCTAssertNotNil(result)
        // Compare with some tolerance for floating point
        XCTAssertEqual(result!.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testGetDateReturnsNilWhenNotSet() throws {
        let result = AccountDefaults.date(for: "nonexistent", accountEmail: testAccountEmail)
        XCTAssertNil(result)
    }

    // MARK: - Data Tests

    func testSetAndGetData() throws {
        let data = "test data".data(using: .utf8)!
        AccountDefaults.setData(data, for: testKey, accountEmail: testAccountEmail)
        let result = AccountDefaults.data(for: testKey, accountEmail: testAccountEmail)
        XCTAssertEqual(result, data)
    }

    // MARK: - String Array Tests

    func testSetAndGetStringArray() throws {
        let array = ["one", "two", "three"]
        AccountDefaults.setStringArray(array, for: testKey, accountEmail: testAccountEmail)
        let result = AccountDefaults.stringArray(for: testKey, accountEmail: testAccountEmail)
        XCTAssertEqual(result, array)
    }

    func testGetStringArrayReturnsEmptyWhenNotSet() throws {
        let result = AccountDefaults.stringArray(for: "nonexistent", accountEmail: testAccountEmail)
        XCTAssertEqual(result, [])
    }

    // MARK: - Nil Account Email Tests

    func testWorksWithNilAccountEmail() throws {
        let value = "global value"
        let nilAccount: String? = nil
        AccountDefaults.setString(value, for: testKey, accountEmail: nilAccount)
        let result = AccountDefaults.string(for: testKey, accountEmail: nilAccount)
        XCTAssertEqual(result, value)
    }

    func testNilAndSpecificAccountAreSeparate() throws {
        let globalValue = "global"
        let accountValue = "account specific"
        let nilAccount: String? = nil

        AccountDefaults.setString(globalValue, for: testKey, accountEmail: nilAccount)
        AccountDefaults.setString(accountValue, for: testKey, accountEmail: testAccountEmail)

        XCTAssertEqual(AccountDefaults.string(for: testKey, accountEmail: nilAccount), globalValue)
        XCTAssertEqual(AccountDefaults.string(for: testKey, accountEmail: testAccountEmail), accountValue)
    }

    // MARK: - Remove Tests

    func testRemoveDeletesValue() throws {
        AccountDefaults.setString("value", for: testKey, accountEmail: testAccountEmail)
        XCTAssertNotNil(AccountDefaults.string(for: testKey, accountEmail: testAccountEmail))

        AccountDefaults.remove(key: testKey, accountEmail: testAccountEmail)
        XCTAssertNil(AccountDefaults.string(for: testKey, accountEmail: testAccountEmail))
    }

    // MARK: - Case Sensitivity Tests

    func testAccountEmailIsCaseInsensitive() throws {
        let value = "test value"
        AccountDefaults.setString(value, for: testKey, accountEmail: "Test@Example.COM")
        let result = AccountDefaults.string(for: testKey, accountEmail: "test@example.com")
        XCTAssertEqual(result, value)

        // Clean up
        AccountDefaults.remove(key: testKey, accountEmail: "test@example.com")
    }
}
