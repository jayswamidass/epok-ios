import Foundation

enum IDs {
    static func hex(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        var data = (0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        if data.allSatisfy({ $0 == 0 }) { data[data.count - 1] = 1 }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

struct TraceContext: Sendable, Equatable {
    let traceId: String
    let spanId: String
    var flags = "01"
    var header: String { "00-\(traceId)-\(spanId)-\(flags)" }
    static func fresh() -> TraceContext { TraceContext(traceId: IDs.hex(bytes: 16), spanId: IDs.hex(bytes: 8)) }

    static func parse(_ value: String?) -> TraceContext? {
        guard let value,
              matches(value, "^([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})(-[^\\s,]*)?$")
        else { return nil }
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces[0] != "ff", !(pieces[0] == "00" && pieces.count != 4),
              pieces[1].contains(where: { $0 != "0" }), pieces[2].contains(where: { $0 != "0" }) else { return nil }
        return TraceContext(traceId: String(pieces[1]), spanId: String(pieces[2]), flags: String(pieces[3]))
    }
}

struct Origin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    static func of(_ url: URL) -> Origin? {
        let text = url.absoluteString
        guard !text.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || $0 == "\\" }),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return Origin(scheme: scheme, host: host, port: parts.port ?? (scheme == "https" ? 443 : 80))
    }

    static func allowed(_ text: String) -> Origin? {
        guard !text.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || $0 == "\\" }),
              matches(text, "(?i)^https?://"), let parts = URLComponents(string: text),
              parts.percentEncodedPath == "" || parts.percentEncodedPath == "/",
              parts.query == nil, parts.fragment == nil, let url = parts.url else { return nil }
        return of(url)
    }
}

struct OwnedHeader: Sendable {
    let name: String
    let original: String?
    let added: String?
}

enum Propagation {
    static func permits(_ url: URL, allowed: Set<String>) -> Bool {
        guard let origin = Origin.of(url) else { return false }
        return allowed.contains { Origin.allowed($0) == origin }
    }

    static func stripOwned(_ request: URLRequest, owned: [OwnedHeader]) -> URLRequest {
        var result = request
        for field in owned where result.value(forHTTPHeaderField: field.name) == field.added {
            result.setValue(field.original, forHTTPHeaderField: field.name)
        }
        return result
    }

    static func inject(_ request: URLRequest, session: String, context: TraceContext) -> (URLRequest, [OwnedHeader]) {
        var result = request
        let inbound = TraceContext.parse(request.value(forHTTPHeaderField: "traceparent"))
        if inbound == nil { result.setValue(context.header, forHTTPHeaderField: "traceparent") }
        if inbound == nil || !validTracestate(request.value(forHTTPHeaderField: "tracestate")) {
            result.setValue(nil, forHTTPHeaderField: "tracestate")
        }
        let parts = (request.value(forHTTPHeaderField: "baggage") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !matches($0, "^(session\\.id|user\\.id)\\s*=") }
        let baggage = (parts + ["session.id=\(session)"]).joined(separator: ",")
        result.setValue(baggage.utf8.count <= 8192 ? baggage : nil, forHTTPHeaderField: "baggage")
        let owned = ["traceparent", "tracestate", "baggage"].map {
            OwnedHeader(name: $0, original: request.value(forHTTPHeaderField: $0), added: result.value(forHTTPHeaderField: $0))
        }
        return (result, owned)
    }

    private static func validTracestate(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= 512 else { return false }
        let members = value.split(separator: ",", omittingEmptySubsequences: false)
        guard members.count <= 32 else { return false }
        var seen = Set<String>()
        return members.allSatisfy { member in
            let pair = member.trimmingCharacters(in: .whitespaces).split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2 else { return false }
            let key = String(pair[0]), item = String(pair[1])
            return seen.insert(key).inserted &&
                matches(key, "^(?:[a-z][a-z0-9_*/-]{0,255}|[a-z0-9][a-z0-9_*/-]{0,240}@[a-z][a-z0-9_*/-]{0,13})$") &&
                matches(item, "^[\\x20-\\x2b\\x2d-\\x3c\\x3e-\\x7e]{0,255}[\\x21-\\x2b\\x2d-\\x3c\\x3e-\\x7e]$")
        }
    }
}
