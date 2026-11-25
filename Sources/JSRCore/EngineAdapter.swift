import JavaScriptCore

// Adapter interface of the pinned js_runtime docs/ENGINE_ADAPTER.md.
// Operations: create (= init), eval, dispose, setMessageCallback, executePendingJobs.
// JavaScriptCore drains pending jobs by itself, so executePendingJobs is a no-op here.

/// One JS engine backend behind the adapter interface. The widget code does not
/// change when the backend changes (QuickJS, JavaScriptCore, Web Worker).
public protocol JsEngine: AnyObject {
    /// Evaluates `code` as global code under `sourceName`; throws with the
    /// exception text on a JS error. The engine keeps running.
    func eval(_ code: String, sourceName: String) throws
    /// Drains pending jobs until none is left. No-op on engines that drain by themselves.
    func executePendingJobs()
    /// Frees the engine. No callbacks fire after `dispose()`.
    func dispose()
    /// Installs the JS global `sendMessage(channel, payloadJson)`; every call
    /// forwards `(channel, payload)` to the host callback.
    func setMessageCallback(_ callback: @escaping (_ channel: String, _ payload: String) -> Void)
}

/// JavaScriptCore backend (iOS + macOS system framework).
public final class JsContextEngine: JsEngine {
    public enum EngineError: Error {
        case exception(String)
    }

    private let context: JSContext
    private var callback: ((_ channel: String, _ payload: String) -> Void)?

    public init() {
        context = JSContext()!
        let bridge: @convention(block) (String, String) -> Void = { [weak self] channel, payload in
            self?.callback?(channel, payload)
        }
        context.setObject(bridge, forKeyedSubscript: "sendMessage" as NSString)
    }

    public func eval(_ code: String, sourceName: String) throws {
        var caught: String?
        context.exceptionHandler = { _, exception in caught = exception?.toString() }
        _ = context.evaluateScript(code, withSourceURL: URL(string: sourceName))
        context.exceptionHandler = nil
        if let caught { throw EngineError.exception(caught) }
    }

    public func setMessageCallback(_ callback: @escaping (_ channel: String, _ payload: String) -> Void) {
        self.callback = callback
    }

    /// JavaScriptCore drains pending jobs after every `evaluateScript`.
    public func executePendingJobs() {}

    public func dispose() {
        callback = nil
    }
}
