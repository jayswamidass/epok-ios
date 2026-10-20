import Foundation

struct Outcome: Sendable {
    let status: Int
    var retryAfter: String? = nil
}

protocol Transport: Sendable {
    func send(_ batch: Batch) async -> Outcome
    func cancel()
}

/// All clients disable automatic redirects. Export redirects are terminal; host
/// redirects are followed explicitly by Rum.data so every hop is checked again.
final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class RumHTTPClient: Sendable {
    private let session: URLSession

    public convenience init() { self.init(configuration: .ephemeral) }

    // Test seam is internal so clients cannot accidentally install an auto-following session.
    init(configuration: URLSessionConfiguration) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.httpCookieStorage = nil
        copy.httpShouldSetCookies = false
        copy.urlCredentialStorage = nil
        session = URLSession(configuration: copy, delegate: RejectRedirects(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    public func close() { session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }
}

final class HTTPTransport: Transport {
    private let config: RumConfig
    private let endpoint: URL
    private let client: RumHTTPClient

    init(config: RumConfig, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard let components = URLComponents(string: config.endpoint),
              let url = components.url, Origin.of(url) != nil,
              components.query == nil, components.fragment == nil else { throw RumError.invalidConfiguration }
        self.config = config
        endpoint = url
        configuration.timeoutIntervalForRequest = Double(config.requestTimeoutMs) / 1_000
        configuration.timeoutIntervalForResource = Double(config.requestTimeoutMs) / 1_000
        client = RumHTTPClient(configuration: configuration)
    }

    func send(_ batch: Batch) async -> Outcome {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1").appendingPathComponent(batch.signal.rawValue))
        request.httpMethod = "POST"
        request.httpBody = Data(batch.body.utf8)
        request.timeoutInterval = Double(config.requestTimeoutMs) / 1_000
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.accountId, forHTTPHeaderField: "AccountID")
        request.setValue(config.projectId, forHTTPHeaderField: "ProjectID")
        request.setValue(config.publicIngestKey, forHTTPHeaderField: "X-API-Key")
        do {
            let (_, response) = try await client.send(request)
            return Outcome(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        } catch { return Outcome(status: 0) }
    }

    func cancel() { client.close() }
}

func retryDelay(config: RumConfig, outcome: Outcome, attempts: Int, now: Int64, random: Double) -> Int64 {
    let backoff = min(Double(config.maxRetryDelayMs), Double(config.retryBaseMs) * pow(2, Double(attempts - 1)))
    let jitter = random.isFinite ? min(1, max(0, random)) : 1
    let jittered = Int64(backoff * (0.5 + 0.5 * jitter))
    var retryAfter: Int64 = 0
    if let text = outcome.retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines) {
        if matches(text, "^[0-9]+(\\.[0-9]+)?$"), let seconds = Double(text), seconds.isFinite {
            retryAfter = Int64(min(Double(Int64.max / 4), seconds * 1_000))
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: text) {
                let delta = max(0, date.timeIntervalSince1970 * 1_000 - Double(now))
                retryAfter = Int64(min(Double(Int64.max / 4), delta))
            }
        }
    }
    // Never shorten Retry-After to the local backoff cap. Age expiry still applies.
    return max(jittered, retryAfter)
}
