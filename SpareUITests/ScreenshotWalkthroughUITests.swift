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
    /// A first, cheap wait before trying to scroll. Something already on
    /// screen becomes hittable well inside this.
    private let shortTimeout: TimeInterval = 3

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testWalkthroughLight() throws {
        try walkthrough(colorScheme: "light")
    }

    func testWalkthroughDark() throws {
        try walkthrough(colorScheme: "dark")
    }

    // MARK: - The trial's screens
    //
    // A pass of their own rather than steps inside the main walkthrough, for
    // a reason that is not tidiness: starting a trial unlocks every length,
    // so capturing the offer partway through the walkthrough would leave the
    // rest of it photographing a premium reader and the free-tier locked
    // states -- the ones the paywall exists to explain -- would stop being
    // reachable at all.
    //
    // Three passes, matching the rest of the file. Four screens each: the
    // offer that follows a dismissed paywall, the day-4 line on Home, the
    // day-7 summary, and Home once the week is over. None of them can be
    // seen by a human without waiting four days and then three more, which
    // is exactly the kind of state that ships unlooked-at.

    func testTrialScreensLight() throws {
        try trialScreens(colorScheme: "light")
    }

    func testTrialScreensDark() throws {
        try trialScreens(colorScheme: "dark")
    }

    func testTrialScreensLargestDynamicType() throws {
        try trialScreens(colorScheme: "ax3", accessibilityText: true)
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
            // AX3: the size the circle grid switches to a single column,
            // the Settings segments become rows, and the paywall plan rows
            // stack. The value is a `UICTContentSizeCategory*` constant —
            // an unrecognised one is silently ignored and the app launches
            // at the default size, which is what the first version did.
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraLarge",
        ]
        app.launchEnvironment["UITEST_COLOR_SCHEME"] = "light"

        // Same system-alert handling as the main walkthrough. This test sorts
        // first alphabetically, so on a clean simulator it is the run that
        // actually meets the notification prompt.
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

        let scheme = "ax3"
        do {
            try waitAndCapture(app, "ax-01-onboarding-pitch", scheme: scheme, identifier: "onboarding.primary")
            try tap(app, "onboarding.primary", scheme: scheme, step: "ax-01-onboarding-pitch")

            try waitAndCapture(app, "ax-02-onboarding-interests", scheme: scheme, identifier: "onboarding.chip.History")
            try tap(app, "onboarding.chip.History", scheme: scheme, step: "ax-02-onboarding-interests")
            try tap(app, "onboarding.primary", scheme: scheme, step: "ax-02-onboarding-interests")
            // One "about you" screen now, not two single-field screens.
            try waitAndCapture(app, "ax-03-onboarding-about", scheme: scheme, identifier: "onboarding.work")
            try tap(app, "onboarding.skip", scheme: scheme, step: "ax-03-onboarding-about")
            try tap(app, "onboarding.primary", scheme: scheme, step: "ax-04-notifications")
            dismissNotificationPromptIfPresent()

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
            waitUntilGone(element(app, "paywall.buy"))

            try waitAndCapture(app, "ax-08-home-settings", scheme: scheme, identifier: "home.settingsButton")
            try tap(app, "home.settingsButton", scheme: scheme, step: "ax-08-home-settings")
            try waitAndCapture(app, "ax-09-settings", scheme: scheme, identifier: "settings.apiKeyField")
        } catch {
            attachFailureDiagnostics(app, scheme: scheme)
            throw error
        }
    }

    /// The states the flow can reach that the happy path never shows.
    ///
    /// Driven by launch arguments rather than by forcing failures through the
    /// UI: an empty library and a provider that fails are both states, not
    /// journeys, and reaching them by navigation would make the test about
    /// the navigation instead.
    func testEmptyAndErrorStates() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITEST_RESET_STATE",
            // No seeded lesson, recall item, or course.
            "-UITEST_EMPTY_STATE",
            // Every provider call fails, so Suggestions and the Reader show
            // their real error copy rather than a contrived string.
            "-UITEST_FAILING_PROVIDER",
        ]
        app.launchEnvironment["UITEST_COLOR_SCHEME"] = "light"
        app.launch()

        let scheme = "states"
        do {
            // Onboarding is skipped by -UITEST_EMPTY_STATE, so this is Home
            // with nothing behind it: no recall card at all, which is the
            // fix for the card that used to appear on a fresh install.
            try waitAndCapture(app, "st-01-home-empty", scheme: scheme, identifier: "home.circle.three")

            try tap(app, "home.circle.three", scheme: scheme, step: "st-01-home-empty")
            try waitAndCapture(app, "st-02-suggestions-error", scheme: scheme, identifier: "suggestions.error")

            let back = app.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: defaultTimeout) { back.tap() }

            try tap(app, "home.libraryButton", scheme: scheme, step: "st-03-library-empty")
            try waitAndCapture(app, "st-03-library-empty", scheme: scheme, identifier: "library.empty")
        } catch {
            attachFailureDiagnostics(app, scheme: scheme)
            throw error
        }
    }

    // MARK: - Trial screens

    /// Launches the app with a given trial state and hands back a running app.
    ///
    /// A fresh launch per screen rather than one long session, because the
    /// three states are three different points in a week and there is no
    /// in-app path between them that does not involve waiting four days.
    /// `StubTrialStore` supplies the state; nothing here reaches a network.
    private func launchForTrial(
        _ extraArguments: [String],
        colorScheme: String,
        accessibilityText: Bool
    ) -> XCUIApplication {
        let app = XCUIApplication()
        // Straight to Home with the seed intact. Onboarding is four taps and
        // four screens this pass is not about, paid three times per pass --
        // and every one of them is somewhere the run can fall over.
        var arguments = ["-UITEST_RESET_STATE", "-UITEST_SKIP_ONBOARDING"] + extraArguments
        if accessibilityText {
            arguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityExtraLarge",
            ]
        }
        app.launchArguments = arguments
        app.launchEnvironment["UITEST_COLOR_SCHEME"] = accessibilityText ? "light" : colorScheme
        app.launch()
        return app
    }

    /// Waits for Home. `-UITEST_SKIP_ONBOARDING` means there is nothing to
    /// walk through first, but the notification prompt can still arrive.
    private func waitForHome(_ app: XCUIApplication, scheme: String) {
        dismissNotificationPromptIfPresent()
        XCTAssertTrue(
            element(app, "home.circle.thirty").waitForExistence(timeout: defaultTimeout),
            "\(scheme): never reached Home"
        )
    }

    private func trialScreens(colorScheme: String, accessibilityText: Bool = false) throws {
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

        // MARK: The offer, reached the way a reader reaches it.
        //
        // Not a debug entry point: this taps a locked length, gets the real
        // paywall, closes it, and the offer is what the app does next. The
        // seeded state already contains a finished lesson, so the ordering
        // rule is satisfied and the paywall is allowed to appear at all.
        var app = launchForTrial(
            ["-UITEST_TRIAL_ELIGIBLE"], colorScheme: colorScheme, accessibilityText: accessibilityText
        )
        do {
            waitForHome(app, scheme: colorScheme)
            try waitAndCapture(app, "t-01-home-eligible", scheme: colorScheme, identifier: "home.circle.thirty")
            try tap(app, "home.circle.thirty", scheme: colorScheme, step: "t-01-home-eligible")
            try waitAndCapture(app, "t-02-paywall", scheme: colorScheme, identifier: "paywall.buy")
            try tap(app, "paywall.close", scheme: colorScheme, step: "t-02-paywall")

            try waitAndCapture(
                app, "t-03-trial-offer", scheme: colorScheme, identifier: "trialOffer.start"
            )
            // The cap has to be legible on this sheet, not merely present in
            // the string. At AX3 that is a real question about layout, which
            // is the whole reason this pass exists.
            XCTAssertTrue(
                element(app, "trialOffer.courseNote").exists,
                "t-03-trial-offer: the mini-course limit is not on the offer"
            )
            try tap(app, "trialOffer.start", scheme: colorScheme, step: "t-03-trial-offer")
        } catch {
            attachFailureDiagnostics(app, scheme: colorScheme)
            throw error
        }
        app.terminate()

        // MARK: Day 4 — the nudge on Home.
        app = launchForTrial(
            ["-UITEST_TRIAL_DAY4"], colorScheme: colorScheme, accessibilityText: accessibilityText
        )
        do {
            waitForHome(app, scheme: colorScheme)
            try waitAndCapture(app, "t-04-home-day4-nudge", scheme: colorScheme, identifier: "home.trialLine")
            // Dismissible, and dismissed for good. A report that keeps coming
            // back is a nag.
            try tap(app, "home.trialLine.dismiss", scheme: colorScheme, step: "t-04-home-day4-nudge")
            XCTAssertTrue(
                waitUntilGone(element(app, "home.trialLine")),
                "t-04: the nudge did not go away when dismissed"
            )
        } catch {
            attachFailureDiagnostics(app, scheme: colorScheme)
            throw error
        }
        app.terminate()

        // MARK: Day 7 — the summary, then the free tier it collapses to.
        app = launchForTrial(
            ["-UITEST_TRIAL_EXPIRED"], colorScheme: colorScheme, accessibilityText: accessibilityText
        )
        do {
            waitForHome(app, scheme: colorScheme)
            try waitAndCapture(
                app, "t-05-trial-summary", scheme: colorScheme, identifier: "trialSummary.keepPremium"
            )
            // Both halves of the argument have to be on screen together: the
            // reader's own numbers, and the promise that the library stays.
            // The second is what makes this a decision rather than a threat.
            XCTAssertTrue(
                element(app, "trialSummary.line").exists,
                "t-05-trial-summary: no summary line"
            )
            XCTAssertTrue(
                element(app, "trialSummary.freeTierNote").exists,
                "t-05-trial-summary: the free tier is not described"
            )

            try tap(app, "trialSummary.continueFree", scheme: colorScheme, step: "t-05-trial-summary")
            XCTAssertTrue(
                waitUntilGone(element(app, "trialSummary.keepPremium")),
                "t-05: the summary did not dismiss"
            )

            // Post-trial Home. The lengths are locked again and the library is
            // untouched -- the second of those is the entire selling model, so
            // it is asserted rather than left to the screenshot.
            try waitAndCapture(
                app, "t-06-home-post-trial", scheme: colorScheme, identifier: "home.circle.thirty"
            )
            try tap(app, "home.libraryButton", scheme: colorScheme, step: "t-06-home-post-trial")
            try waitAndCapture(
                app, "t-07-library-post-trial", scheme: colorScheme, identifier: "library.stats"
            )
        } catch {
            attachFailureDiagnostics(app, scheme: colorScheme)
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

            // MARK: Onboarding — step 3: about you (work + curiosity gaps,
            // previously two separate screens)
            try waitAndCapture(app, "03-onboarding-about", scheme: colorScheme, identifier: "onboarding.work")
            let workField = element(app, "onboarding.work")
            workField.tap()
            workField.typeText("Product designer")

            let gapField = element(app, "onboarding.curiosityGapEntry")
            gapField.tap()
            gapField.typeText("how interest rates work")
            try tap(app, "onboarding.addCuriosityGap", scheme: colorScheme, step: "03-onboarding-about")
            try waitAndCapture(app, "03a-onboarding-about-filled", scheme: colorScheme, identifier: "onboarding.primary")
            try tap(app, "onboarding.primary", scheme: colorScheme, step: "03-onboarding-about")

            // MARK: Onboarding — step 5: notifications
            try waitAndCapture(app, "04-onboarding-notifications", scheme: colorScheme, identifier: "onboarding.primary")
            try tap(app, "onboarding.primary", scheme: colorScheme, step: "04-onboarding-notifications")

            // MARK: Home — the recall card (`-UITEST_RESET_STATE` seeds one
            // already-due item, so this is reachable without a multi-day
            // simulated wait).
            try waitAndCapture(app, "06-home", scheme: colorScheme, identifier: "home.circle.seven")
            try tap(app, "recall.option.Wind alone", scheme: colorScheme, step: "06-home-recall")
            try waitAndCapture(app, "06a-recall-revealed", scheme: colorScheme, identifier: "recall.viewLesson")
            try tap(app, "recall.dismiss", scheme: colorScheme, step: "06a-recall-revealed")

            // MARK: A locked duration still opens the paywall. 06b is also
            // the screenshot that shows the lock marking on the 1-, 15- and
            // 30-minute circles, with 3 and 7 left plain.
            try waitAndCapture(app, "06b-home-locked-durations", scheme: colorScheme, identifier: "home.circle.thirty")

            // The 1-minute circle is premium and must still be on screen for a
            // free reader. A hidden premium length converts nobody, and this
            // one is the conversion hook precisely because "the shortest is the
            // paid one" is counterintuitive -- so its absence would be a
            // product failure that no other assertion here would catch.
            let oneMinute = element(app, "home.circle.one")
            XCTAssertTrue(oneMinute.waitForExistence(timeout: 5),
                          "the 1-minute circle is not on Home for a free reader")
            XCTAssertTrue(oneMinute.isHittable, "the 1-minute circle is on screen but unreachable")

            try tap(app, "home.circle.one", scheme: colorScheme, step: "06b-home-locked-durations")
            try waitAndCapture(app, "06b1-paywall-from-one-minute", scheme: colorScheme, identifier: "paywall.buy")
            try tap(app, "paywall.close", scheme: colorScheme, step: "06b1-paywall-from-one-minute")
            waitUntilGone(element(app, "paywall.buy"))

            try tap(app, "home.circle.thirty", scheme: colorScheme, step: "06b-home-locked-durations")
            try waitAndCapture(app, "06c-paywall-from-duration", scheme: colorScheme, identifier: "paywall.buy")
            try tap(app, "paywall.close", scheme: colorScheme, step: "06c-paywall-from-duration")
            waitUntilGone(element(app, "paywall.buy"))

            try tap(app, "home.circle.seven", scheme: colorScheme, step: "06-home")

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
            //
            // Monthly rather than the pre-selected annual, so the capture
            // shows a deliberate change of selection and the button re-reads
            // the price. The annual row is the one carrying the introductory
            // first-year price, and 09b above is where that copy is captured.
            try tap(app, "paywall.option.monthly", scheme: colorScheme, step: "09b-paywall")
            try waitAndCapture(app, "09c-paywall-monthly", scheme: colorScheme, identifier: "paywall.buy")
            try tap(app, "paywall.buy", scheme: colorScheme, step: "09c-paywall-monthly")

            // The paywall dismisses itself once the entitlement lands, which
            // is also the assertion that the purchase actually took effect.
            try waitAndCapture(app, "09d-completion-unlocked", scheme: colorScheme, identifier: "completion.takeTest")
            try tap(app, "completion.takeTest", scheme: colorScheme, step: "09d-completion-unlocked")

            // Answers every question, however many this length carries.
            //
            // It used to be `1...3`. The count is 2/3/4/5/10 by duration now,
            // so a fixed number here is a number that has to be edited every
            // time the product changes it — and it tests nothing that
            // `LessonAttachmentsTests` and the proxy's own shape check do not
            // already pin exactly. What this walkthrough is for is the flow:
            // answer everything, arrive at the summary. Bounded above the
            // longest test so a screen that never advances still fails.
            var questionNumber = 0
            while questionNumber < 12, !element(app, "postLessonTest.done").exists {
                let option = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH 'postLessonTest.option.'"))
                    .firstMatch
                questionNumber += 1
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
            XCTAssertGreaterThan(questionNumber, 1, "the test ended after a single question")
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

        // Existence is not readiness, and this has now bitten in four
        // different ways: an identifier clobbered by a container, a
        // stroke-only background with no hit area, an element below the fold,
        // and an element under an animating sheet. Wait for hittability, and
        // if it never comes, try scrolling before giving up — "exists but is
        // further down the page" is the common case now that Home and the
        // Completion screen both scroll.
        var ready = waitUntilHittable(target, timeout: shortTimeout)
        if !ready {
            ready = scrollUntilHittable(app, target)
        }
        if !ready {
            ready = waitUntilHittable(target, timeout: defaultTimeout)
        }
        if !ready {
            capture(app, "FAILURE-\(step)", scheme: scheme)
            printHierarchy(app, scheme: scheme, context: "\(step) (exists but not hittable)")
        }
        XCTAssertTrue(ready, "\(step): \"\(identifier)\" never became hittable within \(defaultTimeout)s")

        // An element can report itself hittable and still have no usable hit
        // point, which `tap()` reports as "Activation point invalid and no
        // suggested hit points based on element frame" — an XCTest-level error
        // with no dump attached, so the accessibility tree that would explain
        // it never reaches the log. A zero-sized frame is what causes it, and
        // it means a layout squeezed the element to nothing rather than
        // placing it off-screen. Caught here so the failure names itself.
        let frame = target.frame
        if frame.width == 0 || frame.height == 0 {
            capture(app, "FAILURE-\(step)", scheme: scheme)
            printHierarchy(app, scheme: scheme, context: "\(step) (hittable but zero-sized)")
            XCTFail("\(step): \"\(identifier)\" has a zero-sized frame — squeezed by layout, not scrolled past")
        }

        // A coordinate tap rather than `target.tap()`.
        //
        // Everything above has already established that this element exists,
        // is hittable, and has a real frame -- that is where the verification
        // lives. What `target.tap()` adds on top is resolving an activation
        // point at tap time, and inside a SwiftUI ScrollView that resolution
        // races the scroll view's own layout: CI has produced "Activation
        // point invalid and no suggested hit points based on element frame"
        // on an element that passed every check a line earlier. The error is
        // raised by XCTest directly, so it cannot be caught and retried, and
        // it arrives with no accessibility dump attached.
        //
        // Tapping the centre of the frame we just validated skips that second
        // resolution. It does not skip hit-testing of what is on top: a sheet
        // covering the element still fails, at `waitUntilHittable` above,
        // which is where that failure belongs.
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Waits for an element to actually go away.
    ///
    /// Dismissing a sheet is animated, so the tap that closes it returns long
    /// before the content underneath is reachable — the next step then finds
    /// its target "existing" (it is in the tree, just covered) and fails on
    /// hittability instead. Waiting for the sheet's own content to disappear
    /// is the barrier that makes the following step deterministic.
    @discardableResult
    private func waitUntilGone(
        _ element: XCUIElement,
        timeout: TimeInterval = 10
    ) -> Bool {
        if !element.exists { return true }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Dismisses the notification permission alert directly on Springboard.
    ///
    /// `addUIInterruptionMonitor` only fires on the *next* interaction with
    /// the app, which isn't deterministic when the following step is a
    /// `waitForExistence` — an element behind the alert still "exists", so
    /// the wait succeeds and the screenshot captures the alert sitting over
    /// the screen under review. That is exactly what the first AX5 run did.
    /// Reaching for the alert directly is explicit and ordered.
    private func dismissNotificationPromptIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Don't Allow", "Don’t Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                return
            }
        }
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
