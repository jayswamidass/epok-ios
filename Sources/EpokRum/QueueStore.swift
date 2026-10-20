import Foundation
import CryptoKit

enum Signal: String, Codable, Sendable {
    case traces, metrics
}

/// One observation per immutable payload. Only retry metadata changes on resend.
struct Batch: Codable, Equatable, Sendable {
    let id: String
    let signal: Signal
    let body: String
    let createdAt: Int64
    var attempts = 0
    var notBefore: Int64 = 0

    var bytes: Int {
        // All fields are JSON-encodable. A failure is a programming error, never size zero.
        (try? JSONEncoder().encode(self).count) ?? Int.max
    }
}

struct Ledger: Codable, Sendable {
    var version = 1
    var counters = DeliveryCounters()
    var batches: [Batch] = []
    var accountingUncertain = false

    func validate() throws {
        guard version == 1 else { throw RumError.invalidLedger }
        let c = counters
        guard [c.attempted, c.acked, c.dropped_capacity, c.dropped_error, c.networkAttempts]
            .allSatisfy({ $0 >= 0 }) else { throw RumError.invalidLedger }
        var total = Int64(batches.count)
        for count in [c.acked, c.dropped_capacity, c.dropped_error] {
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { throw RumError.invalidLedger }
            total = next
        }
        guard c.enqueued == total else { throw RumError.invalidLedger }
        var ids = Set<String>()
        for batch in batches {
            guard matches(batch.id, "^[0-9a-f]{32}$"), ids.insert(batch.id).inserted,
                  batch.attempts >= 0, batch.attempts <= 10,
                  batch.createdAt >= 0, batch.notBefore >= 0,
                  !batch.body.isEmpty else { throw RumError.invalidLedger }
        }
    }
}

protocol QueueStore: Sendable {
    func load() throws -> Ledger
    func save(_ ledger: Ledger) throws
}

/// Stateless file operations; exactly ONE Rum actor may own a given file at a time.
struct FileQueueStore: QueueStore {
    let file: URL

    static func applicationSupportFile(config: RumConfig) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        let identity = [config.endpoint, config.accountId, config.projectId,
                        config.serviceName, config.publicIngestKey].joined(separator: "\0")
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("epok-rum", isDirectory: true)
            .appendingPathComponent("\(hash).json")
    }

    func load() throws -> Ledger {
        guard FileManager.default.fileExists(atPath: file.path) else { return Ledger() }
        let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: file))
        try ledger.validate()
        return ledger
    }

    func save(_ ledger: Ledger) throws {
        try ledger.validate()
        var directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Atomic replacement covers counters, batch IDs, bodies, and attempts together.
        try encoder.encode(ledger).write(to: file, options: .atomic)
    }
}
