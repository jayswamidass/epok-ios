import Foundation
import Network

public protocol Connectivity: Sendable {
    func isOnline() -> Bool
    func start(onChange: @escaping @Sendable () -> Void)
    func stop()
}

public final class ManualConnectivity: Connectivity {
    private struct State: Sendable {
        var online: Bool
        var listener: (@Sendable () -> Void)?
    }
    private let state: Locked<State>

    public init(initiallyOnline: Bool = true) { state = Locked(State(online: initiallyOnline)) }
    public func isOnline() -> Bool { state.withValue { $0.online } }
    public func start(onChange: @escaping @Sendable () -> Void) { state.withValue { $0.listener = onChange } }
    public func stop() { state.withValue { $0.listener = nil } }
    public func setOnline(_ online: Bool) {
        let callback = state.withValue { value in
            value.online = online
            return value.listener
        }
        callback?() // Never call user code while holding the lock.
    }
}

/// Owns NWPathMonitor only between start and stop. Unknown connectivity is offline.
public final class NetworkConnectivity: Connectivity, @unchecked Sendable {
    // All fields except the immutable queue/lock are guarded by lock.
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.epok.rum.connectivity")
    private var monitor: NWPathMonitor?
    private var online = false
    private var generation = 0
    private var listener: (@Sendable () -> Void)?

    public init() {}

    public func isOnline() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        generation += 1
        let token = generation
        let next = NWPathMonitor()
        listener = onChange
        monitor = next
        next.pathUpdateHandler = { [weak self] path in
            self?.update(online: path.status == .satisfied, generation: token)
        }
        next.start(queue: queue)
    }

    private func update(online: Bool, generation: Int) {
        lock.lock()
        guard self.generation == generation, monitor != nil else { lock.unlock(); return }
        self.online = online
        let callback = listener
        lock.unlock()
        callback?()
    }

    public func stop() {
        lock.lock()
        generation += 1
        let previous = monitor
        monitor = nil
        listener = nil
        online = false
        lock.unlock()
        previous?.cancel()
    }

    deinit { monitor?.cancel() }
}
