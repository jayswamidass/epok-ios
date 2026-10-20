import Foundation
import XCTest
@testable import EpokReplay

final class ReplayUploadTests: XCTestCase {
    func testRevocationPurgesOfflineBytesAndRejectsLateAdmission() {
        let upload = ReplayUpload(endpoint: URL(string: "https://collector.invalid/s/")!)
        upload.setOffline(true)
        upload.admit { ["event": "$snapshot", "private": "test-only"] }
        XCTAssertGreaterThan(upload.snapshot()["queuedBytes"]!, 0)
        upload.revoke()
        upload.admit {
            XCTFail("Serialization must not run after withdrawal")
            return [:]
        }
        upload.setOffline(false)
        upload.flush()
        XCTAssertEqual(upload.snapshot()["queuedBytes"], 0)
        XCTAssertEqual(upload.snapshot()["delivered"], 0)
    }

    func testAdmissionRacingRevocationCannotRecreateQueue() {
        let upload = ReplayUpload(endpoint: URL(string: "https://collector.invalid/s/")!)
        upload.setOffline(true)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index == 50 { upload.revoke() }
            upload.admit { ["index": index, "event": "$snapshot"] }
        }
        XCTAssertEqual(upload.snapshot()["queuedBytes"], 0)
        upload.revoke()
    }

    func testNewGrantCannotReopenOldGenerationAndCapIsBounded() {
        let old = ReplayUpload(endpoint: URL(string: "https://collector.invalid/s/")!)
        old.setOffline(true)
        old.admit { ["old": "payload"] }
        old.revoke()
        let next = ReplayUpload(endpoint: URL(string: "https://collector.invalid/s/")!, maxBytes: 64)
        defer { next.revoke() }
        next.setOffline(true)
        old.admit { XCTFail("old grant reopened"); return [:] }
        next.admit { ["new": "payload"] }
        XCTAssertGreaterThan(next.snapshot()["queuedBytes"]!, 0)
        next.admit { ["oversize": String(repeating: "x", count: 100)] }
        XCTAssertLessThanOrEqual(next.snapshot()["queuedBytes"]!, 64)
        XCTAssertEqual(next.snapshot()["dropped"], 1)
        XCTAssertEqual(old.snapshot()["queuedBytes"], 0)
    }
}

private final class UploadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started: XCTestExpectation?
    private var stopped: XCTestExpectation?
    func arm(started: XCTestExpectation, stopped: XCTestExpectation) {
        lock.lock()
        defer { lock.unlock() }
        self.started = started
        self.stopped = stopped
    }
    func didStart() {
        lock.lock()
        defer { lock.unlock() }
        started?.fulfill()
        started = nil
    }
    func didStop() {
        lock.lock()
        defer { lock.unlock() }
        stopped?.fulfill()
        stopped = nil
    }
}

private final class PendingUpload: URLProtocol, @unchecked Sendable {
    static let probe = UploadProbe()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.probe.didStart() }
    override func stopLoading() { Self.probe.didStop() }
}

extension ReplayUploadTests {
    func testWithdrawalCancelsInFlightUploadAndPurgesItsQueueEntry() {
        let started = expectation(description: "upload started")
        let stopped = expectation(description: "upload cancelled")
        PendingUpload.probe.arm(started: started, stopped: stopped)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingUpload.self]
        let upload = ReplayUpload(endpoint: URL(string: "https://collector.invalid/s/")!, configuration: configuration)
        upload.admit { ["event": "$snapshot", "private": "queued"] }
        wait(for: [started], timeout: 5)
        XCTAssertGreaterThan(upload.snapshot()["queuedBytes"]!, 0)
        upload.revoke()
        wait(for: [stopped], timeout: 5)
        upload.admit { XCTFail("late capture admitted after cancellation"); return [:] }
        XCTAssertEqual(upload.snapshot()["queuedBytes"], 0)
        XCTAssertEqual(upload.snapshot()["delivered"], 0)
    }
}
