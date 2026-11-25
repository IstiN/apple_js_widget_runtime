import Foundation

// Timers on the host side of __jsr_set_interval / __jsr_clear_interval /
// __jsr_raf / __jsr_caf (PROTOCOL.md section 3). The scheduling point is the
// injectable `TimerDriving` driver: the main run loop on a real host, a manual
// driver in tests and the host conformance loop (driven by hand, no sleeping).
// Every tick evaluates the resolve global of the reference (`__jsrInterval`,
// `__jsrRaf`) on the engine after the current job.

public protocol TimerDriving: AnyObject {
    func schedule(id: String, delay: TimeInterval, _ fire: @escaping () -> Void)
    func cancel(id: String)
}

/// Real-host driver: main run loop (DispatchQueue.main).
public final class MainRunLoopTimerDriver: TimerDriving {
    public init() {}

    public func schedule(id: String, delay: TimeInterval, _ fire: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: fire)
    }

    public func cancel(id: String) {
        // Work scheduled with asyncAfter cannot be cancelled by id; Timers
        // checks liveness before evaluating a tick, so a cancelled id no-ops.
    }
}

/// Deterministic driver for tests and the host conformance loop.
/// `fireAll()` drains the pending snapshot once (FIFO); entries re-scheduled
/// by a tick stay pending for the next call, so repeating intervals stay finite.
public final class ManualTimerDriver: TimerDriving {
    private var pending: [String: () -> Void] = [:]
    private var order: [String] = []
    private let lock = NSLock()

    public init() {}

    public func schedule(id: String, delay: TimeInterval, _ fire: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if pending[id] == nil { order.append(id) }
        pending[id] = fire
    }

    public func cancel(id: String) {
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    public var pendingIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return order
    }

    /// Fires one pending timer by id (no-op for unknown ids).
    public func fire(id: String) {
        let entry: (() -> Void)? = {
            self.lock.lock(); defer { self.lock.unlock() }
            self.order.removeAll { $0 == id }
            return self.pending.removeValue(forKey: id)
        }()
        entry?()
    }

    /// Fires every pending timer once, FIFO.
    public func fireAll() {
        for id in pendingIds { fire(id: id) }
    }
}

public final class Timers {
    /// Wall clock in seconds; injected so tests can fix elapsed values.
    public var clock: () -> TimeInterval
    private let driver: TimerDriving
    /// Evaluates a tick script (e.g. `__jsrInterval("i1")`) on the engine.
    private let evaluate: (String) -> Void
    private let lock = NSLock()
    private var live: Set<String> = []

    public init(driver: TimerDriving, clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }, evaluate: @escaping (String) -> Void) {
        self.driver = driver
        self.clock = clock
        self.evaluate = evaluate
    }

    /// __jsr_set_interval: {"id","ms","once"}; ms defaults 0 when once, else 1000
    /// (defaults applied by the handler; Timers receives the effective delay).
    public func setInterval(id: String, delay: TimeInterval, once: Bool) {
        setLive(id)
        driver.schedule(id: id, delay: delay) { [weak self] in
            guard let self, self.isLive(id) else { return }
            if once {
                self.unsetLive(id)
            } else {
                self.setInterval(id: id, delay: delay, once: false) // re-arm before the tick
            }
            self.evaluate("__jsrInterval(\(JSON.stringify(id)))")
        }
    }

    /// __jsr_clear_interval and __jsr_caf: drop the timer; unknown ids ignored.
    public func cancel(id: String) {
        unsetLive(id)
        driver.cancel(id: id)
    }

    /// __jsr_raf: one frame tick per request, elapsed ms since the request;
    /// the callback is deleted after firing (PROTOCOL.md __jsr_raf).
    public func requestFrame(id: String) {
        let start = clock()
        setLive(id)
        driver.schedule(id: id, delay: 1.0 / 60.0) { [weak self] in
            guard let self, self.isLive(id) else { return }
            self.unsetLive(id)
            let elapsedMs = (self.clock() - start) * 1000.0
            self.evaluate("__jsrRaf(\(JSON.stringify(id)), \(Int(elapsedMs)))")
        }
    }

    private func setLive(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        live.insert(id)
    }

    private func unsetLive(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        live.remove(id)
    }

    private func isLive(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return live.contains(id)
    }
}
