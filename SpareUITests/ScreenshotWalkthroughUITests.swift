import XCTest

/// Walks the full onboarding → Home → Suggestions → Reader → Completion →
/// Library path and attaches a screenshot at each step, in both light and
/// dark mode. This is the primary review surface for changes made without a
/// Mac: CI extracts the attachments from the `.xcresult` bundle and uploads
/// them as a plain-PNG workflow artifact.
final class ScreenshotWalkthroughUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testWalkthroughLight() throws {
        try walkthrough(colorScheme: "light")
    }

    func testWalkthroughDark() throws {
        try walkthrough(colorScheme: "dark")
    }

    // MARK: - Walkthrough

    private func walkthrough(colorScheme: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITEST_RESET_STATE"]
        app.launchEnvironment["UITEST_COLOR_SCHEME"] = colorScheme

        // The notification-permission system alert only appears once per
        // simulator (first decision sticks); handle it if it shows up so it
        // never blocks the walkthrough.
        let notificationMonitor = addUIInterruptionMonitor(withDescription: "Notification permission") { alert in
            for label in ["Allow", "Don't Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(notificationMonitor) }

        app.launch()

        // MARK: Onboarding — step 1: pitch
        capture(app, "01-onboarding-pitch", scheme: colorScheme)
        app.buttons["onboarding.primary"].tap()

        // MARK: Onboarding — step 2: interests
        capture(app, "02-onboarding-interests", scheme: colorScheme)
        app.buttons["onboarding.chip.History"].tap()
        app.buttons["onboarding.chip.Physics"].tap()
        app.buttons["onboarding.primary"].tap()

        // MARK: Onboarding — step 3: work
        capture(app, "03-onboarding-work", scheme: colorScheme)
        let workField = app.textFields["onboarding.work"]
        XCTAssertTrue(workField.waitForExistence(timeout: 5))
        workField.tap()
        workField.typeText("Product designer")
        app.buttons["onboarding.primary"].tap()

        // MARK: Onboarding — step 4: curiosity gaps
        capture(app, "04-onboarding-curiosity-gaps", scheme: colorScheme)
        let gapField = app.textFields["onboarding.curiosityGapEntry"]
        XCTAssertTrue(gapField.waitForExistence(timeout: 5))
        gapField.tap()
        gapField.typeText("how interest rates work")
        app.buttons["onboarding.addCuriosityGap"].tap()
        app.buttons["onboarding.primary"].tap()

        // MARK: Onboarding — step 5: notifications
        capture(app, "05-onboarding-notifications", scheme: colorScheme)
        app.buttons["onboarding.primary"].tap()

        // MARK: Home
        let homeScreen = element(app, "home.screen")
        XCTAssertTrue(homeScreen.waitForExistence(timeout: 10))
        capture(app, "06-home", scheme: colorScheme)

        app.buttons["home.circle.ten"].tap()

        // MARK: Suggestions
        let suggestionsScreen = element(app, "suggestions.screen")
        XCTAssertTrue(suggestionsScreen.waitForExistence(timeout: 10))
        let firstSuggestionRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'suggestions.row.'"))
            .firstMatch
        XCTAssertTrue(firstSuggestionRow.waitForExistence(timeout: 10))
        capture(app, "07-suggestions", scheme: colorScheme)
        firstSuggestionRow.tap()

        // MARK: Reader
        let readerScreen = element(app, "reader.screen")
        XCTAssertTrue(readerScreen.waitForExistence(timeout: 10))
        let continueButton = app.buttons["reader.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 30), "lesson never finished streaming")
        capture(app, "08-reader", scheme: colorScheme)
        continueButton.tap()

        // MARK: Completion
        let completionScreen = element(app, "completion.screen")
        XCTAssertTrue(completionScreen.waitForExistence(timeout: 10))
        capture(app, "09-completion", scheme: colorScheme)
        app.buttons["completion.returnHome"].tap()

        // MARK: Library (reached from Home)
        XCTAssertTrue(homeScreen.waitForExistence(timeout: 10))
        app.buttons["home.libraryButton"].tap()
        let libraryScreen = element(app, "library.screen")
        XCTAssertTrue(libraryScreen.waitForExistence(timeout: 10))
        capture(app, "10-library", scheme: colorScheme)
    }

    // MARK: - Helpers

    /// SwiftUI doesn't guarantee a container's XCUIElement type (`.other` vs
    /// `.scrollView` etc.), so identifier lookups for screen roots search
    /// every element type rather than assuming one.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String, scheme: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(scheme)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
