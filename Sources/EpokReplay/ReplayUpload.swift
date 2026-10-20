import Foundation

/// Transport only: all view traversal, masking and touch capture belong to PostHog.
/// One grant owns one instance; revoked instances can never be reopened.
/// The lock protects admission, queue, task creation and revocation together.
final class ReplayUpload: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let endpoint: URL
    private let maxBytes: Int
    private var session: URLSession?
    private var timer: DispatchSourceTimer?
    private var task: URLSessionDataTask?
    private var pending: [Data] = []
    private var attempts = 0
    private var revoked = false
    private var offline = false
    private var delivered = 0
    private var dropped = 0

    init(endpoint: URL, maxBytes: Int = 4 * 1024 * 1024,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.endpoint = endpoint
        self.maxBytes = maxBytes
        super.init()
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.flush() }
        self.timer = timer
        timer.resume()
    }

    /// Serialization is inside the same lock as withdrawal. No late callback can
    /// recreate queued bytes. No PostHogEvent object escapes its synchronous hook.
    func admit(_ envelope: () -> [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked else { return }
        guard let bytes = try? JSONSerialization.data(withJSONObject: [envelope()]),
              pending.reduce(0, { $0 + $1.count }) + bytes.count <= maxBytes else {
            dropped += 1
            return
        }
        pending.append(bytes)
        sendLocked()
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        sendLocked()
    }

    func setOffline(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        offline = value
        // An existing request may finish. This test gate blocks subsequent sends.
        if !offline { sendLocked() }
    }

    private func sendLocked() {
        guard !revoked, !offline, task == nil, let bytes = pending.first, let session else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = bytes
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        attempts += 1
        let next = session.dataTask(with: request) { [weak self] _, response, error in
            self?.completed(status: (response as? HTTPURLResponse)?.statusCode, failed: error != nil)
        }
        task = next
        next.resume()
    }

    private func completed(status: Int?, failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked else { return }
        task = nil
        let success = !failed && (200...299).contains(status ?? 0)
        let retry = failed || status == nil || status == 429 || (500...599).contains(status ?? 0)
        if success || !retry || attempts >= 3 {
            if !pending.isEmpty { pending.removeFirst() }
            if success { delivered += 1 } else { dropped += 1 }
            attempts = 0
        }
        // Timer retries at most once per second; no tight retry loop.
    }

    func revoke() {
        lock.lock()
        defer { lock.unlock() }
        revoked = true // BEFORE cancellation, SDK stop/close, or queue removal.
        timer?.cancel()
        timer = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        pending.removeAll(keepingCapacity: false)
    }

    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return ["queuedBytes": pending.reduce(0, { $0 + $1.count }),
                "delivered": delivered, "dropped": dropped]
    }

    // Never forward a batch (which contains the ingest key) through a redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
