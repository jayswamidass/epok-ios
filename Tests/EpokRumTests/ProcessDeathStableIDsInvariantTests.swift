import Foundation
import XCTest
@testable import EpokRum

final class ProcessDeathStableIDsInvariantTests: XCTestCase {
    func testReconstructedStoreKeepsUnackedBatchAndOneAckStaysAcked() async throws {
        var first: Harness? = try Harness(replies: [.init(status: 204), .init(status: 503)])
        let file = first!.file
        let directory = first!.directory
        let oldHosts = first!.hosts
        defer {
            try? FileManager.default.removeItem(at: directory)
            for host in oldHosts { _ = StubURLProtocol.registry.withValue { $0.removeValue(forKey: host) } }
        }
        await first!.rum.grantConsent()
        await first!.rum.recordMetric(name: "already.acked", value: 1)
        await first!.rum.recordHTTP(url: "https://app.example/users/42?token=private")
        first!.network.setOnline(true)
        await first!.rum.flush()
        let before = await first!.rum.snapshot()
        XCTAssertEqual(before.counters.acked, 1)
        XCTAssertEqual(before.pending, 1)
        let saved = try FileQueueStore(file: file).load().batches[0]
        XCTAssertEqual(saved.attempts, 1)
        XCTAssertEqual(saved.notBefore, 1_700_000_000_100)
        await first!.rum.close() // Release resources; close performs no ledger writes.
        first = nil // Release the original Rum and store objects; use a NEW FileQueueStore below.
        let bytesBeforeRelaunch = try Data(contentsOf: file)
        let recoveredStore = FileQueueStore(file: file)
        let disk = try recoveredStore.load()
        XCTAssertEqual(disk.batches, [saved], "ID, body, attempts and deadline must survive object reconstruction")
        XCTAssertEqual(disk.counters.acked, 1)
        let next = try Harness(replies: [.init(status: 200)], file: file, store: recoveredStore)
        defer { next.cleanup() }
        await next.rum.flush()
        let dormant = await next.rum.snapshot()
        XCTAssertEqual(dormant.consent, .denied)
        XCTAssertFalse(dormant.exporterConstructed)
        XCTAssertFalse(dormant.ledgerLoaded)
        XCTAssertTrue(next.stub.requests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), bytesBeforeRelaunch)
        await next.rum.grantConsent()
        let restored = await next.rum.snapshot()
        XCTAssertEqual(restored.batchIds, [saved.id])
        XCTAssertEqual(restored.counters.acked, 1)
        XCTAssertNotEqual(restored.sessionId, before.sessionId)
        next.network.setOnline(true)
        await next.rum.flush()
        XCTAssertTrue(next.stub.requests.isEmpty, "Persisted retry deadline must block an early resend")
        next.advance(100)
        await next.rum.flush()
        let done = await next.rum.snapshot()
        XCTAssertEqual(done.counters.enqueued, 2)
        XCTAssertEqual(done.counters.acked, 2)
        XCTAssertEqual(done.pending, 0)
        XCTAssertEqual(next.stub.requests.count, 1, "Previously acked observation must NOT be sent again")
        XCTAssertEqual(next.stub.requests.first?.body, Data(saved.body.utf8))
        let third = try FileQueueStore(file: file).load()
        XCTAssertEqual(third.counters.acked, 2)
        XCTAssertTrue(third.batches.isEmpty)
        assertConserved(done)
    }

    func testAttemptCapSurvivesRelaunchAndKillAfterAttemptReservation() async throws {
        let first = try Harness(replies: [.init(status: 503)])
        defer { first.cleanup() }
        await first.rum.grantConsent()
        await first.rum.recordMetric(name: "sample", value: 1)
        first.network.setOnline(true)
        await first.rum.flush()
        await first.rum.close()
        let next = try Harness(replies: [.init(status: 500), .init(status: 500)], file: first.file,
                               now: 1_700_000_000_100)
        defer { next.cleanup() }
        await next.rum.grantConsent()
        next.network.setOnline(true)
        await next.rum.flush()
        next.advance(200)
        await next.rum.flush()
        next.advance(10_000)
        await next.rum.flush()
        let done = await next.rum.snapshot()
        XCTAssertEqual(next.stub.requests.count, 2, "Three attempts TOTAL across both runtimes")
        XCTAssertEqual(done.counters.acked, 0)
        XCTAssertEqual(done.counters.dropped_error, 1)
        XCTAssertEqual(done.pending, 0)
        assertConserved(done)

        // Simulate a crash after the last reservation was saved, before a response was handled.
        let interrupted = try Harness()
        defer { interrupted.cleanup() }
        await interrupted.rum.grantConsent()
        await interrupted.rum.recordMetric(name: "interrupted", value: 1)
        await interrupted.rum.close()
        let store = FileQueueStore(file: interrupted.file)
        var ledger = try store.load()
        ledger.batches[0].attempts = 3
        ledger.counters.networkAttempts = 3
        try store.save(ledger)
        let afterKill = try Harness(file: interrupted.file)
        defer { afterKill.cleanup() }
        await afterKill.rum.grantConsent()
        afterKill.network.setOnline(true)
        await afterKill.rum.flush()
        let exhausted = await afterKill.rum.snapshot()
        XCTAssertTrue(afterKill.stub.requests.isEmpty)
        XCTAssertEqual(exhausted.counters.dropped_error, 1)
        assertConserved(exhausted)
    }

    func testCorruptLedgerIsPreservedUntilDenialThenMarksUncertainty() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try Data("corrupt-secret".utf8).write(to: h.file, options: .atomic)
        let granted = await h.rum.grantConsent()
        XCTAssertFalse(granted)
        XCTAssertEqual(try String(contentsOf: h.file, encoding: .utf8), "corrupt-secret")
        await h.rum.withdrawConsent()
        let denied = await h.rum.snapshot()
        XCTAssertTrue(denied.accountingUncertain, "Unknown lost counts must not be invented")
        XCTAssertTrue(try FileQueueStore(file: h.file).load().accountingUncertain)
        XCTAssertFalse(try String(contentsOf: h.file, encoding: .utf8).contains("corrupt-secret"))
        let next = try Harness(file: h.file)
        defer { next.cleanup() }
        let reopened = await next.rum.grantConsent()
        XCTAssertFalse(reopened, "Uncertain accounting must suspend export after relaunch too")
        XCTAssertEqual(next.constructions.withValue { $0 }, 0)
    }

    func testLedgerRejectsBrokenConservationAndDuplicateBatchIDs() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.rum.grantConsent()
        await h.rum.recordMetric(name: "sample", value: 1)
        let store = FileQueueStore(file: h.file)
        var ledger = try store.load()
        ledger.counters.acked = 1
        XCTAssertThrowsError(try store.save(ledger), "Broken conservation must not reach disk")
        ledger.counters.acked = 0
        ledger.batches.append(ledger.batches[0])
        ledger.counters.attempted = 2
        XCTAssertThrowsError(try store.save(ledger), "Duplicate durable IDs must be rejected")
    }

    func testExternalSimulatorProcessDeathFlowRequiresHostApp() throws {
        throw XCTSkip("Optional out-of-process flow: follow Sample/README.md with a separately built host app. In-package reconstruction is tested above.")
    }
}
