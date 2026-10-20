import Foundation
import XCTest
@testable import EpokRum

final class ConsentInvariantTests: XCTestCase {
    func testDeniedByDefaultCapturesQueuesAndConstructsNothing() async throws {
        let h = try Harness(replies: [.init(status: 200)])
        defer { h.cleanup() }
        await h.rum.recordHTTP(url: "https://app.example/private")
        await h.rum.recordMetric(name: "sample", value: 1)
        await h.rum.flush()
        let client = h.hostClient()
        defer { client.close() }
        _ = try await h.rum.data(for: h.request(), using: client)
        let request = try XCTUnwrap(h.stub.requests.first)
        XCTAssertNil(request.header("traceparent"))
        XCTAssertNil(request.header("baggage"))
        let state = await h.rum.snapshot()
        XCTAssertEqual(state.consent, .denied)
        XCTAssertNil(state.sessionId)
        XCTAssertEqual(state.counters.enqueued, 0, "Denied host requests must not capture")
        XCTAssertEqual(state.pending, 0)
        XCTAssertFalse(state.exporterConstructed)
        XCTAssertFalse(state.ledgerLoaded)
        XCTAssertEqual(h.constructions.withValue { $0 }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.file.path))
        assertConserved(state)
    }

    func testWithdrawalPurgesDiskAndMemoryAndRegrantDoesNotResurrect() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.rum.grantConsent()
        await h.rum.recordHTTP(url: "https://app.example/orders/42")
        let old = await h.rum.snapshot()
        XCTAssertEqual(try FileQueueStore(file: h.file).load().batches.count, 1)
        await h.rum.withdrawConsent()
        let denied = await h.rum.snapshot()
        XCTAssertEqual(denied.consent, .denied)
        XCTAssertNil(denied.sessionId)
        XCTAssertFalse(denied.exporterConstructed)
        XCTAssertEqual(denied.pending, 0)
        XCTAssertEqual(denied.counters.dropped_error, 1)
        XCTAssertTrue(try FileQueueStore(file: h.file).load().batches.isEmpty)
        XCTAssertFalse(try String(contentsOf: h.file, encoding: .utf8).contains("orders"), "Purge must remove observation bytes")
        await h.rum.recordMetric(name: "denied", value: 1)
        await h.rum.grantConsent()
        let granted = await h.rum.snapshot()
        XCTAssertNotEqual(granted.sessionId, old.sessionId)
        XCTAssertEqual(granted.pending, 0)
        XCTAssertEqual(granted.counters.enqueued, 1)
        assertConserved(granted)
    }

    func testExplicitDenialPurgesDormantQueueWithoutGrant() async throws {
        let first = try Harness()
        defer { first.cleanup() }
        await first.rum.grantConsent()
        await first.rum.recordMetric(name: "sample", value: 1)
        await first.rum.close()
        let next = try Harness(file: first.file)
        defer { next.cleanup() }
        let before = try Data(contentsOf: first.file)
        await next.rum.flush()
        XCTAssertEqual(try Data(contentsOf: first.file), before)
        await next.rum.denyConsent()
        let denied = await next.rum.snapshot()
        XCTAssertEqual(denied.counters.dropped_error, 1)
        XCTAssertEqual(next.constructions.withValue { $0 }, 0)
        XCTAssertTrue(try FileQueueStore(file: first.file).load().batches.isEmpty)
        assertConserved(denied)
    }

    func testInvalidConfigurationAndFactoryFailureKeepGateClosed() async throws {
        let invalid = try Harness { $0.maxAttempts = 0 }
        defer { invalid.cleanup() }
        let opened = await invalid.rum.grantConsent()
        XCTAssertFalse(opened)
        XCTAssertEqual(invalid.constructions.withValue { $0 }, 0)
        // Use a valid configuration so the throwing factory itself is exercised.
        let valid = try Harness()
        defer { valid.cleanup() }
        let failing = Rum(config: valid.config, store: FileQueueStore(file: valid.file), connectivity: valid.network,
                          transportFactory: { throw URLError(.unknown) }, now: { 1_700_000_000_000 })
        let factoryOpened = await failing.grantConsent()
        XCTAssertFalse(factoryOpened)
        let state = await failing.snapshot()
        XCTAssertEqual(state.consent, .denied)
        XCTAssertNil(state.sessionId)
        XCTAssertFalse(state.exporterConstructed)
    }

    func testConnectivityStartsOnlyAfterConsentAndStopsOnWithdrawal() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let monitor = CountingConnectivity()
        let rum = Rum(config: h.config, store: FileQueueStore(file: h.file), connectivity: monitor,
                      transportFactory: { try HTTPTransport(config: h.config, configuration: StubURLProtocol.configuration()) },
                      now: { 1_700_000_000_000 }, automaticFlush: true)
        XCTAssertEqual(monitor.starts.withValue { $0 }, 0)
        await rum.grantConsent()
        XCTAssertEqual(monitor.starts.withValue { $0 }, 1)
        await rum.withdrawConsent()
        XCTAssertEqual(monitor.stops.withValue { $0 }, 1)
        let state = await rum.snapshot()
        XCTAssertEqual(state.consent, .denied)
    }
}

private final class CountingConnectivity: Connectivity {
    let starts = Locked(0)
    let stops = Locked(0)
    func isOnline() -> Bool { false }
    func start(onChange: @escaping @Sendable () -> Void) { starts.withValue { $0 += 1 } }
    func stop() { stops.withValue { $0 += 1 } }
}
