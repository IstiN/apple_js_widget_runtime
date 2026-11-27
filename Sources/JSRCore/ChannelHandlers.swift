import Foundation

// One handler class per channel of the pinned js_runtime docs/PROTOCOL.md
// (v0.1, 21 channels), registered in a map — no channel `if` chain. Handler
// semantics mirror the harness host emulation (js_widget_runtime harness/host.mjs).

/// Records the fire-and-forget lanes (trace, renders, title, console, state).
public final class HostRecorder {
    public private(set) var trace: [String] = []
    public private(set) var renders: [String] = []
    public private(set) var title: String?
    public private(set) var consoleLines: [String] = []
    public private(set) var state: Any?

    public init() {}

    func recordVerb(_ channel: String) {
        trace.append(channel.hasPrefix("__jsr_") ? String(channel.dropFirst("__jsr_".count)) : channel)
    }

    func log(_ line: String) { consoleLines.append(line) }
    func render(_ payload: String) { renders.append(payload) }
    func setTitle(_ title: String) { self.title = title }
    func exportState(_ value: Any?) { state = value }
}

/// Everything a handler needs; `resolve` schedules the `__jsrResolve(id, value)`
/// evaluation after the current job (promise channels, PROTOCOL.md section 2).
public struct ChannelContext {
    public let channel: String
    public let rawPayload: String
    public let recorder: HostRecorder
    public let services: HostServices
    public let timers: Timers
    public let configuration: JSRConfiguration
    public let resolve: (_ id: String, _ valueJSON: String) -> Void
}

public protocol ChannelHandler: AnyObject {
    func handle(_ context: ChannelContext)
}

public final class ChannelRegistry {
    public let recorder = HostRecorder()
    private var handlers: [String: ChannelHandler] = [:]
    /// Promise resolutions queued "after the current job"; drained by the host loop.
    /// Producers run on ANY thread (URLSession completions on the session's
    /// delegate queue, MockHttp/timers on the caller's thread), so append and
    /// drain take one lock — the single rule for every channel resolution
    /// (review 2026-11-26, finding 4).
    private var resolutions: [(String, String)] = []
    private let resolutionsLock = NSLock()
    private let services: HostServices
    private let timers: Timers
    private let configuration: JSRConfiguration
    private let evaluate: (String) -> Void

    public init(services: HostServices, timers: Timers, configuration: JSRConfiguration, evaluate: @escaping (String) -> Void) {
        self.services = services
        self.timers = timers
        self.configuration = configuration
        self.evaluate = evaluate
        registerDefaults()
    }

    public func handler(for channel: String) -> ChannelHandler? {
        handlers[channel]
    }

    public func register(channel: String, handler: ChannelHandler) {
        handlers[channel] = handler
    }

    /// Entry point of the engine's `sendMessage` global: trace, then dispatch.
    public func dispatch(channel: String, payload: String) {
        recorder.recordVerb(channel)
        guard let handler = handlers[channel] else { return } // unknown lanes are dropped
        handler.handle(ChannelContext(
            channel: channel, rawPayload: payload, recorder: recorder,
            services: services, timers: timers, configuration: configuration,
            resolve: resolveClosure))
    }

    /// Drains queued promise resolutions FIFO until the queue is empty
    /// (bounded): each resolution evaluates `__jsrResolve(id, value)` on the
    /// engine after the current job; JSC settles the promise chain inside.
    public func drain() {
        var rounds = 0
        while rounds < 100 {
            let batch: [(String, String)]
            resolutionsLock.lock()
            if resolutions.isEmpty {
                resolutionsLock.unlock()
                break
            }
            batch = resolutions
            resolutions.removeAll()
            resolutionsLock.unlock()
            for (id, value) in batch {
                evaluate("__jsrResolve(\(JSON.stringify(id)), \(value))")
            }
            rounds += 1
        }
    }

    // MARK: - wiring

    private lazy var resolveClosure: (String, String) -> Void = { [weak self] id, value in
        guard let self else { return }
        self.resolutionsLock.lock()
        self.resolutions.append((id, value))
        self.resolutionsLock.unlock()
    }

    private func registerDefaults() {
        let handlers: [String: ChannelHandler] = [
            "__jsr_log": LogHandler(),
            "__jsr_render": RenderHandler(),
            "__jsr_set_title": SetTitleHandler(),
            "__jsr_set_interval": SetIntervalHandler(),
            "__jsr_clear_interval": ClearIntervalHandler(),
            "__jsr_raf": RafHandler(),
            "__jsr_caf": CafHandler(),
            "__jsr_fetch": FetchHandler(),
            "__jsr_exec": ExecHandler(),
            "__jsr_open_url": OpenUrlHandler(),
            "__jsr_host_call": HostCallHandler(),
            "__jsr_host_call_binary": HostCallBinaryHandler(),
            "__jsr_capture": CaptureHandler(),
            "__jsr_storage_get": StorageGetHandler(),
            "__jsr_storage_set": StorageSetHandler(),
            "__jsr_secrets_get": SecretsGetHandler(),
            "__jsr_secrets_set": SecretsSetHandler(),
            "__jsr_load_asset": LoadAssetHandler(),
            "__jsr_export_state": ExportStateHandler(),
            "__jsr_scene3d_command": Scene3dCommandHandler(),
            "__jsr_event_done": EventDoneHandler(),
        ]
        for (channel, handler) in handlers { register(channel: channel, handler: handler) }
    }
}

// MARK: - core channels

/// __jsr_log: raw string (joined console arguments); console.warn/error prefix.
public final class LogHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        context.recorder.log(JSON.unwrapRaw(context.rawPayload))
    }
}

/// __jsr_render: JSON string of the full UI tree; host applies through onRender.
public final class RenderHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        context.recorder.render(context.rawPayload)
    }
}

/// __jsr_set_title: raw string from jsr.setTitle(t).
public final class SetTitleHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        context.recorder.setTitle(JSON.unwrapRaw(context.rawPayload))
    }
}

/// __jsr_set_interval: {"id","ms","once"}; ms defaults 0 when once, else 1000.
public final class SetIntervalHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        guard let payload = JSON.parseTagged(context.rawPayload),
              let id = payload["id"] as? String else { return }
        let once = payload["once"] as? Bool ?? false
        let ms: Double
        if let requested = payload["ms"] as? Double, requested >= 0 {
            ms = requested
        } else if let requested = payload["ms"] as? NSNumber, requested.doubleValue >= 0 {
            ms = requested.doubleValue
        } else {
            ms = once ? 0 : 1000
        }
        context.timers.setInterval(id: id, delay: ms / 1000.0, once: once)
    }
}

/// __jsr_clear_interval: raw timer id; unknown ids ignored.
public final class ClearIntervalHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        context.timers.cancel(id: JSON.unwrapRaw(context.rawPayload))
    }
}

/// __jsr_raf: {"id"} (iid kept through dispatch per PROTOCOL.md); one frame tick.
public final class RafHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        guard let payload = JSON.parseTagged(context.rawPayload),
              let id = payload["id"] as? String else { return }
        context.timers.requestFrame(id: id)
    }
}

/// __jsr_caf: raw frame id; drops the pending frame.
public final class CafHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        context.timers.cancel(id: JSON.unwrapRaw(context.rawPayload))
    }
}

/// __jsr_fetch: {"id","url","method","headers"}; promise via __cbs[id].
public final class FetchHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        guard let payload = JSON.parseTagged(context.rawPayload),
              let id = payload["id"] as? String else { return }
        let method = (payload["method"] as? String ?? "GET").uppercased()
        let headers = payload["headers"] as? [String: Any] ?? [:]
        let request = FetchRequest(url: payload["url"] as? String ?? "", method: method, headers: headers)
        context.services.http.fetch(request) { value in
            context.resolve(id, JSON.stringify(value))
        }
    }
}

/// __jsr_exec: {"id","cmd"}; refused by capability unless allowedExec.
public final class ExecHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        guard let payload = JSON.parseTagged(context.rawPayload),
              let id = payload["id"] as? String else { return }
        guard context.configuration.allowsExec else {
            context.resolve(id, JSON.stringify(["__error": "exec is not permitted by this host"]))
            return
        }
        context.services.processRunner.run(payload["cmd"] as? String ?? "") { value in
            context.resolve(id, JSON.stringify(value))
        }
    }
}

/// __jsr_open_url (extended): {"id","url"}; resolves true when accepted.
public final class OpenUrlHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        guard let payload = JSON.parseTagged(context.rawPayload),
              let id = payload["id"] as? String else { return }
        let url = payload["url"] as? String ?? ""
        if url.isEmpty {
            context.resolve(id, JSON.stringify(["__error": "openUrl: empty url"]))
            return
        }
        context.services.openUrl.open(url) { value in
            context.resolve(id, JSON.stringify(value))
        }
    }
}

/// __jsr_host_call: {"id","name","args"}; resolves with the host handler result.
public final class HostCallHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        guard let payload = JSON.parseTagged(context.rawPayload),
              let id = payload["id"] as? String else { return }
        context.services.hostCall.call(
            name: payload["name"] as? String ?? "",
            args: payload["args"] as? [String: Any] ?? [:]
        ) { value in
            context.resolve(id, JSON.stringify(value))
        }
    }
}

/// __jsr_host_call_binary (extended): raw "<name> <base64>", fire-and-forget
/// and lossy; malformed payloads are dropped silently (PROTOCOL.md).
public final class HostCallBinaryHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {}
}

/// __jsr_capture (extended): {"id","opts"}; resolves when the capture completes.
public final class CaptureHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        guard let payload = JSON.parseTagged(context.rawPayload),
              let id = payload["id"] as? String else { return }
        context.resolve(id, JSON.stringify(["__error": "capture is not supported by this host"]))
    }
}

/// __jsr_storage_get: {"id","key"}; resolves the stored value or null.
public final class StorageGetHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        guard let payload = JSON.parseTagged(context.rawPayload),
              let id = payload["id"] as? String, let key = payload["key"] as? String else { return }
        if let value = context.services.storage.get(key) {
            context.resolve(id, JSON.stringify(value))
        } else {
            context.resolve(id, "null")
        }
    }
}

/// __jsr_storage_set: {"key","value"}; no id, no response (fire-and-forget).
public final class StorageSetHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        guard let payload = JSON.parseTagged(context.rawPayload),
              let key = payload["key"] as? String else { return }
        context.services.storage.set(key, payload["value"])
    }
}

/// __jsr_secrets_get: {"id","key"}; resolves the secret value or null.
public final class SecretsGetHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        guard let payload = JSON.parseTagged(context.rawPayload),
              let id = payload["id"] as? String, let key = payload["key"] as? String else { return }
        if let value = context.services.secrets.get(key) {
            context.resolve(id, JSON.stringify(value))
        } else {
            context.resolve(id, "null")
        }
    }
}

/// __jsr_secrets_set: {"id","key","value"} (null deletes); resolves ok boolean.
public final class SecretsSetHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        guard let payload = JSON.parseTagged(context.rawPayload),
              let id = payload["id"] as? String, let key = payload["key"] as? String else { return }
        let ok = context.services.secrets.set(key, payload["value"])
        context.resolve(id, JSON.stringify(ok))
    }
}

/// __jsr_load_asset: {"id","path"}; never rejects, nil resolves null.
public final class LoadAssetHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        guard let payload = JSON.parseTagged(context.rawPayload),
              let id = payload["id"] as? String else { return }
        if let value = context.services.assets.load(payload["path"] as? String ?? "") {
            context.resolve(id, JSON.stringify(value))
        } else {
            context.resolve(id, "null")
        }
    }
}

/// __jsr_export_state: the widget's structured state; host stores the snapshot.
public final class ExportStateHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {
        context.recorder.exportState(JSON.parseTagged(context.rawPayload))
    }
}

// MARK: - extended / worker-only channels (fire-and-forget lanes, dropped)

/// __jsr_scene3d_command (extended): no 3D host in the core; dropped with a log line.
public final class Scene3dCommandHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {}
}

/// __jsr_event_done: Web Worker engines only; VM engines never send it.
public final class EventDoneHandler: ChannelHandler {
    public init() {}
    public func handle(_ context: ChannelContext) {}
}
