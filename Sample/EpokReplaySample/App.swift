import EpokRum
import EpokReplay
import UIKit

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {}

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ReplayViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

@MainActor
final class ReplayViewController: UIViewController {
    private var rum: Rum?
    private var replay: EpokReplay?
    private let state = UILabel()
    private let queued = UILabel()
    private let delivered = UILabel()
    private let demo = UILabel()
    private var count = 0
    private var timer: Timer?
    private var busy = false
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        state.accessibilityIdentifier = "state"
        queued.accessibilityIdentifier = "queuedBytes"
        delivered.accessibilityIdentifier = "delivered"
        demo.text = "Checkout: 0 items"
        demo.font = .preferredFont(forTextStyle: .title1)
        let input = UITextField()
        input.placeholder = "Masked sample input"
        input.borderStyle = .roundedRect
        input.accessibilityIdentifier = "sampleInput"
        let stack = UIStackView(arrangedSubviews: [demo, input, state, queued, delivered])
        stack.axis = .vertical
        stack.spacing = 16
        for (title, id, action) in [
            ("Grant consent", "grant", #selector(grant)),
            ("Add item + RUM metric", "update", #selector(update)),
            ("Replay offline", "offline", #selector(offline)),
            ("Replay online / flush", "flush", #selector(flush)),
            ("Withdraw consent", "withdraw", #selector(withdraw))
        ] {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.accessibilityIdentifier = id
            button.addTarget(self, action: action, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
        do {
            // Written ONLY into this disposable app container by mac-replay-capture.sh.
            let data = try Data(contentsOf: documents.appendingPathComponent("capture-config.json"))
            let config = try JSONDecoder().decode(CaptureConfig.self, from: data)
            let rumConfig = RumConfig(endpoint: config.origin, publicIngestKey: config.ingestKey,
                accountId: config.accountId, projectId: config.projectId, serviceName: "epok-ios-replay-sample")
            let sdk = try Rum(config: rumConfig,
                storageURL: documents.appendingPathComponent("rum-ledger.json"))
            rum = sdk
            replay = try EpokReplay(rum: sdk,
                host: URL(string: config.origin + "/v1/rum/mobile/ios")!, publicIngestKey: config.ingestKey)
            refresh("startup")
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } catch {
            state.text = "error: \(error.localizedDescription)"
        }
    }

    @objc private func grant() {
        guard !busy else { return }
        busy = true
        Task {
            _ = await replay?.grantConsent()
            busy = false
            refresh()
        }
    }

    @objc private func update() {
        count += 1
        demo.text = "Checkout: \(count) items"
        demo.backgroundColor = count.isMultiple(of: 2) ? .systemYellow : .systemGreen
        Task { await rum?.recordMetric(name: "sample.items", value: Double(count)) }
        refresh()
    }

    @objc private func offline() {
        replay?.setOffline(true)
        refresh("captured")
    }

    @objc private func flush() {
        replay?.setOffline(false)
        replay?.flush()
        refresh()
    }

    @objc private func withdraw() {
        // No await precedes the replay coordinator's synchronous revocation gate.
        Task {
            refresh("offline")
            await replay?.withdrawConsent()
            refresh("withdrawn")
        }
    }

    private func refresh(_ phase: String = "status") {
        guard let snapshot = replay?.snapshot() else { return }
        state.text = snapshot["captureActive"] as? Bool == true ? "recording" : (snapshot["consent"] as? String ?? "error")
        queued.text = String(snapshot["queuedBytes"] as? Int ?? -1)
        delivered.text = String(snapshot["delivered"] as? Int ?? -1)
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: documents.appendingPathComponent(phase + ".json"), options: .atomic)
        }
    }
}

private struct CaptureConfig: Decodable {
    let origin: String
    let ingestKey: String
    let accountId: String
    let projectId: String
}
