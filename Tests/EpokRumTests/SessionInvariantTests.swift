import XCTest
@testable import EpokRum

final class SessionInvariantTests: XCTestCase {
    func testSessionStableWithinIdleWindowAndRotatesBeyondIdle() async throws {
        let h = try Harness { $0.sessionInactivityMs = 100; $0.sessionMaxDurationMs = 1_000 }
        defer { h.cleanup() }
        let denied = await h.rum.snapshot()
        XCTAssertNil(denied.sessionId)
        await h.rum.grantConsent()
        let granted = await h.rum.snapshot()
        let first = try XCTUnwrap(granted.sessionId)
        h.advance(100)
        await h.rum.recordMetric(name: "sample", value: 1)
        let atBoundary = await h.rum.snapshot()
        XCTAssertEqual(atBoundary.sessionId, first, "Android rotates strictly beyond the idle boundary")
        h.advance(101)
        await h.rum.recordMetric(name: "sample", value: 1)
        let idle = await h.rum.snapshot()
        XCTAssertNotEqual(idle.sessionId, first, "Idle timeout must rotate")
        XCTAssertTrue(matches(try XCTUnwrap(idle.sessionId), "^[0-9a-f]{32}$"))
        assertConserved(idle)
    }

    func testHardDurationRotatesDespiteContinuousActivityAndWithdrawalResets() async throws {
        let h = try Harness { $0.sessionInactivityMs = 100; $0.sessionMaxDurationMs = 250 }
        defer { h.cleanup() }
        await h.rum.grantConsent()
        let first = await h.rum.snapshot().sessionId
        for _ in 0..<2 { h.advance(90); await h.rum.recordMetric(name: "sample", value: 1) }
        let active = await h.rum.snapshot()
        XCTAssertEqual(active.sessionId, first)
        h.advance(90)
        await h.rum.recordMetric(name: "sample", value: 1)
        let rotated = await h.rum.snapshot()
        XCTAssertNotEqual(rotated.sessionId, first, "Continuous activity must not defeat the hard cap")
        await h.rum.withdrawConsent()
        let denied = await h.rum.snapshot()
        XCTAssertNil(denied.sessionId)
        await h.rum.grantConsent()
        let fresh = await h.rum.snapshot()
        XCTAssertNotEqual(fresh.sessionId, rotated.sessionId)
        XCTAssertEqual(fresh.pending, 0)
        assertConserved(fresh)
    }

    func testFlushDoesNotExtendSessionActivity() async throws {
        let h = try Harness { $0.sessionInactivityMs = 100 }
        defer { h.cleanup() }
        await h.rum.grantConsent()
        let first = await h.rum.snapshot().sessionId
        h.advance(90)
        await h.rum.flush()
        h.advance(11)
        await h.rum.recordMetric(name: "sample", value: 1)
        let later = await h.rum.snapshot()
        XCTAssertNotEqual(later.sessionId, first)
    }
}
