import XCTest

@MainActor
final class ReplayCaptureTests: XCTestCase {
    func testConsentCaptureAndWithdrawal() {
        let app = XCUIApplication()
        app.launch()
        let state = app.staticTexts["state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        expect(state, label: "denied")
        app.buttons["update"].tap()
        app.buttons["flush"].tap()
        settle(2)
        XCTAssertEqual(app.staticTexts["delivered"].label, "0")
        XCTAssertEqual(app.staticTexts["queuedBytes"].label, "0")
        app.buttons["grant"].tap()
        expect(state, label: "recording")
        for _ in 0..<3 {
            app.buttons["update"].tap()
            settle(1.2)
        }
        app.buttons["flush"].tap()
        let uploaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != '0'"), object: app.staticTexts["delivered"])
        XCTAssertEqual(XCTWaiter.wait(for: [uploaded], timeout: 20), .completed)
        app.buttons["offline"].tap()
        app.buttons["update"].tap()
        settle(2)
        let buffered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != '0'"), object: app.staticTexts["queuedBytes"])
        XCTAssertEqual(XCTWaiter.wait(for: [buffered], timeout: 10), .completed)
        app.buttons["withdraw"].tap()
        expect(state, label: "denied")
        XCTAssertEqual(app.staticTexts["queuedBytes"].label, "0")
        let before = app.staticTexts["delivered"].label
        app.buttons["flush"].tap()
        app.buttons["update"].tap()
        settle(2)
        XCTAssertEqual(app.staticTexts["delivered"].label, before)
        XCTAssertEqual(app.staticTexts["queuedBytes"].label, "0")
        // Runtime-only consent: a new process must start denied again.
        app.terminate()
        app.launch()
        expect(app.staticTexts["state"], label: "denied")
        XCTAssertEqual(app.staticTexts["queuedBytes"].label, "0")
    }

    private func expect(_ element: XCUIElement, label: String) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 15), .completed)
    }
    private func settle(_ seconds: TimeInterval) {
        let pause = XCTestExpectation(description: "capture layout cadence")
        pause.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [pause], timeout: seconds), .completed)
    }
}
