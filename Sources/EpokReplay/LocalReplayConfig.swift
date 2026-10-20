import Foundation

/// PostHog 3.92.0 always fetches remote config, even when remoteConfig=false.
/// Answer its control-plane request locally; NO PostHog network request escapes.
/// This is a pinned compatibility seam, not another Epok endpoint. Server-side
/// replay_enabled, ingest auth and quota policy still gate every actual upload.
final class LocalReplayConfig: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, request.httpMethod == "GET",
              url.path.contains("/array/"), url.path.hasSuffix("/config") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let body = Data(#"{"sessionRecording":{"endpoint":"/s/"},"hasFeatureFlags":false,"surveys":false}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
