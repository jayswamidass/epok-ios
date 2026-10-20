import Foundation
import XCTest
@testable import EpokRum

final class PrivacyInvariantTests: XCTestCase {
    func testAndroidPrivacyCorpusAndMalformedInputsFailClosed() {
        let cases = [
            "https://user:password@app.example/api/v2/users/42/profile?q=secret#private": "https://app.example/api/v2/users/<redacted>/profile?<redacted>#<redacted>",
            "/api/token/V2/GraphQL/:id": "/api/token/<redacted>/<redacted>/<redacted>",
            "/reset-password/short": "/reset-password/<redacted>",
            "/api/%25761/users/%2534%2532": "/api/v1/users/<redacted>",
            "/u/:id/:uuid/:hash": "/u/:id/:uuid/:hash",
            "/health-check/GraphQL/v2": "/health-check/GraphQL/v2",
            "//user:password@app.example:8080/cart": "//app.example:8080/cart",
            "https://app.example/#/route?secret=x": "https://app.example/#<redacted>",
            "https://[invalid": "<redacted>",
            "http:///": "<redacted>",
            "javascript:secret": "<redacted>",
            "https://app.example/hello\\secret": "<redacted>",
            "/bad/%ZZ": "<redacted>",
            "https://app.example/bad/%ZZ": "<redacted>",
            "https://app.example/\nprivate": "<redacted>"
        ]
        for (input, expected) in cases { XCTAssertEqual(Privacy.scrubURL(input), expected, input) }
        for secret in ["999", "alice%2540example.com", "eyJhbGciOi.payload.sig", "abcdef0123456789",
                       "a1b2c3d4e5f6g7h8", String(repeating: "a", count: 33), "part%2Fprivate"] {
            XCTAssertEqual(Privacy.scrubURL("/files/\(secret)"), "/files/<redacted>")
        }
        XCTAssertEqual(Privacy.scrubURL("/search?q=secret&page=2", allowedQueryKeys: ["page"]), "/search?page=2&<redacted>")
        XCTAssertEqual(Privacy.scrubURL("/search?%ZZ=secret", allowedQueryKeys: ["%ZZ"]), "<redacted>")
        XCTAssertEqual(Privacy.scrubURL("/files/a+b"), "/files/<redacted>", "Plus must not become form whitespace")
        XCTAssertFalse(matches("metric\n", "^[a-z]+$"), "Anchored validators must consume a final newline")
        let once = Privacy.scrubURL("https://app.example/users/42")
        XCTAssertEqual(Privacy.scrubURL(once), once)
    }

    func testDiskAndWireContainScrubbedOTLPTracesAndMetricsWithAuth() async throws {
        let h = try Harness(replies: [.init(status: 202), .init(status: 200)])
        defer { h.cleanup() }
        await h.rum.grantConsent()
        await h.rum.recordHTTP(url: "https://user:password@app.example/users/42?token=top-secret#fragment")
        await h.rum.recordMetric(name: "sample.trigger", value: 2)
        let disk = try String(contentsOf: h.file, encoding: .utf8)
        for secret in ["password", "top-secret", "fragment", h.config.publicIngestKey] { XCTAssertFalse(disk.contains(secret)) }
        h.network.setOnline(true)
        await h.rum.flush()
        let requests = h.stub.requests
        XCTAssertEqual(requests.map(\.url.path), ["/prefix/v1/traces", "/prefix/v1/metrics"])
        for request in requests {
            XCTAssertEqual(request.header("X-API-Key"), h.config.publicIngestKey)
            XCTAssertEqual(request.header("AccountID"), "account")
            XCTAssertEqual(request.header("ProjectID"), "project")
            XCTAssertEqual(request.header("Content-Type"), "application/json")
            XCTAssertNil(request.header("traceparent"), "Exporter must not instrument itself")
        }
        let traces = try XCTUnwrap(requests.first)
        let raw = String(decoding: traces.body, as: UTF8.self)
        for secret in ["password", "top-secret", "fragment"] { XCTAssertFalse(raw.contains(secret)) }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: traces.body) as? [String: Any])
        let resources = try XCTUnwrap(root["resourceSpans"] as? [[String: Any]])
        let scopes = try XCTUnwrap(resources.first?["scopeSpans"] as? [[String: Any]])
        let spans = try XCTUnwrap(scopes.first?["spans"] as? [[String: Any]])
        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual(span["name"] as? String, "GET https://app.example/users/<redacted>?<redacted>#<redacted>")
        XCTAssertEqual(span["kind"] as? Int, 3)
        XCTAssertTrue(matches(try XCTUnwrap(span["traceId"] as? String), "^[0-9a-f]{32}$"))
        XCTAssertTrue(matches(try XCTUnwrap(span["spanId"] as? String), "^[0-9a-f]{16}$"))
        XCTAssertEqual(span["startTimeUnixNano"] as? String, "1700000000000000000")
        let attrs = try XCTUnwrap(span["attributes"] as? [[String: Any]])
        let status = try XCTUnwrap(attrs.first { $0["key"] as? String == "http.status_code" }?["value"] as? [String: Any])
        XCTAssertEqual(status["intValue"] as? String, "200", "OTLP int64 fields must be JSON strings")
        let metrics = try XCTUnwrap(requests.last)
        let metricRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: metrics.body) as? [String: Any])
        let metricResources = try XCTUnwrap(metricRoot["resourceMetrics"] as? [[String: Any]])
        let metricScopes = try XCTUnwrap(metricResources.first?["scopeMetrics"] as? [[String: Any]])
        let values = try XCTUnwrap(metricScopes.first?["metrics"] as? [[String: Any]])
        let gauge = try XCTUnwrap(values.first?["gauge"] as? [String: Any])
        let points = try XCTUnwrap(gauge["dataPoints"] as? [[String: Any]])
        XCTAssertEqual(points.first?["asDouble"] as? Double, 2)
        let state = await h.rum.snapshot()
        XCTAssertEqual(state.counters.acked, 2)
        assertConserved(state)
    }

    func testInvalidObservationIsCountedAsDropWithoutWritingSensitiveName() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.rum.grantConsent()
        await h.rum.recordMetric(name: "sample", value: .nan)
        await h.rum.recordMetric(name: "https://private/secret", value: 1)
        await h.rum.recordHTTP(url: "https://[invalid?secret=never-raw")
        let state = await h.rum.snapshot()
        XCTAssertEqual(state.counters.enqueued, 3)
        XCTAssertEqual(state.counters.dropped_error, 2)
        XCTAssertEqual(state.pending, 1)
        let disk = try String(contentsOf: h.file, encoding: .utf8)
        XCTAssertFalse(disk.contains("never-raw"))
        XCTAssertFalse(disk.contains("https://private/secret"))
        XCTAssertTrue(disk.contains("<redacted>"))
        assertConserved(state)
    }
}
