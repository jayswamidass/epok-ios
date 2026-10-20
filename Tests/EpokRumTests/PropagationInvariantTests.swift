import Foundation
import XCTest
@testable import EpokRum

final class PropagationInvariantTests: XCTestCase {
    func testURLSessionDelegateRejectsAutomaticRedirects() throws {
        let session = URLSession(configuration: StubURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let source = URL(string: "https://allowed.invalid/start")!
        let redirected = URLRequest(url: URL(string: "https://lookalike.invalid/finish")!)
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil))
        let task = session.dataTask(with: source) // Never resumed; no network.
        let called = Locked(false)
        let result = Locked<URLRequest?>(redirected)
        RejectRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                    newRequest: redirected) { request in
            called.withValue { $0 = true }
            result.withValue { $0 = request }
        }
        XCTAssertTrue(called.withValue { $0 })
        XCTAssertNil(result.withValue { $0 }, "Automatic redirects must never bypass the explicit origin check")
    }

    func testExactSchemeHostPortAllowlistRejectsLookalikes() {
        let allowed: Set<String> = ["https://api.getepok.dev:443"]
        XCTAssertTrue(Propagation.permits(URL(string: "https://API.getepok.dev/users")!, allowed: allowed))
        for target in ["https://api.evil-getepok.dev/", "https://api.getepok.dev.evil.com/",
                       "https://sub.api.getepok.dev/", "http://api.getepok.dev/",
                       "https://api.getepok.dev:444/", "https://user:pass@api.getepok.dev/"] {
            XCTAssertFalse(Propagation.permits(URL(string: target)!, allowed: allowed), target)
        }
        let target = URL(string: "https://api.getepok.dev/path")!
        for entry in ["https://api.getepok.dev/path", "https://api.getepok.dev?x=1", "https://api.getepok.dev#x",
                      "https://user@api.getepok.dev", ".*getepok.dev", "https:\\api.getepok.dev"] {
            XCTAssertFalse(Propagation.permits(target, allowed: [entry]), entry)
        }
    }

    func testURLSessionAllowedAndLookalikeRequestsExposeActualHeaders() async throws {
        let h = try Harness(replies: [.init(), .init()])
        defer { h.cleanup() }
        await h.rum.grantConsent()
        let client = h.hostClient()
        defer { client.close() }
        _ = try await h.rum.data(for: h.request(), using: client)
        _ = try await h.rum.data(for: h.request(hostIndex: 2), using: client)
        XCTAssertEqual(h.stub.requests.count, 2)
        let allowed = try XCTUnwrap(h.stub.requests.first)
        let denied = try XCTUnwrap(h.stub.requests.last)
        XCTAssertNotNil(TraceContext.parse(allowed.header("traceparent")))
        let state = await h.rum.snapshot()
        XCTAssertEqual(allowed.header("baggage"), "session.id=\(try XCTUnwrap(state.sessionId))")
        XCTAssertNil(denied.header("traceparent"), "Lookalike origin must NOT receive SDK trace context")
        XCTAssertNil(denied.header("baggage"))
        XCTAssertEqual(state.pending, 2)
        assertConserved(state)
    }

    func testCrossOriginRedirectStripsSDKHeadersBeforeNextURLSessionRequest() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let redirectStub = HTTPStub([.init(status: 302, headers: ["Location": "https://\(h.hosts[2])/finish"]), .init()])
        for host in h.hosts { StubURLProtocol.registry.withValue { $0[host] = redirectStub } }
        await h.rum.grantConsent()
        let client = h.hostClient()
        defer { client.close() }
        var request = h.request(path: "/start")
        request.setValue("Bearer host-owned", forHTTPHeaderField: "Authorization")
        let (_, response) = try await h.rum.data(for: request, using: client)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(redirectStub.requests.count, 2)
        XCTAssertNotNil(redirectStub.requests.first?.header("traceparent"))
        XCTAssertNil(redirectStub.requests.last?.header("traceparent"))
        XCTAssertNil(redirectStub.requests.last?.header("baggage"))
        XCTAssertNil(redirectStub.requests.last?.header("Authorization"))
        XCTAssertEqual(redirectStub.requests.last?.url.host, h.hosts[2])
    }

    func testInboundContextOwnershipTracestateAndWithdrawal() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.rum.grantConsent()
        let inbound = "00-\(String(repeating: "1", count: 32))-\(String(repeating: "2", count: 16))-00"
        var request = h.request()
        request.setValue(inbound, forHTTPHeaderField: "traceparent")
        request.setValue("vendor=value", forHTTPHeaderField: "tracestate")
        request.setValue("other=ok,session.id=stale,user.id=private", forHTTPHeaderField: "baggage")
        let first = await h.rum.prepare(request)
        let second = await h.rum.prepare(first.request, owned: first.owned)
        XCTAssertEqual(second.request.value(forHTTPHeaderField: "traceparent"), inbound)
        XCTAssertEqual(second.request.value(forHTTPHeaderField: "tracestate"), "vendor=value")
        XCTAssertEqual(first.request.value(forHTTPHeaderField: "baggage"), second.request.value(forHTTPHeaderField: "baggage"))
        let sid = try XCTUnwrap(second.capture?.session)
        XCTAssertEqual(second.request.value(forHTTPHeaderField: "baggage"), "other=ok,session.id=\(sid)")
        var malformed = request
        malformed.setValue("00-\(String(repeating: "0", count: 32))-\(String(repeating: "2", count: 16))-01", forHTTPHeaderField: "traceparent")
        let repaired = await h.rum.prepare(malformed)
        XCTAssertNotNil(TraceContext.parse(repaired.request.value(forHTTPHeaderField: "traceparent")))
        XCTAssertNil(repaired.request.value(forHTTPHeaderField: "tracestate"))
        let generated = await h.rum.prepare(h.request())
        let generatedAgain = await h.rum.prepare(generated.request, owned: generated.owned)
        XCTAssertEqual(generatedAgain.request.value(forHTTPHeaderField: "traceparent"), generated.request.value(forHTTPHeaderField: "traceparent"))
        await h.rum.withdrawConsent()
        let denied = await h.rum.prepare(first.request, owned: first.owned)
        XCTAssertNil(denied.capture)
        XCTAssertEqual(denied.request.value(forHTTPHeaderField: "traceparent"), inbound, "Host-owned context stays host-owned")
        XCTAssertEqual(denied.request.value(forHTTPHeaderField: "baggage"), request.value(forHTTPHeaderField: "baggage"))
        let stripped = await h.rum.prepare(generated.request, owned: generated.owned)
        XCTAssertNil(stripped.request.value(forHTTPHeaderField: "traceparent"))
        XCTAssertNil(stripped.request.value(forHTTPHeaderField: "baggage"))
    }
}
