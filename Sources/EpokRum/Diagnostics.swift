import Foundation

public struct DeliveryCounters: Codable, Equatable, Sendable {
    // Android compatibility: attempted means observations admitted, NOT HTTP attempts.
    public internal(set) var attempted: Int64 = 0
    public internal(set) var acked: Int64 = 0
    public internal(set) var dropped_capacity: Int64 = 0
    public internal(set) var dropped_error: Int64 = 0
    /// Durable reservations for HTTP attempts, including a kill before socket send.
    public internal(set) var networkAttempts: Int64 = 0

    /// Includes observations immediately dropped during construction or admission.
    public var enqueued: Int64 { attempted }
    public var dropped: Int64 { dropped_capacity + dropped_error }
}

public struct RumSnapshot: Sendable {
    public let consent: Consent
    public let sessionId: String?
    public let counters: DeliveryCounters
    public let pending: Int
    public let queuedBytes: Int
    public let batchIds: [String]
    public let lastDecision: String
    public let storageHealthy: Bool
    public let accountingUncertain: Bool
    public let exporterConstructed: Bool
    /// False until an explicit grant/denial reads the dormant ledger.
    public let ledgerLoaded: Bool

    public var isConserved: Bool {
        counters.enqueued == counters.acked + counters.dropped + Int64(pending)
    }
}

enum RumError: Error {
    case invalidConfiguration
    case invalidLedger
    case invalidObservation
}

func matches(_ value: String, _ pattern: String) -> Bool {
    guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
    // ICU's $ can match before a final newline. Anchored validators must consume
    // the entire value (Android Regex.matches semantics), including that newline.
    return !pattern.hasSuffix("$") || range == (value.startIndex..<value.endIndex)
}

func wallTimeMilliseconds() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
}

/// NSLock is used only in synchronous methods, never across an await. All mutable
/// contents are private; callers must not return mutable references from withValue.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
