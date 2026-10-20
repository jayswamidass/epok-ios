import Foundation
import XCTest
@testable import EpokRum

// Shared test support lives here to keep exactly one test source file per invariant.
struct StubReply: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var offline = false
}

struct RecordedRequest: Sendable {
    let url: URL
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

final class HTTPStub: Sendable {
    private struct State: Sendable {
        var replies: [StubReply]
        var requests: [RecordedRequest] = []
    }
    private let state: Locked<State>
    init(_ replies: [StubReply] = []) { state = Locked(State(replies: replies)) }
    var requests: [RecordedRequest] { state.withValue { $0.requests } }

    func receive(_ request: URLRequest) -> StubReply {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let record = RecordedRequest(url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        return state.withValue {
            $0.requests.append(record)
            // An exhausted script fails closed; it must never silently produce a success.
            return $0.replies.isEmpty ? StubReply(offline: true) : $0.replies.removeFirst()
        }
    }
}

// URLProtocol owns its inherited lifecycle state; this subclass adds no instance
// state. The shared fixture registry and each response script use Locked storage.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = Locked<[String: HTTPStub]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let stub = Self.registry.withValue({ $0[url.host?.lowercased() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let reply = stub.receive(request)
        if reply.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        // Deliver 3xx as a response: the production client owns its redirect loop.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }
}

final class Harness: Sendable {
    let rum: Rum
    let file: URL
    let directory: URL
    let config: RumConfig
    let stub: HTTPStub
    let network: ManualConnectivity
    let clock: Locked<Int64>
    let constructions = Locked(0)
    let hosts: [String]

    init(replies: [StubReply] = [], file: URL? = nil, now: Int64 = 1_700_000_000_000,
         automaticFlush: Bool = false, store: (any QueueStore)? = nil,
         transport: (any Transport)? = nil, configure: (inout RumConfig) -> Void = { _ in }) throws {
        let identity = UUID().uuidString.lowercased()
        hosts = ["collector-\(identity).invalid", "api-\(identity).invalid", "api-\(identity).invalid.evil.test"]
        directory = file?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("epok-rum-tests-\(identity)", isDirectory: true)
        self.file = file ?? directory.appendingPathComponent("ledger.json")
        var config = RumConfig(endpoint: "https://\(hosts[0])/prefix/", publicIngestKey: "public-poc-ingest-only",
                               accountId: "account", projectId: "project", serviceName: "test",
                               allowedOrigins: ["https://\(hosts[1])"])
        config.retryBaseMs = 100
        config.maxRetryDelayMs = 500
        configure(&config)
        self.config = config
        let frozenConfig = config
        let script = HTTPStub(replies)
        stub = script
        for host in hosts { StubURLProtocol.registry.withValue { $0[host] = script } }
        network = ManualConnectivity(initiallyOnline: false)
        clock = Locked(now)
        let count = constructions, testClock = clock
        rum = Rum(config: config, store: store ?? FileQueueStore(file: self.file), connectivity: network,
                  transportFactory: {
                      count.withValue { $0 += 1 }
                      if let transport { return transport }
                      return try HTTPTransport(config: frozenConfig, configuration: StubURLProtocol.configuration())
                  }, now: { testClock.withValue { $0 } }, automaticFlush: automaticFlush)
    }

    func advance(_ ms: Int64) { clock.withValue { $0 += ms } }
    func cleanup() {
        for host in hosts { _ = StubURLProtocol.registry.withValue { $0.removeValue(forKey: host) } }
        try? FileManager.default.removeItem(at: directory)
    }
    func hostClient() -> RumHTTPClient { RumHTTPClient(configuration: StubURLProtocol.configuration()) }
    func request(path: String = "/users", hostIndex: Int = 1) -> URLRequest {
        URLRequest(url: URL(string: "https://\(hosts[hostIndex])\(path)")!)
    }
}

func assertConserved(_ state: RumSnapshot, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(state.isConserved, "enqueued != acked + dropped + queued", file: file, line: line)
    XCTAssertEqual(state.counters.enqueued,
                   state.counters.acked + state.counters.dropped_capacity + state.counters.dropped_error + Int64(state.pending),
                   file: file, line: line)
}

final class FailingStore: QueueStore {
    let actual: FileQueueStore
    let failWrites = Locked(false)
    init(file: URL) { actual = FileQueueStore(file: file) }
    func load() throws -> Ledger { try actual.load() }
    func save(_ ledger: Ledger) throws {
        if failWrites.withValue({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
        try actual.save(ledger)
    }
}

/// Deliberately ignores cancellation so the late-response fence is actually tested.
actor SuspendedTransport: Transport {
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private(set) var sends = 0
    func send(_ batch: Batch) async -> Outcome {
        sends += 1
        return await withCheckedContinuation {
            continuation = $0
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if sends > 0 { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release() { continuation?.resume(returning: Outcome(status: 200)); continuation = nil }
    nonisolated func cancel() {}
}

final class TransportAccountingInvariantTests: XCTestCase {
    func test5xxDoesNotAckAndRetryAfterAndStablePayload() async throws {
        let h = try Harness(replies: [.init(status: 503), .init(status: 429, headers: ["Retry-After": "2"]), .init(status: 204)])
        defer { h.cleanup() }
        await h.rum.grantConsent()
        await h.rum.recordHTTP(url: "https://app.example/users/42?token=secret")
        let initial = await h.rum.snapshot()
        h.network.setOnline(true)
        await h.rum.flush()
        let failed = await h.rum.snapshot()
        XCTAssertEqual(failed.counters.acked, 0, "A 503 must NOT acknowledge an observation")
        XCTAssertEqual(failed.pending, 1)
        XCTAssertEqual(failed.batchIds, initial.batchIds)
        XCTAssertEqual(h.stub.requests.count, 1, "One attempt per batch per flush")
        h.advance(100)
        await h.rum.flush()
        h.advance(1_999)
        await h.rum.flush()
        XCTAssertEqual(h.stub.requests.count, 2, "Retry-After must exceed the 500ms local cap")
        h.advance(1)
        await h.rum.flush()
        let done = await h.rum.snapshot()
        XCTAssertEqual(done.counters.acked, 1)
        XCTAssertEqual(done.counters.enqueued, 1)
        XCTAssertEqual(done.counters.networkAttempts, 3)
        XCTAssertEqual(done.pending, 0)
        XCTAssertEqual(Set(h.stub.requests.map(\.body)).count, 1)
        XCTAssertTrue(h.stub.requests.allSatisfy { String(decoding: $0.body, as: UTF8.self).contains(initial.batchIds[0]) })
        XCTAssertTrue(try FileQueueStore(file: h.file).load().batches.isEmpty)
        assertConserved(done)
    }

    func testPermanent5xxHitsLifetimeCapAndTotalPerFlushCap() async throws {
        let h = try Harness(replies: Array(repeating: .init(status: 500), count: 6)) {
            $0.maxAttempts = 2
            $0.maxBatchesPerFlush = 1
        }
        defer { h.cleanup() }
        await h.rum.grantConsent()
        await h.rum.recordMetric(name: "first", value: 1)
        await h.rum.recordMetric(name: "second", value: 2)
        h.network.setOnline(true)
        await h.rum.flush()
        XCTAssertEqual(h.stub.requests.count, 1)
        h.advance(100)
        await h.rum.flush()
        let capped = await h.rum.snapshot()
        XCTAssertEqual(capped.counters.dropped_error, 1)
        XCTAssertEqual(capped.counters.acked, 0)
        XCTAssertEqual(capped.pending, 1)
        await h.rum.flush()
        h.advance(100)
        await h.rum.flush()
        for _ in 0..<5 { h.advance(100_000); await h.rum.flush() }
        let done = await h.rum.snapshot()
        XCTAssertEqual(h.stub.requests.count, 4, "Permanent 5xx must not resend forever")
        XCTAssertEqual(done.counters.dropped_error, 2)
        assertConserved(done)
    }

    func testOfflineErrorsAndTerminalStatuses() async throws {
        for status in [302, 400, 401, 403, 404, 408] {
            let h = try Harness(replies: [.init(status: status, headers: ["Location": "https://never.invalid/"])])
            await h.rum.grantConsent()
            await h.rum.recordMetric(name: "sample", value: 1)
            h.network.setOnline(true)
            await h.rum.flush()
            h.advance(1_000)
            await h.rum.flush()
            let state = await h.rum.snapshot()
            XCTAssertEqual(state.counters.acked, 0)
            XCTAssertEqual(state.counters.dropped_error, 1, "status \(status)")
            XCTAssertEqual(h.stub.requests.count, 1)
            assertConserved(state)
            h.cleanup()
        }
        let h = try Harness(replies: [.init(offline: true), .init(status: 202)])
        defer { h.cleanup() }
        await h.rum.grantConsent()
        await h.rum.recordMetric(name: "sample", value: 1)
        await h.rum.flush()
        XCTAssertTrue(h.stub.requests.isEmpty, "Offline gate must not spend an attempt")
        h.network.setOnline(true)
        await h.rum.flush()
        let failed = await h.rum.snapshot()
        XCTAssertEqual(failed.pending, 1)
        XCTAssertEqual(failed.counters.acked, 0)
        h.advance(100)
        await h.rum.flush()
        let done = await h.rum.snapshot()
        XCTAssertEqual(done.counters.acked, 1)
        assertConserved(done)
    }

    func testOfflineQueueEvictsByBytesAndAge() async throws {
        let measure = try Harness()
        defer { measure.cleanup() }
        await measure.rum.grantConsent()
        await measure.rum.recordMetric(name: "sample", value: 1)
        let size = await measure.rum.snapshot().queuedBytes
        let h = try Harness { $0.maxQueueBytes = size + 128; $0.maxQueueAgeMs = 1_000 }
        defer { h.cleanup() }
        await h.rum.grantConsent()
        await h.rum.recordMetric(name: "sample", value: 1)
        let first = await h.rum.snapshot().batchIds
        await h.rum.recordMetric(name: "sample", value: 2)
        let capacity = await h.rum.snapshot()
        XCTAssertEqual(capacity.pending, 1)
        XCTAssertNotEqual(capacity.batchIds, first, "Oldest observation must be evicted")
        XCTAssertEqual(capacity.counters.dropped_capacity, 1)
        XCTAssertLessThanOrEqual(capacity.queuedBytes, h.config.maxQueueBytes)
        h.advance(1_000)
        await h.rum.flush()
        let expired = await h.rum.snapshot()
        XCTAssertEqual(expired.pending, 0, "Age limit applies even offline")
        XCTAssertEqual(expired.counters.dropped_error, 1)
        XCTAssertTrue(h.stub.requests.isEmpty)
        assertConserved(expired)
        let tiny = try Harness { $0.maxQueueBytes = 1 }
        defer { tiny.cleanup() }
        await tiny.rum.grantConsent()
        await tiny.rum.recordMetric(name: "sample", value: 1)
        let rejected = await tiny.rum.snapshot()
        XCTAssertEqual(rejected.pending, 0)
        XCTAssertEqual(rejected.counters.dropped_capacity, 1)
        assertConserved(rejected)
    }

    func testConcurrentFlushAndLateAckAfterWithdrawal() async throws {
        let gate = SuspendedTransport()
        let h = try Harness(transport: gate)
        defer { h.cleanup() }
        await h.rum.grantConsent()
        await h.rum.recordMetric(name: "sample", value: 1)
        h.network.setOnline(true)
        let first = Task { await h.rum.flush() }
        await gate.waitUntilStarted()
        await h.rum.flush()
        let sends = await gate.sends
        XCTAssertEqual(sends, 1, "Actor reentrancy must not start a duplicate export")
        await h.rum.withdrawConsent()
        await h.rum.grantConsent()
        await gate.release()
        await first.value
        let state = await h.rum.snapshot()
        XCTAssertEqual(state.counters.acked, 0, "Late 200 from previous consent epoch must be ignored")
        XCTAssertEqual(state.counters.dropped_error, 1)
        XCTAssertEqual(state.pending, 0)
        assertConserved(state)
    }

    func testLateAckOfCapacityEvictedBatchIsIgnored() async throws {
        let measure = try Harness()
        defer { measure.cleanup() }
        await measure.rum.grantConsent()
        await measure.rum.recordMetric(name: "sample", value: 1)
        let size = await measure.rum.snapshot().queuedBytes
        let gate = SuspendedTransport()
        let h = try Harness(transport: gate) { $0.maxQueueBytes = size + 128 }
        defer { h.cleanup() }
        await h.rum.grantConsent()
        await h.rum.recordMetric(name: "sample", value: 1)
        h.network.setOnline(true)
        let flush = Task { await h.rum.flush() }
        await gate.waitUntilStarted()
        await h.rum.recordMetric(name: "sample", value: 2)
        await gate.release()
        await flush.value
        let state = await h.rum.snapshot()
        XCTAssertEqual(state.counters.acked, 0)
        XCTAssertEqual(state.counters.dropped_capacity, 1)
        XCTAssertEqual(state.pending, 1)
        assertConserved(state)
    }

    func testStorageFailureRetainsMemoryAndSuspendsExport() async throws {
        let base = try Harness()
        defer { base.cleanup() }
        let store = FailingStore(file: base.file)
        let h = try Harness(file: base.file, store: store)
        defer { h.cleanup() }
        await h.rum.grantConsent()
        store.failWrites.withValue { $0 = true }
        await h.rum.recordMetric(name: "sample", value: 1)
        await h.rum.recordMetric(name: "sample", value: 2)
        h.network.setOnline(true)
        await h.rum.flush()
        let failed = await h.rum.snapshot()
        XCTAssertFalse(failed.storageHealthy)
        XCTAssertEqual(failed.pending, 1, "Failed disk write must not pretend to drop retained memory")
        XCTAssertEqual(failed.counters.dropped_error, 1)
        XCTAssertTrue(h.stub.requests.isEmpty)
        assertConserved(failed)
        await h.rum.withdrawConsent()
        let granted = await h.rum.grantConsent()
        XCTAssertFalse(granted)
        let denied = await h.rum.snapshot()
        XCTAssertEqual(denied.counters.dropped_error, 2)
        XCTAssertTrue(denied.lastDecision.contains("storage_write_error"))
        assertConserved(denied)
    }

    func testRetryJitterAndHTTPDateBounds() throws {
        let h = try Harness()
        defer { h.cleanup() }
        let now: Int64 = 1_700_000_000_000
        XCTAssertEqual(retryDelay(config: h.config, outcome: .init(status: 503), attempts: 1, now: now, random: 0), 50)
        XCTAssertEqual(retryDelay(config: h.config, outcome: .init(status: 503), attempts: 10, now: now, random: 1), 500)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = formatter.string(from: Date(timeIntervalSince1970: Double(now + 60_000) / 1_000))
        XCTAssertEqual(retryDelay(config: h.config, outcome: .init(status: 429, retryAfter: date), attempts: 1, now: now, random: 0), 60_000)
        XCTAssertEqual(retryDelay(config: h.config, outcome: .init(status: 503, retryAfter: "garbage"), attempts: 1, now: now, random: 0), 50)
    }
}
