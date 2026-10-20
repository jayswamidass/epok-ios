import Foundation

/// JSONSerialization dictionaries stay local to synchronous serialization; no Any
/// values cross actor boundaries. The resulting immutable UTF-8 string is Sendable.
enum Otlp {
    private static func attributes(_ values: [String: Any]) -> [[String: Any]] {
        values.keys.sorted().map { key in
            let value = values[key]!
            let typed: [String: Any]
            switch value {
            case let flag as Bool: typed = ["boolValue": flag]
            case let integer as Int: typed = ["intValue": String(integer)]
            case let integer as Int64: typed = ["intValue": String(integer)]
            case let number as Double: typed = ["doubleValue": number]
            default: typed = ["stringValue": String(describing: value)]
            }
            return ["key": key, "value": typed]
        }
    }

    private static func nanos(_ ms: Int64) throws -> String {
        let (value, overflow) = ms.multipliedReportingOverflow(by: 1_000_000)
        guard ms >= 0, !overflow else { throw RumError.invalidObservation }
        return String(value)
    }

    static func span(url: String, method: String, context: TraceContext,
                     start: Int64, end: Int64, status: Int) throws -> [String: Any] {
        let safe = Privacy.scrubURL(url)
        let verb = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "CONNECT", "TRACE"]
            .contains(method) ? method : "HTTP"
        return [
            "traceId": context.traceId, "spanId": context.spanId,
            "name": "\(verb) \(safe)", "kind": 3,
            "startTimeUnixNano": try nanos(start), "endTimeUnixNano": try nanos(max(start, end)),
            "status": ["code": status == 0 || status >= 400 ? 2 : 1],
            "attributes": attributes(["http.url": safe, "http.method": verb, "http.status_code": status])
        ]
    }

    static func metric(name: String, value: Double, now: Int64) throws -> [String: Any] {
        guard matches(name, "^[a-zA-Z][a-zA-Z0-9_.-]{0,63}$"), value.isFinite else {
            throw RumError.invalidObservation
        }
        return ["name": name, "unit": "1", "gauge": ["dataPoints": [
            ["timeUnixNano": try nanos(now), "asDouble": value]
        ]]]
    }

    static func envelope(signal: Signal, event: [String: Any], id: String, session: String,
                         config: RumConfig, counters: DeliveryCounters) throws -> String {
        let resource: [String: Any] = ["attributes": attributes([
            "service.name": config.serviceName, "telemetry.sdk.name": "epok-rum-ios",
            "telemetry.sdk.language": "swift", "rum": true, "session.id": session, "rum.batch.id": id,
            "rum.delivery.attempted": counters.attempted, "rum.delivery.acked": counters.acked,
            "rum.delivery.dropped_capacity": counters.dropped_capacity,
            "rum.delivery.dropped_error": counters.dropped_error
        ])]
        let spans = signal == .traces
        let scope: [String: Any] = ["scope": ["name": "epok-rum-ios"], (spans ? "spans" : "metrics"): [event]]
        let group: [String: Any] = ["resource": resource, (spans ? "scopeSpans" : "scopeMetrics"): [scope]]
        let root: [String: Any] = [(spans ? "resourceSpans" : "resourceMetrics"): [group]]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
