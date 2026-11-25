import AppKit
import JSRCore

// AppKit interaction driver (issue #3): the conformance actions on real views.
// - tap by nodeId or visible text: NSButton.performClick, else the node's
//   tap event dispatched through the host-to-JS lane;
// - input: editable NSTextField text change, delegate fires onChanged/onChange;
// - submit: keyboard done → onSubmit ?? onSubmitted (PROTOCOL v0.2 amendment A1);
// - scroll: pointer scroll on the enclosing NSScrollView (A2);
// - swipe: touch-like drag of the scroll content by the gesture delta;
// - wait: real time on the main run loop; back: __jsrHostEvent("back", {}).

public final class AppKitInteractionDriver: NSObject, InteractionDriver, NSTextFieldDelegate {
    public let mapper: AppKitMapper
    private let runtime: JsWidgetRuntime
    private let registry: ChannelRegistry
    private let engine: JsEngine

    public init(mapper: AppKitMapper, runtime: JsWidgetRuntime, registry: ChannelRegistry, engine: JsEngine) {
        self.mapper = mapper
        self.runtime = runtime
        self.registry = registry
        self.engine = engine
        super.init()
        for view in mapper.views.values {
            wireEditing(in: view)
        }
    }

    private func wireEditing(in view: NSView) {
        if let field = view as? NSTextField, field.isEditable {
            field.delegate = self
        }
        for subview in view.subviews {
            wireEditing(in: subview)
        }
    }

    // MARK: - InteractionDriver

    @discardableResult
    public func tap(target: String) -> Bool {
        guard let nodeId = resolveNodeId(target) else { return false }
        if let button = mapper.views[nodeId] as? NSButton {
            button.performClick(nil) // the real action path
            registry.drain()
            return true
        }
        let record = mapper.records[nodeId]
        mapper.dispatchTap(nodeId: nodeId)
        if record?.events["onTap"] != nil || record?.events["onClick"] != nil || record?.events["onPressed"] != nil {
            registry.drain()
            return true
        }
        return mapper.records[nodeId] != nil
    }

    @discardableResult
    public func input(node target: String, value: String) -> Bool {
        guard let nodeId = resolveNodeId(target), let view = mapper.views[nodeId] else { return false }
        let record = mapper.records[nodeId]
        // text fields land on real editable controls only when the host maps
        // them; the seed types keep the live label path
        if let field = editableField(in: view) {
            field.stringValue = value
            controlTextDidChange(Notification(name: NSTextField.textDidChangeNotification, object: field))
            registry.drain()
            return true
        }
        guard let action = record?.events["onChanged"] ?? record?.events["onChange"] else { return false }
        try? runtime.callEvent(action, payloadJson: JSON.stringify(["value": value]))
        registry.drain()
        return true
    }

    @discardableResult
    public func submit(node target: String) -> Bool {
        guard let nodeId = resolveNodeId(target), let record = mapper.records[nodeId] else { return false }
        let value = liveText(nodeId: nodeId) ?? record.textContent ?? ""
        guard let action = record.events["onSubmit"] ?? record.events["onSubmitted"] else { return false }
        try? runtime.callEvent(action, payloadJson: JSON.stringify(["value": value]))
        registry.drain()
        return true
    }

    public func scroll(dx: Double, dy: Double) {
        guard let scrollView = enclosingScrollView() else { return }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let document = scrollView.documentView
        let current = document?.frame.origin ?? .zero
        let clip = scrollView.contentView
        let adjusted = NSPoint(x: current.x + dx, y: max(0, current.y + dy))
        clip.bounds.origin = adjusted
        scrollView.reflectScrolledClipView(clip)
    }

    public func swipe(x1: Double, y1: Double, x2: Double, y2: Double, ms: Double) {
        // touch-like drag: the content moves by the gesture delta (drag up scrolls down)
        scroll(dx: x2 - x1, dy: y1 - y2)
    }

    public func wait(ms: Double) {
        let deadline = Date().addingTimeInterval(ms / 1000.0)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        registry.drain()
    }

    public func back() {
        try? engine.eval("__jsrHostEvent(\"back\", {})", sourceName: "<host-event>")
        registry.drain()
    }

    // MARK: - text editing (delegate)

    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let nodeId: String? = {
            let id = field.accessibilityIdentifier()
            return id.isEmpty ? enclosingNodeId(of: field) : id
        }()
        guard let nodeId, let record = mapper.records[nodeId] else { return }
        guard let action = record.events["onChanged"] ?? record.events["onChange"] else { return }
        try? runtime.callEvent(action, payloadJson: JSON.stringify(["value": field.stringValue]))
    }

    // MARK: - plumbing

    /// nodeId when target matches /^n\d+$/, else the first mapped view whose
    /// live text matches the target.
    public func resolveNodeId(_ target: String) -> String? {
        if target.range(of: "^n\\d+$", options: .regularExpression) != nil {
            return mapper.views[target] != nil ? target : nil
        }
        for (nodeId, view) in mapper.views {
            if liveText(nodeId: nodeId) == target { return nodeId }
            if let button = view as? NSButton, button.title == target { return nodeId }
        }
        return nil
    }

    private func liveText(nodeId: String) -> String? {
        guard let view = mapper.views[nodeId] else { return nil }
        if let field = view as? NSTextField { return field.stringValue }
        if let button = view as? NSButton { return button.title }
        return nil
    }

    private func editableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = editableField(in: subview) { return field }
        }
        return nil
    }

    private func enclosingNodeId(of view: NSView) -> String? {
        var current: NSView? = view
        while let node = current {
            if node.accessibilityIdentifier().range(of: "^n\\d+$", options: .regularExpression) != nil {
                return node.accessibilityIdentifier()
            }
            current = node.superview
        }
        return nil
    }

    private func enclosingScrollView() -> NSScrollView? {
        for view in mapper.views.values.reversed() {
            var current: NSView? = view
            while let node = current {
                if let scrollView = node as? NSScrollView { return scrollView }
                current = node.superview
            }
        }
        return nil
    }
}
