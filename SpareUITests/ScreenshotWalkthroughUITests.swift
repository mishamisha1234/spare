import XCTest

/// Walks the full onboarding → Home → Suggestions → Reader → Completion →
/// Library path and attaches a screenshot at each step, in both light and
/// dark mode. This is the primary review surface for changes made without a
/// Mac: CI extracts the attachments from the `.xcresult` bundle and uploads
/// them as a plain-PNG workflow artifact.
///
/// `@MainActor`: XCUIApplication/XCUIElement are main-actor-isolated in the
/// XCTest SDK this project builds against, and every helper here touches one.
@MainActor
final class ScreenshotWalkthroughUITests: XCTestCase {

    /// Generous: this is a cold-launched simulator app on a shared CI runner,
    /// not a warm device. Individual steps rarely need this long, but a slow
    /// runner shouldn't turn into a false failure.
    private let defaultTimeout: TimeInterval = 30

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
        // never blocks the walkthrough. Matches by substring since the exact
        // wording/casing of system alert buttons varies by iOS version.
        let notificationMonitor = addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for button in alert.buttons.allElementsBoundByIndex {
                let label = button.label.lowercased()
                if label.contains("allow") || label.contains("ok") || label.contains("don") {
                    button.tap()
                    return true
                }
            }
            return false
        }
        defer { removeUIInterruptionMonitor(notificationMonitor) }

        app.launch()

        // Unconditional, not failure-only: `app.screenshot()` captures raw
        // simulator pixels regardless of what XCUITest's own accessibility
        // connection sees, so a clean screenshot does not prove the element
        // tree is correct. This dump is ground truth for that tree — needed
        // because the previous run showed a perfectly rendered button that a
        // 30s `waitForExistence` still could not find by identifier.
        let launchHierarchy = XCTAttachment(string: app.debugDescription)
        launchHierarchy.name = "\(colorScheme)-00-launch-hierarchy"
        launchHierarchy.lifetime = .keepAlways
        add(launchHierarchy)
        // Also printed directly: xcparse's "screenshots" subcommand may only
        // pull image attachments, but stdout is captured in the CI log
        // regardless, with no artifact-extraction step in between.
        print("=== \(colorScheme) accessibility tree at launch ===")
        print(app.debugDescription)
        print("=== end \(colorScheme) accessibility tree ===")

        do {
            // MARK: Onboarding — step 1: pitch
            try waitAndCapture(app, "01-onboarding-pitch", scheme: colorScheme, identifier: "onboarding.primary")
            try tap(app, "onboarding.primary", scheme: colorScheme, step: "01-onboarding-pitch")

            // MARK: Onboarding — step 2: interests
            try waitAndCapture(app, "02-onboarding-interests", scheme: colorScheme, identifier: "onboarding.chip.History")
            try tap(app, "onboarding.chip.History", scheme: colorScheme, step: "02-onboarding-interests")
            try tap(app, "onboarding.chip.Physics", scheme: colorScheme, step: "02-onboarding-interests")
            try tap(app, "onboarding.primary", scheme: colorScheme, step: "02-onboarding-interests")

            // MARK: Onboarding — step 3: work
            try waitAndCapture(app, "03-onboarding-work", scheme: colorScheme, identifier: "onboarding.work")
            let workField = element(app, "onboarding.work")
            workField.tap()
            workField.typeText("Product designer")
            try tap(app, "onboarding.primary", scheme: colorScheme, step: "03-onboarding-work")

            // MARK: Onboarding — step 4: curiosity gaps
            try waitAndCapture(app, "04-onboarding-curiosity-gaps", scheme: colorScheme, identifier: "onboarding.curiosityGapEntry")
            let gapField = element(app, "onboarding.curiosityGapEntry")
            gapField.tap()
            gapField.typeText("how interest rates work")
            try tap(app, "onboarding.addCuriosityGap", scheme: colorScheme, step: "04-onboarding-curiosity-gaps")
            try tap(app, "onboarding.primary", scheme: colorScheme, step: "04-onboarding-curiosity-gaps")

            // MARK: Onboarding — step 5: notifications
            try waitAndCapture(app, "05-onboarding-notifications", scheme: colorScheme, identifier: "onboarding.primary")
            try tap(app, "onboarding.primary", scheme: colorScheme, step: "05-onboarding-notifications")

            // MARK: Home
            try waitAndCapture(app, "06-home", scheme: colorScheme, identifier: "home.circle.ten")
            try tap(app, "home.circle.ten", scheme: colorScheme, step: "06-home")

            // MARK: Suggestions
            let firstSuggestionRow = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'suggestions.row.'"))
                .firstMatch
            try waitAndCapture(app, "07-suggestions", scheme: colorScheme, element: firstSuggestionRow, step: "07-suggestions")
            firstSuggestionRow.tap()

            // MARK: Reader — MockProvider streams progressively, so give this
            // one a longer budget than the default.
            let continueButton = element(app, "reader.continue")
            try waitAndCapture(
                app, "08-reader", scheme: colorScheme,
                element: continueButton, step: "08-reader", timeout: 60
            )
            continueButton.tap()

            // MARK: Completion
            try waitAndCapture(app, "09-completion", scheme: colorScheme, identifier: "completion.returnHome")
            try tap(app, "completion.returnHome", scheme: colorScheme, step: "09-completion")

            // MARK: Library (reached from Home)
            try waitAndCapture(app, "06b-home-again", scheme: colorScheme, identifier: "home.libraryButton")
            try tap(app, "home.libraryButton", scheme: colorScheme, step: "06b-home-again")
            try waitAndCapture(app, "10-library", scheme: colorScheme, identifier: "library.screen")
        } catch {
            attachFailureDiagnostics(app, scheme: colorScheme)
            throw error
        }
    }

    // MARK: - Helpers

    /// SwiftUI doesn't guarantee a container's XCUIElement type (`.other` vs
    /// `.scrollView` etc.), so every identifier lookup searches every element
    /// type rather than assuming one — this was the direct cause of the first
    /// version of this test failing to find a plain SwiftUI `Button`.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Waits for a specific element (by identifier or a pre-built query) to
    /// exist, then screenshots. Failing here — rather than at the next tap —
    /// makes the artifact show exactly which step never rendered.
    @discardableResult
    private func waitAndCapture(
        _ app: XCUIApplication,
        _ name: String,
        scheme: String,
        identifier: String? = nil,
        element target: XCUIElement? = nil,
        step: String? = nil,
        timeout: TimeInterval? = nil
    ) throws -> XCUIElement? {
        let waitTarget: XCUIElement?
        if let target {
            waitTarget = target
        } else if let identifier {
            waitTarget = element(app, identifier)
        } else {
            waitTarget = nil
        }

        if let waitTarget {
            let ok = waitTarget.waitForExistence(timeout: timeout ?? defaultTimeout)
            capture(app, name, scheme: scheme)
            XCTAssertTrue(ok, "\(step ?? name): element never appeared")
            return waitTarget
        }

        capture(app, name, scheme: scheme)
        return nil
    }

    /// Waits for a control to exist (and be hittable) before tapping, instead
    /// of relying on `.tap()`'s own implicit synchronization — a failure here
    /// reports which step's control never became available, rather than a
    /// generic "no matches found" with no indication of how long was waited.
    private func tap(_ app: XCUIApplication, _ identifier: String, scheme: String, step: String) throws {
        let target = element(app, identifier)
        let ok = target.waitForExistence(timeout: defaultTimeout)
        if !ok {
            capture(app, "FAILURE-\(step)", scheme: scheme)
        }
        XCTAssertTrue(ok, "\(step): \"\(identifier)\" never appeared within \(defaultTimeout)s")
        target.tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String, scheme: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(scheme)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A screenshot plus the full accessibility tree, attached only when the
    /// walkthrough fails — turns "it failed" into "here is exactly what was
    /// on screen and what elements existed at that moment" without needing
    /// another push-and-wait cycle to find out.
    private func attachFailureDiagnostics(_ app: XCUIApplication, scheme: String) {
        capture(app, "FAILURE-final-state", scheme: scheme)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(scheme)-FAILURE-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
