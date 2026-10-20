import Foundation

public struct RumConfig: Sendable {
    public var endpoint: String
    public var publicIngestKey: String
    public var accountId: String
    public var projectId: String
    public var serviceName: String
    public var allowedOrigins: Set<String>
    public var maxQueueBytes = 256 * 1024
    public var maxQueueAgeMs: Int64 = 24 * 60 * 60 * 1_000
    public var maxAttempts = 3
    public var maxBatchesPerFlush = 64
    public var retryBaseMs: Int64 = 500
    public var maxRetryDelayMs: Int64 = 30_000
    public var requestTimeoutMs: Int64 = 10_000
    public var flushIntervalMs: Int64 = 1_000
    public var sessionInactivityMs: Int64 = 30 * 60 * 1_000
    public var sessionMaxDurationMs: Int64 = 4 * 60 * 60 * 1_000

    public init(endpoint: String, publicIngestKey: String, accountId: String,
                projectId: String, serviceName: String, allowedOrigins: Set<String> = []) {
        self.endpoint = endpoint
        self.publicIngestKey = publicIngestKey
        self.accountId = accountId
        self.projectId = projectId
        self.serviceName = serviceName
        self.allowedOrigins = allowedOrigins
    }

    func validate() throws {
        guard maxQueueBytes > 0, (1...10).contains(maxAttempts), maxBatchesPerFlush > 0,
              [maxQueueAgeMs, retryBaseMs, maxRetryDelayMs, requestTimeoutMs,
               flushIntervalMs, sessionInactivityMs, sessionMaxDurationMs]
                .allSatisfy({ $0 > 0 && $0 <= 86_400_000 * 365 }),
              [publicIngestKey, accountId, projectId, serviceName].allSatisfy({
                  !$0.isEmpty && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
              }) else { throw RumError.invalidConfiguration }
    }
}

/// One actor, one store owner, one export in flight. All persistence occurs before
/// returning from admission and before starting a network attempt. Disk errors fail
/// closed and are exposed through snapshot(), without crashing the host application.
public actor Rum {
    private let config: RumConfig
    private let store: any QueueStore
    private let connectivity: any Connectivity
    private let transportFactory: @Sendable () throws -> any Transport
    private let now: @Sendable () -> Int64
    private let random: @Sendable () -> Double
    private let automaticFlush: Bool
    private var ledger = Ledger()
    private var loaded = false
    private var consent = Consent.denied
    private var epoch: UInt64 = 0
    private var session: String?
    private var sessionStarted: Int64 = 0
    private var sessionSeen: Int64 = 0
    private var transport: (any Transport)?
    private var timer: Task<Void, Never>?
    private var active: (id: String, task: Task<Outcome, Never>)?
    private var flushing = false
    private var storageHealthy = true
    private var accountingUncertain = false
    private var decision = "denied_default"

    /// Resolves a storage identity but creates no files, session, exporter, monitor,
    /// or timer. A nil storageURL uses Application Support/epok-rum/<SHA256>.json.
    public init(config: RumConfig, connectivity: any Connectivity = NetworkConnectivity(),
                storageURL: URL? = nil) throws {
        self.config = config
        self.connectivity = connectivity
        let file: URL
        if let storageURL { file = storageURL }
        else { file = try FileQueueStore.applicationSupportFile(config: config) }
        store = FileQueueStore(file: file)
        transportFactory = { try HTTPTransport(config: config) }
        now = { wallTimeMilliseconds() }
        random = { Double.random(in: 0...1) }
        automaticFlush = true
    }

    init(config: RumConfig, store: any QueueStore, connectivity: any Connectivity,
         transportFactory: @escaping @Sendable () throws -> any Transport,
         now: @escaping @Sendable () -> Int64, random: @escaping @Sendable () -> Double = { 1 },
         automaticFlush: Bool = false) {
        self.config = config
        self.store = store
        self.connectivity = connectivity
        self.transportFactory = transportFactory
        self.now = now
        self.random = random
        self.automaticFlush = automaticFlush
    }

    @discardableResult
    public func grantConsent() -> Bool {
        if consent == .granted { return true }
        guard storageHealthy else { return false }
        do {
            try config.validate()
            guard load(), storageHealthy else { return false }
            trim()
            guard persist() else { return false }
            transport = try transportFactory()
            _ = touchSession()
            epoch &+= 1
            consent = .granted
            decision = "granted"
            if automaticFlush {
                let token = epoch
                connectivity.start { [weak self] in
                    Task { [weak self] in await self?.scheduledFlush(epoch: token) }
                }
                let interval = UInt64(config.flushIntervalMs) * 1_000_000
                timer = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let keepRunning = await self?.scheduledFlush(epoch: token), keepRunning else { return }
                        do { try await Task.sleep(nanoseconds: interval) }
                        catch { return }
                    }
                }
            }
            return true
        } catch {
            stopRuntime()
            decision = "grant_error"
            return false
        }
    }

    public func denyConsent() { withdrawConsent() }

    public func withdrawConsent() {
        stopRuntime() // Gate and epoch close BEFORE disk work or cancellation completion.
        let readable = load()
        ledger.counters.dropped_error += Int64(ledger.batches.count)
        ledger.batches.removeAll()
        if !readable { ledger.accountingUncertain = true }
        accountingUncertain = accountingUncertain || ledger.accountingUncertain
        decision = readable ? "withdrawn_purged" : "withdrawn_purged_accounting_uncertain"
        if persist() { loaded = true }
    }

    /// Releases runtime resources and retains the durable queue. Not withdrawal.
    public func close() {
        stopRuntime()
        decision = "closed_durable_queue_retained"
    }

    private func stopRuntime() {
        consent = .denied
        epoch &+= 1
        session = nil
        active?.task.cancel()
        active = nil
        timer?.cancel()
        timer = nil
        connectivity.stop()
        transport?.cancel()
        transport = nil
    }

    deinit {
        timer?.cancel()
        active?.task.cancel()
        transport?.cancel()
        connectivity.stop()
    }

    @discardableResult
    private func scheduledFlush(epoch token: UInt64) async -> Bool {
        guard token == epoch, consent == .granted else { return false }
        await flush()
        return token == epoch && consent == .granted
    }

    private func load() -> Bool {
        if loaded { return true }
        do {
            ledger = try store.load()
            loaded = true
            accountingUncertain = ledger.accountingUncertain
            if accountingUncertain {
                storageHealthy = false
                decision = "accounting_uncertain_export_suspended"
            }
            return true
        } catch {
            storageHealthy = false
            accountingUncertain = true
            decision = "storage_read_error_preserved"
            return false
        }
    }

    @discardableResult
    private func persist() -> Bool {
        do { try store.save(ledger); return true }
        catch {
            storageHealthy = false
            decision = "storage_write_error_export_suspended"
            return false
        }
    }

    private func touchSession() -> String {
        let time = now()
        if session == nil || time < sessionSeen || time - sessionSeen > config.sessionInactivityMs ||
            time - sessionStarted > config.sessionMaxDurationMs {
            session = IDs.hex(bytes: 16)
            sessionStarted = time
        }
        sessionSeen = time
        return session! // Established immediately above; this method has no suspension.
    }

    public func snapshot() -> RumSnapshot {
        RumSnapshot(consent: consent, sessionId: session, counters: ledger.counters,
                    pending: ledger.batches.count, queuedBytes: queuedBytes(),
                    batchIds: ledger.batches.map(\.id), lastDecision: decision,
                    storageHealthy: storageHealthy, accountingUncertain: accountingUncertain,
                    exporterConstructed: transport != nil, ledgerLoaded: loaded)
    }

    private func queuedBytes() -> Int {
        ledger.batches.reduce(0) { partial, batch in
            let (total, overflow) = partial.addingReportingOverflow(batch.bytes)
            return overflow ? Int.max : total
        }
    }

    private func drop(id: String, capacity: Bool) {
        guard let index = ledger.batches.firstIndex(where: { $0.id == id }) else { return }
        ledger.batches.remove(at: index)
        if capacity { ledger.counters.dropped_capacity += 1 }
        else { ledger.counters.dropped_error += 1 }
        if active?.id == id { active?.task.cancel() }
        decision = capacity ? "dropped_capacity" : "dropped_error"
    }

    @discardableResult
    private func trim() -> Bool {
        let before = ledger.batches.count
        let time = now()
        for batch in ledger.batches where time >= batch.createdAt && time - batch.createdAt >= config.maxQueueAgeMs {
            drop(id: batch.id, capacity: false)
        }
        while queuedBytes() > config.maxQueueBytes, let oldest = ledger.batches.first {
            drop(id: oldest.id, capacity: true)
        }
        return before != ledger.batches.count
    }

    private func admit(signal: Signal, sessionId: String, event: () throws -> [String: Any]) {
        ledger.counters.attempted += 1
        guard storageHealthy else {
            ledger.counters.dropped_error += 1
            decision = "dropped_error_storage_unavailable"
            return
        }
        do {
            let id = IDs.hex(bytes: 16)
            let body = try Otlp.envelope(signal: signal, event: event(), id: id, session: sessionId,
                                         config: config, counters: ledger.counters)
            ledger.batches.append(Batch(id: id, signal: signal, body: body, createdAt: now()))
            decision = "queued"
            trim()
        } catch {
            ledger.counters.dropped_error += 1
            decision = "dropped_error_construction"
        }
        persist()
    }

    public func recordHTTP(url: String, method: String = "GET", status: Int = 200) {
        guard consent == .granted else { return }
        let time = now(), sessionId = touchSession()
        admit(signal: .traces, sessionId: sessionId) {
            try Otlp.span(url: url, method: method, context: .fresh(), start: time, end: time, status: status)
        }
    }

    public func recordMetric(name: String, value: Double) {
        guard consent == .granted else { return }
        let sessionId = touchSession()
        admit(signal: .metrics, sessionId: sessionId) { try Otlp.metric(name: name, value: value, now: now()) }
    }

    struct Capture: Sendable {
        let epoch: UInt64
        let session: String
        let context: TraceContext
        let start: Int64
    }

    struct Prepared: Sendable {
        let request: URLRequest
        let capture: Capture?
        let owned: [OwnedHeader]
    }

    func prepare(_ request: URLRequest, owned: [OwnedHeader] = []) -> Prepared {
        let base = Propagation.stripOwned(request, owned: owned)
        guard consent == .granted, let url = base.url else {
            return Prepared(request: base, capture: nil, owned: [])
        }
        let sid = touchSession()
        let priorSDKContext = owned.contains {
            $0.name == "traceparent" && $0.added == request.value(forHTTPHeaderField: "traceparent")
        } ? TraceContext.parse(request.value(forHTTPHeaderField: "traceparent")) : nil
        let context = TraceContext.parse(base.value(forHTTPHeaderField: "traceparent")) ?? priorSDKContext ?? .fresh()
        let capture = Capture(epoch: epoch, session: sid, context: context, start: now())
        if Propagation.permits(url, allowed: config.allowedOrigins) {
            let (injected, fields) = Propagation.inject(base, session: sid, context: context)
            decision = "propagation_allowed"
            return Prepared(request: injected, capture: capture, owned: fields)
        }
        decision = "propagation_denied_origin"
        return Prepared(request: base, capture: capture, owned: [])
    }

    private func finish(_ prepared: Prepared, status: Int) {
        guard let capture = prepared.capture, consent == .granted, epoch == capture.epoch else { return }
        admit(signal: .traces, sessionId: capture.session) {
            try Otlp.span(url: prepared.request.url?.absoluteString ?? Privacy.redacted,
                          method: prepared.request.httpMethod ?? "GET", context: capture.context,
                          start: capture.start, end: now(), status: status)
        }
    }

    /// Explicit URLSession instrumentation; host calls still run while consent is
    /// denied, but capture and SDK propagation do not. Use a reusable RumHTTPClient.
    /// Buffered data requests only; streams/background sessions are outside this POC.
    public func data(for request: URLRequest, using client: RumHTTPClient) async throws -> (Data, HTTPURLResponse) {
        var next = request
        var owned: [OwnedHeader] = []
        for hop in 0...10 {
            try Task.checkCancellation()
            let prepared = prepare(next, owned: owned)
            let result: (Data, HTTPURLResponse)
            do { result = try await client.send(prepared.request) }
            catch { finish(prepared, status: 0); throw error }
            finish(prepared, status: result.1.statusCode)
            let response = result.1
            guard [301, 302, 303, 307, 308].contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let currentURL = prepared.request.url,
                  let target = URL(string: location, relativeTo: currentURL)?.absoluteURL,
                  Origin.of(target) != nil else { return result }
            guard hop < 10 else { throw URLError(.httpTooManyRedirects) }
            next = prepared.request
            next.url = target
            owned = prepared.owned
            if Origin.of(currentURL) != Origin.of(target) {
                next.setValue(nil, forHTTPHeaderField: "Authorization")
                next.setValue(nil, forHTTPHeaderField: "Cookie")
                next.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
            }
            let method = next.httpMethod ?? "GET"
            if (response.statusCode == 303 && method != "HEAD") ||
                ([301, 302].contains(response.statusCode) && method == "POST") {
                next.httpMethod = "GET"
                next.httpBody = nil
                next.httpBodyStream = nil
                next.setValue(nil, forHTTPHeaderField: "Content-Length")
                next.setValue(nil, forHTTPHeaderField: "Content-Type")
            }
        }
        throw URLError(.httpTooManyRedirects)
    }

    /// A flush has a fixed starting set, one attempt per ID, and a total pass cap.
    /// Reentrant flush calls return while a pass is active. Retry never busy-loops.
    public func flush() async {
        guard !flushing, consent == .granted, storageHealthy else { return }
        flushing = true
        defer { flushing = false }
        let token = epoch
        let candidates = Array(ledger.batches.map(\.id).prefix(config.maxBatchesPerFlush))
        if trim() && !persist() { return }
        for id in candidates {
            guard !Task.isCancelled, consent == .granted, epoch == token, storageHealthy else { return }
            if trim() && !persist() { return }
            guard connectivity.isOnline(), let transport else { return }
            guard let index = ledger.batches.firstIndex(where: { $0.id == id }),
                  ledger.batches[index].notBefore <= now() else { continue }
            if ledger.batches[index].attempts >= config.maxAttempts {
                drop(id: id, capacity: false)
                if !persist() { return }
                continue
            }
            ledger.batches[index].attempts += 1
            ledger.counters.networkAttempts += 1
            // Attempt reservation survives a kill during the request.
            trim()
            guard persist() else { return }
            guard let batch = ledger.batches.first(where: { $0.id == id }) else { continue }
            let work = Task { await transport.send(batch) }
            active = (id, work)
            let outcome = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            if active?.id == id { active = nil }
            guard consent == .granted, epoch == token, storageHealthy else { return }
            guard let current = ledger.batches.firstIndex(where: { $0.id == id }) else { continue }
            if (200...299).contains(outcome.status) {
                ledger.batches.remove(at: current)
                ledger.counters.acked += 1
                decision = "acked"
            } else if (outcome.status != 0 && outcome.status != 429 && !(500...599).contains(outcome.status)) ||
                ledger.batches[current].attempts >= config.maxAttempts {
                drop(id: id, capacity: false)
            } else {
                let time = now()
                let delay = retryDelay(config: config, outcome: outcome,
                                       attempts: ledger.batches[current].attempts, now: time, random: random())
                let (deadline, overflow) = time.addingReportingOverflow(delay)
                ledger.batches[current].notBefore = overflow ? Int64.max : deadline
                decision = "retry_scheduled"
            }
            trim()
            if !persist() { return }
        }
    }
}
