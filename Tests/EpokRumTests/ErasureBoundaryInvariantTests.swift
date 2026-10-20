import XCTest
@testable import EpokRum

final class ErasureBoundaryInvariantTests: XCTestCase {
    func testErasureHasNoCredentialInputAlwaysDeniesAndHasNoNetworkEffect() async throws {
        let h = try Harness(replies: [.init()])
        defer { h.cleanup() }
        await h.rum.grantConsent() // A configured public ingest key grants no deletion authority.
        await h.rum.recordMetric(name: "sample", value: 1)
        let before = await h.rum.snapshot()
        // Compile-time signature assertion: there is no credential/session/transport parameter.
        let request: @Sendable () -> SessionErasure.Result = SessionErasure.request
        for _ in 0..<3 {
            XCTAssertEqual(request(), .deniedRequiresSessionScopedAuthorization, "Erasure must never report success")
        }
        let after = await h.rum.snapshot()
        XCTAssertEqual(after.counters, before.counters)
        XCTAssertEqual(after.batchIds, before.batchIds, "Erasure stub must not clear even the local queue")
        XCTAssertTrue(h.stub.requests.isEmpty, "Stub cannot send DELETE or any other request")
        assertConserved(after)
    }
}
