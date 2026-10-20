import Foundation

public enum Privacy {
    public static let redacted = "<redacted>"
    private static let sensitive = "(?i)^(access[-_]?token|id[-_]?token|refresh[-_]?token|token|secret|password|passwd|reset([-_]password)?|auth|authorization|bearer|api[-_]?key|key|code|invite|verify|verification|session)$"

    /// Scrubs before serialization/disk. Any parser or decoding failure redacts the
    /// entire URL. Query values are kept only on explicit, exact key opt-in.
    public static func scrubURL(_ input: String, allowedQueryKeys: Set<String> = []) -> String {
        guard !input.isEmpty else { return "" }
        guard !input.unicodeScalars.contains(where: { $0.value <= 31 || $0.value == 127 || $0 == "\\" })
        else { return redacted }
        let hasFragment = input.contains("#")
        let base = String(input.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let parts = base.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var path = String(parts[0])
        var authority = ""
        if path.hasPrefix("//") || matches(path, "(?i)^[a-z][a-z0-9+.-]*:") {
            let relative = path.hasPrefix("//")
            let candidate = relative ? "https:" + path : path
            guard matches(candidate, "(?i)^https?://[^/]+"),
                  let components = URLComponents(string: candidate),
                  let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = components.host, !host.isEmpty,
                  !host.contains(where: { $0.isWhitespace }), components.url != nil,
                  components.port.map({ (1...65535).contains($0) }) ?? true
            else { return redacted }
            let hostText = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            let defaultPort = scheme == "https" ? 443 : 80
            let port = components.port.map { $0 == defaultPort ? "" : ":\($0)" } ?? ""
            authority = (relative ? "" : scheme + ":") + "//" + hostText.lowercased() + port
            // Use the original escaped path so malformed percent escapes are not repaired by Foundation.
            let afterScheme = candidate.dropFirst(scheme.count + 3)
            path = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
        }
        var secretNext = false
        var safe: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            var decoded = String(segment)
            for _ in 0..<4 where decoded.contains("%") {
                guard let next = decoded.removingPercentEncoding else { return redacted }
                decoded = next
            }
            let secret = secretNext
            secretNext = secret || matches(decoded, sensitive)
            let opaque = decoded.lowercased().hasPrefix("eyj") || decoded
                .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
                .contains { part in
                    let text = String(part)
                    return matches(text, "(?i)^[a-f0-9]{16,}$") || matches(text, "(?i)^[a-z0-9]{24,}$") ||
                        (matches(text, "(?i)^[a-z0-9]{16,}$") && matches(text, "[0-9]"))
                }
            if decoded.isEmpty { safe.append("") }
            else if !secret && [":id", ":uuid", ":hash"].contains(decoded) { safe.append(decoded) }
            else if secret || opaque || !matches(decoded, "(?i)^[a-z][a-z0-9_.-]{0,31}$") { safe.append(redacted) }
            else { safe.append(decoded) }
        }
        var kept: [String] = []
        var dropped = false
        if parts.count == 2 && !parts[1].isEmpty {
            for pair in parts[1].split(separator: "&", omittingEmptySubsequences: false) {
                let rawKey = String(pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                guard let key = rawKey.removingPercentEncoding else { return redacted }
                if allowedQueryKeys.contains(key) {
                    // Even explicitly allowed values must not bypass malformed-escape handling.
                    guard String(pair).removingPercentEncoding != nil else { return redacted }
                    kept.append(String(pair))
                } else { dropped = true }
            }
        }
        if dropped { kept.append(redacted) }
        return authority + safe.joined(separator: "/") + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&")) +
            (hasFragment ? "#" + redacted : "")
    }
}
