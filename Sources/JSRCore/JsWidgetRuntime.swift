import JavaScriptCore

// Mirror of android_js_widget_runtime JsWidgetRuntime / flutter QuickjsWidgetEngineBackend.
// Contract: JS -> host via global sendMessage(channel, payloadJson);
// host -> JS via jsr._handler(actionId, payload) (callEvent).
public final class JsWidgetRuntime {
    public enum EngineError: Error {
        case exception(String)
    }

    public struct Configuration {
        /// Runtime bootstrap (console/timers/rAF/fetch…) — from js_runtime#3.
        public var runtimeBootstrap: String
        /// Widget bootstrap (jsr.render/onEvent/theme…) — contract half.
        public var widgetBootstrap: String
        public init(runtimeBootstrap: String, widgetBootstrap: String) {
            self.runtimeBootstrap = runtimeBootstrap
            self.widgetBootstrap = widgetBootstrap
        }
    }

    public typealias MessageSink = (_ channel: String, _ payload: String) -> Void

    private let context: JSContext
    private let config: Configuration
    private var sink: MessageSink?

    public init(configuration: Configuration) {
        self.config = configuration
        self.context = JSContext()!
        installSendMessageBridge()
    }

    private func installSendMessageBridge() {
        let bridge: @convention(block) (String, String) -> Void = { [weak self] channel, payload in
            self?.sink?(channel, payload)
        }
        context.setObject(bridge, forKeyedSubscript: "sendMessage" as NSString)
    }

    public func start(sink: @escaping MessageSink) {
        self.sink = sink
        eval(config.runtimeBootstrap + "\n" + config.widgetBootstrap)
    }

    /// Evaluates JS; throws EngineError.exception on JS error.
    @discardableResult
    public func eval(_ code: String, source: String = "<widget>") throws -> JSValue? {
        var caught: String?
        context.exceptionHandler = { caught = $0?.toString() }
        let value = context.evaluateScript(code, withSourceURL: nil)
        context.exceptionHandler = nil
        if let caught { throw EngineError.exception(caught) }
        return value
    }

    /// Delivers an event into the widget: jsr._handler(actionId, payloadJson).
    /// Contract-identical to the Flutter/Android dispatch snippet.
    public func callEvent(_ actionId: String, payloadJson: String = "{}") throws {
        let escapedAction = actionId.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        (function(){
          var __h = jsr._handler || (typeof handleEvent === "function" ? handleEvent : null);
          if (!__h) { return; }
          try {
            var __r = __h("\(escapedAction)", \(payloadJson));
            if (__r && typeof __r.then === "function") { __r.then(function(){}, function(e){}); }
          } catch (e) {}
        })();
        """
        try eval(script, source: "<event>")
    }
}
