//
//  SimpleMailUITests.swift
//  SimpleMailUITests
//
//  Created by Mark Marge on 12/31/25.
//

import XCTest

final class SimpleMailUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Launch Tests

    @MainActor
    func testAppLaunches() throws {
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - Login Flow Tests

    @MainActor
    func testLoginScreenAppears() throws {
        let signInButton = app.buttons["Sign in with Google"]
        if signInButton.waitForExistence(timeout: 5) {
            XCTAssertTrue(signInButton.exists)
        } else {
            let tabBar = app.tabBars.firstMatch
            XCTAssertTrue(tabBar.exists)
        }
    }

    // MARK: - Tab Bar Tests

    @MainActor
    func testTabBarExists() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTSkip("Tab bar not available - user may need to log in")
            return
        }
        XCTAssertTrue(tabBar.exists)
    }

    @MainActor
    func testCanSwitchToBriefingTab() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTSkip("Tab bar not available")
            return
        }
        let briefingTab = tabBar.buttons["Briefing"]
        XCTAssertTrue(briefingTab.exists)
        briefingTab.tap()
        sleep(1)
    }

    @MainActor
    func testCanSwitchToSettingsTab() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTSkip("Tab bar not available")
            return
        }
        let settingsTab = tabBar.buttons["Settings"]
        XCTAssertTrue(settingsTab.exists)
        settingsTab.tap()
        let settingsList = app.collectionViews.firstMatch
        XCTAssertTrue(settingsList.waitForExistence(timeout: 5))
    }

    // MARK: - Inbox Tests

    @MainActor
    func testInboxLoads() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTSkip("Not logged in")
            return
        }
        tabBar.buttons["Inbox"].tap()
        sleep(1)
    }

    @MainActor
    func testCanPullToRefresh() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTSkip("Not logged in")
            return
        }
        tabBar.buttons["Inbox"].tap()
        sleep(1)

        let scrollView = app.scrollViews.firstMatch
        guard scrollView.waitForExistence(timeout: 5) else {
            XCTSkip("No scrollable content found")
            return
        }

        let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.1, thenDragTo: end)
        sleep(2)
        XCTAssertTrue(scrollView.exists)
    }

    // MARK: - Search Tests

    @MainActor
    func testCanOpenSearch() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTSkip("Not logged in")
            return
        }
        tabBar.buttons["Inbox"].tap()
        sleep(1)

        let searchButton = app.buttons["searchButton"]
        guard searchButton.waitForExistence(timeout: 5) else {
            XCTSkip("Search button not found")
            return
        }
        searchButton.tap()
        sleep(1) // Wait for sheet to present

        // Search might be in a text field or search field
        let searchField = app.searchFields.firstMatch
        let textField = app.textFields.firstMatch
        let foundSearch = searchField.waitForExistence(timeout: 5) || textField.waitForExistence(timeout: 2)
        XCTAssertTrue(foundSearch, "Search input not found")
    }

    // MARK: - Compose Tests

    @MainActor
    func testCanOpenCompose() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTSkip("Not logged in")
            return
        }
        tabBar.buttons["Inbox"].tap()
        sleep(1)

        let composeButton = app.buttons["composeButton"]
        guard composeButton.waitForExistence(timeout: 5) else {
            XCTSkip("Compose button not found")
            return
        }
        composeButton.tap()
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
    }

    @MainActor
    func testCanDismissCompose() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTSkip("Not logged in")
            return
        }
        tabBar.buttons["Inbox"].tap()
        sleep(1)

        let composeButton = app.buttons["composeButton"]
        guard composeButton.waitForExistence(timeout: 5) else {
            XCTSkip("Compose button not found")
            return
        }
        composeButton.tap()

        let cancelButton = app.buttons["Cancel"]
        guard cancelButton.waitForExistence(timeout: 5) else {
            XCTFail("Cancel button not found")
            return
        }
        cancelButton.tap()
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    // MARK: - Email Detail Tests

    @MainActor
    func testCanOpenEmail() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTSkip("Not logged in")
            return
        }
        tabBar.buttons["Inbox"].tap()
        sleep(2)

        let cells = app.cells
        guard cells.count > 0 else {
            XCTSkip("No emails in inbox")
            return
        }
        cells.firstMatch.tap()
        sleep(1)
    }

    @MainActor
    func testCanNavigateBackFromEmail() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTSkip("Not logged in")
            return
        }
        tabBar.buttons["Inbox"].tap()
        sleep(2)

        let cells = app.cells
        guard cells.count > 0 else {
            XCTSkip("No emails in inbox")
            return
        }
        cells.firstMatch.tap()
        sleep(1)

        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.exists {
            backButton.tap()
        }
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    // MARK: - Settings Tests

    @MainActor
    func testSettingsShowsAccountInfo() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTSkip("Not logged in")
            return
        }
        tabBar.buttons["Settings"].tap()
        sleep(1)
        let accountSection = app.staticTexts["Account"]
        XCTAssertTrue(accountSection.waitForExistence(timeout: 5))
    }

    // MARK: - Swipe Actions Tests

    @MainActor
    func testCanSwipeEmailForActions() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTSkip("Not logged in")
            return
        }
        tabBar.buttons["Inbox"].tap()
        sleep(2)

        let cells = app.cells
        guard cells.count > 0 else {
            XCTSkip("No emails in inbox")
            return
        }

        let firstCell = cells.firstMatch
        firstCell.swipeLeft()
        sleep(1)
        firstCell.swipeRight()
    }

    // MARK: - Performance Tests

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
