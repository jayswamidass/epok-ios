import EpokRum
import Foundation
import PostHog

/// Additive replay coordinator using EpokRum's runtime-only Consent model.
/// Construct on app launch; only grantConsent constructs PostHog or a transport.
@MainActor
public final class EpokReplay {
    public private(set) var consent: Consent = .denied
    private let rum: Rum
    private let host: URL
    private let key: String
    private var sdk: PostHogSDK?
    private var upload: ReplayUpload?
    private var epoch: UInt64 = 0
    private var granting = false
    private var lastUpload: [String: Int] = ["queuedBytes": 0, "delivered": 0, "dropped": 0]

    public init(rum: Rum, host: URL, publicIngestKey: String) throws {
        guard ["https", "http"].contains(host.scheme ?? ""), host.host != nil,
              host.user == nil, host.password == nil, host.query == nil, host.fragment == nil,
              host.path == "/v1/rum/mobile/ios", !publicIngestKey.isEmpty,
              publicIngestKey == publicIngestKey.trimmingCharacters(in: .whitespacesAndNewlines),
              host.scheme == "https" || ["127.0.0.1", "localhost", "::1"].contains(host.host ?? "") else {
            throw URLError(.badURL)
        }
        self.rum = rum
        self.host = host
        key = publicIngestKey
    }

    @discardableResult
    public func grantConsent() async -> Bool {
        if consent == .granted { return true }
        guard !granting else { return false }
        granting = true
        defer { granting = false }
        let token = epoch
        guard await rum.grantConsent() else { return false }
        guard epoch == token else { return false }
        consent = .granted
        let sink = ReplayUpload(endpoint: host.appendingPathComponent("s/"))
        upload = sink
        let config = PostHogConfig(projectToken: key, host: host.absoluteString)
        config.sessionReplay = true
        config.sessionReplayConfig.screenshotMode = false
        config.sessionReplayConfig.maskAllTextInputs = true
        config.sessionReplayConfig.maskAllImages = true
        config.sessionReplayConfig.maskAllSandboxedViews = true
        config.sessionReplayConfig.captureNetworkTelemetry = false
        config.sessionReplayConfig.captureLogs = false
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.captureElementInteractions = false
        config.captureSwiftUIElementInteractions = false
        config.capturePushNotificationOpened = false
        config.capturePushNotificationSubscriptions = false
        config.errorTrackingConfig.autoCapture = false
        config.errorTrackingConfig.exceptionSteps.enabled = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.surveys = false
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        let controlPlane = URLSessionConfiguration.ephemeral
        controlPlane.urlCache = nil
        controlPlane.protocolClasses = [LocalReplayConfig.self]
        config.urlSessionConfiguration = controlPlane
        let ingestKey = key
        config.setBeforeSend { [weak sink] event in
            if event.event == "$snapshot", event.properties["$snapshot_source"] as? String == "mobile" {
                sink?.admit {
                    let date = ISO8601DateFormatter()
                    date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return ["api_key": ingestKey, "event": event.event,
                            "distinct_id": event.distinctId, "uuid": event.uuid.uuidString.lowercased(),
                            "timestamp": date.string(from: event.timestamp), "properties": event.properties]
                }
            }
            // Returning nil is essential: never persist replay in PostHog's queue.
            // Its optOut does not purge and stop/close can trigger a flush.
            return nil
        }
        sdk = PostHogSDK.with(config)
        // optOut persists across SDK instances. Only this fresh Epok consent
        // grant may override it; never let a stored SDK preference grant consent.
        sdk?.optIn()
        return true // Config/capture activation is async; expose actual state below.
    }

    public func withdrawConsent() async {
        epoch &+= 1
        consent = .denied
        upload?.revoke()
        lastUpload = upload?.snapshot() ?? lastUpload
        upload = nil
        sdk?.stopSessionRecording()
        sdk?.optOut()
        sdk?.close()
        sdk = nil
        await rum.withdrawConsent()
    }

    public func flush() { upload?.flush() }
    public func setOffline(_ value: Bool) { upload?.setOffline(value) }

    public func snapshot() -> [String: Any] {
        var result: [String: Any] = (upload?.snapshot() ?? lastUpload).mapValues { $0 as Any }
        result["consent"] = consent.rawValue
        result["sdkConstructed"] = sdk != nil
        result["captureActive"] = sdk?.isSessionReplayActive() ?? false
        return result
    }
}
