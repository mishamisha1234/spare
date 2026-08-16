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

    /// The largest accessibility text size, which is where layouts actually
    /// break. Screenshots only — it stops after the first few screens rather
    /// than repeating the whole flow, because the point is to see whether
    /// text fits, and a third full pass would add ~3 minutes to every run for
    /// screens whose behaviour is already covered twice.
    func testLargestDynamicTypeLayout() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITEST_RESET_STATE",
            // The documented override for driving Dynamic Type from a UI
            // test without going through Settings.
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launchEnvironment["UITEST_COLOR_SCHEME"] = "light"
        app.launch()

        let scheme = "ax5"
        do {
            try waitAndCapture(app, "ax-01-onboarding-pitch", scheme: scheme, identifier: "onboarding.primary")
            try tap(app, "onboarding.primary", scheme: scheme, step: "ax-01-onboarding-pitch")

            try waitAndCapture(app, "ax-02-onboarding-interests", scheme: scheme, identifier: "onboarding.chip.History")
            try tap(app, "onboarding.chip.History", scheme: scheme, step: "ax-02-onboarding-interests")
            try tap(app, "onboarding.primary", scheme: scheme, step: "ax-02-onboarding-interests")
            try tap(app, "onboarding.skip", scheme: scheme, step: "ax-03-skip-work")
            try tap(app, "onboarding.skip", scheme: scheme, step: "ax-04-skip-gaps")
            try tap(app, "onboarding.primary", scheme: scheme, step: "ax-05-notifications")

            // Home is the screen this test exists for: at AX5 the circles are
            // replaced by full-width rows, since two 160pt circles already
            // fill the screen and can't grow.
            try waitAndCapture(app, "ax-06-home", scheme: scheme, identifier: "home.circle.thirty")
            try tap(app, "recall.option.Wind alone", scheme: scheme, step: "ax-06-home-recall")
            try waitAndCapture(app, "ax-06a-recall-revealed", scheme: scheme, identifier: "recall.viewLesson")
            try tap(app, "recall.dismiss", scheme: scheme, step: "ax-06a-recall-revealed")

            // The paywall is dense and full of derived copy, so it's the
            // other likely overflow.
            try tap(app, "home.circle.thirty", scheme: scheme, step: "ax-06-home")
            try waitAndCapture(app, "ax-07-paywall", scheme: scheme, identifier: "paywall.buy")
            try tap(app, "paywall.close", scheme: scheme, step: "ax-07-paywall")

            try waitAndCapture(app, "ax-08-home-settings", scheme: scheme, identifier: "home.settingsButton")
            try tap(app, "home.settingsButton", scheme: scheme, step: "ax-08-home-settings")
            try waitAndCapture(app, "ax-09-settings", scheme: scheme, identifier: "settings.apiKeyField")
        } catch {
            attachFailureDiagnostics(app, scheme: scheme)
            throw error
        }
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

            // MARK: Home — the recall card (`-UITEST_RESET_STATE` seeds one
            // already-due item, so this is reachable without a multi-day
            // simulated wait).
            try waitAndCapture(app, "06-home", scheme: colorScheme, identifier: "home.circle.ten")
            try tap(app, "recall.option.Wind alone", scheme: colorScheme, step: "06-home-recall")
            try waitAndCapture(app, "06a-recall-revealed", scheme: colorScheme, identifier: "recall.viewLesson")
            try tap(app, "recall.dismiss", scheme: colorScheme, step: "06a-recall-revealed")

            // MARK: A locked duration still opens the paywall. 06b is also
            // the screenshot that shows the dashed lock marking on the 15-
            // and 30-minute course circles, with 3 and 10 left plain.
            try waitAndCapture(app, "06b-home-locked-durations", scheme: colorScheme, identifier: "home.circle.thirty")
            try tap(app, "home.circle.thirty", scheme: colorScheme, step: "06b-home-locked-durations")
            try waitAndCapture(app, "06c-paywall-from-duration", scheme: colorScheme, identifier: "paywall.buy")
            try tap(app, "paywall.close", scheme: colorScheme, step: "06c-paywall-from-duration")

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
            // The button exists as soon as the lesson finishes, but it sits at
            // the foot of a ~10,000pt scroll view, so it isn't hittable until
            // the reader gets there. Confirmed from the CI accessibility tree:
            // a bare `.tap()` left the app sitting on the Reader with content
            // still at y = -9804. Scrolling is also what a real reader does.
            XCTAssertTrue(
                scrollUntilHittable(app, continueButton),
                "08-reader: never scrolled far enough to reach Continue"
            )
            continueButton.tap()

            // MARK: Completion — still on the free tier here, so both premium
            // rows show as visibly locked rather than being hidden.
            try waitAndCapture(app, "09-completion", scheme: colorScheme, identifier: "completion.returnHome")
            try tap(app, "completion.markComplete", scheme: colorScheme, step: "09-completion")

            // MARK: Paywall, reached by tapping the locked post-lesson test.
            // This is the real trigger path, not a debug entry point.
            try waitAndCapture(app, "09a-completion-locked", scheme: colorScheme, identifier: "completion.takeTest")
            try tap(app, "completion.takeTest", scheme: colorScheme, step: "09a-completion-locked")
            try waitAndCapture(app, "09b-paywall", scheme: colorScheme, identifier: "paywall.buy")

            // Buying through StubPurchaseStore: no StoreKit configuration, no
            // sandbox account, and no possibility of a real charge in CI.
            try tap(app, "paywall.option.lifetime", scheme: colorScheme, step: "09b-paywall")
            try waitAndCapture(app, "09c-paywall-lifetime", scheme: colorScheme, identifier: "paywall.buy")
            try tap(app, "paywall.buy", scheme: colorScheme, step: "09c-paywall-lifetime")

            // The paywall dismisses itself once the entitlement lands, which
            // is also the assertion that the purchase actually took effect.
            try waitAndCapture(app, "09d-completion-unlocked", scheme: colorScheme, identifier: "completion.takeTest")
            try tap(app, "completion.takeTest", scheme: colorScheme, step: "09d-completion-unlocked")

            for questionNumber in 1...3 {
                let option = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH 'postLessonTest.option.'"))
                    .firstMatch
                if questionNumber == 1 {
                    try waitAndCapture(
                        app, "09e-postlessontest", scheme: colorScheme,
                        element: option, step: "09e-postlessontest"
                    )
                } else {
                    XCTAssertTrue(
                        option.waitForExistence(timeout: defaultTimeout),
                        "postlessontest question \(questionNumber): no option appeared"
                    )
                }
                option.tap()
                if questionNumber == 1 {
                    try waitAndCapture(app, "09f-postlessontest-revealed", scheme: colorScheme, identifier: "postLessonTest.next")
                }
                try tap(app, "postLessonTest.next", scheme: colorScheme, step: "postlessontest-q\(questionNumber)")
            }
            try waitAndCapture(app, "09g-postlessontest-summary", scheme: colorScheme, identifier: "postLessonTest.done")
            try tap(app, "postLessonTest.done", scheme: colorScheme, step: "09g-postlessontest-summary")

            try waitAndCapture(app, "09h-completion-after-test", scheme: colorScheme, identifier: "completion.returnHome")
            try tap(app, "completion.returnHome", scheme: colorScheme, step: "09h-completion-after-test")

            // MARK: Library (reached from Home)
            // Premium by now, so this is also where the course circle shows
            // its resume state: the seeded part-read course surfaces as
            // "Chapter 2 of 4 / Continue" instead of the offer, where a
            // moment ago (06b, free tier) the same circle was dash-locked.
            try waitAndCapture(app, "09i-home-again", scheme: colorScheme, identifier: "home.libraryButton")
            try tap(app, "home.libraryButton", scheme: colorScheme, step: "09i-home-again")
            // Wait for the lesson we just read to actually appear in the
            // library, not just for the screen to exist -- a stronger check,
            // and it avoids depending on any container-level identifier.
            let firstLibraryRow = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'library.row.'"))
                .firstMatch
            try waitAndCapture(app, "10-library", scheme: colorScheme, element: firstLibraryRow, step: "10-library")

            // MARK: Stats (points, level, the quiet achievements line)
            try tap(app, "library.stats", scheme: colorScheme, step: "10-library")
            try waitAndCapture(app, "10a-stats", scheme: colorScheme, identifier: "stats.share")

            // MARK: Share card render — the whole point of testing this in
            // CI: the rendered bitmap has no view hierarchy of its own, so a
            // screenshot of the preview sheet is the only way to review it
            // without a Mac.
            try tap(app, "stats.share", scheme: colorScheme, step: "10a-stats")
            try waitAndCapture(app, "10b-sharecard", scheme: colorScheme, identifier: "shareCard.image")
            try tap(app, "shareCard.close", scheme: colorScheme, step: "10b-sharecard")

            let statsBackButton = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(
                statsBackButton.waitForExistence(timeout: defaultTimeout),
                "10c-library: no back button from Stats"
            )
            statsBackButton.tap()

            // MARK: Settings — last, deliberately. It needs a back-navigation
            // tap on system chrome, so if that proves flaky it costs only this
            // step rather than the screenshots already captured.
            let backButton = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(
                backButton.waitForExistence(timeout: defaultTimeout),
                "11-settings: no back button to return to Home"
            )
            backButton.tap()
            try waitAndCapture(app, "11-home", scheme: colorScheme, identifier: "home.settingsButton")
            try tap(app, "home.settingsButton", scheme: colorScheme, step: "11-settings")
            try waitAndCapture(
                app, "12-settings", scheme: colorScheme, identifier: "settings.apiKeyField"
            )
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
            // `continueAfterFailure = false` aborts the test via XCTest's own
            // control flow, not a Swift `throw` -- the outer do/catch's
            // attachFailureDiagnostics() never actually runs for an
            // XCTAssertTrue failure. Printing here, unconditionally on
            // failure, is what actually gets a real accessibility tree into
            // the CI log for this class of failure.
            if !ok { printHierarchy(app, scheme: scheme, context: step ?? name) }
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
        let exists = target.waitForExistence(timeout: defaultTimeout)
        if !exists {
            capture(app, "FAILURE-\(step)", scheme: scheme)
            printHierarchy(app, scheme: scheme, context: step)
        }
        XCTAssertTrue(exists, "\(step): \"\(identifier)\" never appeared within \(defaultTimeout)s")

        // Existence is not readiness. A control that has just been laid out
        // (or is mid appear-animation, or sits in a ScrollView that hasn't
        // settled) exists at a correct on-screen frame while still being
        // untappable, and `.tap()` does not wait that out on its own.
        let ready = waitUntilHittable(target, timeout: defaultTimeout)
        if !ready {
            capture(app, "FAILURE-\(step)", scheme: scheme)
            printHierarchy(app, scheme: scheme, context: "\(step) (exists but not hittable)")
        }
        XCTAssertTrue(ready, "\(step): \"\(identifier)\" never became hittable within \(defaultTimeout)s")

        target.tap()
    }

    /// Scrolls until a known-existing element is actually reachable.
    ///
    /// `.tap()` does some scrolling of its own, but not dependably inside a
    /// long SwiftUI `ScrollView` — which is how the Reader's Continue button
    /// ended up being "tapped" while remaining ten thousand points below the
    /// fold. Stops as soon as the element is hittable, so the common case
    /// costs nothing.
    private func scrollUntilHittable(
        _ app: XCUIApplication,
        _ element: XCUIElement,
        maxSwipes: Int = 40
    ) -> Bool {
        var swipes = 0
        while !element.isHittable, swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        return element.isHittable
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        if element.isHittable { return true }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Prints the live accessibility tree to stdout, same as the launch-time
    /// dump — the one diagnostic proven to actually reach the CI log,
    /// unlike an XCTAttachment queued for a catch block that never runs.
    private func printHierarchy(_ app: XCUIApplication, scheme: String, context: String) {
        print("=== \(scheme) accessibility tree at failure (\(context)) ===")
        print(app.debugDescription)
        print("=== end \(scheme) accessibility tree at failure ===")
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
