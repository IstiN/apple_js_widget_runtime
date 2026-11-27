#if canImport(UIKit) && os(iOS)
import UIKit
import JSRCore

// iOS interaction driver on real UIKit views (issue #2). Same action contract
// as the AppKit driver: tap by nodeId/visible text (UIControl sendActions),
// input through real editable fields (editingChanged -> onChanged), submit =
// the keyboard done path (A1: UITextField return key -> onSubmit/onSubmitted),
// scroll = setContentOffset by the delta (A2 iOS equivalent of a pointer
// scroll), swipe stays the drag (offset move), wait pumps the run loop,
// back -> __jsrHostEvent.

public final class UIKitInteractionDriver: NSObject, InteractionDriver, UITextFieldDelegate {
    public let mapper: UIKitMapper
    private let runtime: JsWidgetRuntime
    private let registry: ChannelRegistry
    private let engine: JsEngine

    public init(mapper: UIKitMapper, runtime: JsWidgetRuntime, registry: ChannelRegistry, engine: JsEngine) {
        self.mapper = mapper
        self.runtime = runtime
        self.registry = registry
        self.engine = engine
        super.init()
        for view in mapper.views.values {
            wireEditing(in: view)
        }
    }

    private func wireEditing(in view: UIView) {
        if let field = view as? UITextField {
            field.delegate = self
        }
        for subview in view.subviews {
            wireEditing(in: subview)
        }
    }

    // MARK: - InteractionDriver

    public func currentTree() -> WidgetNode? {
        guard let payload = mapper.records[mapper.rootId ?? ""] else { return nil }
        return payload
    }

    @discardableResult
    public func tap(target: String) -> Bool {
        guard let nodeId = resolveNodeId(target) else { return false }
        if let button = mapper.views[nodeId] as? UIButton {
            button.sendActions(for: .touchUpInside) // the real action path
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
        if let field = editableField(in: view) {
            field.text = value
            field.sendActions(for: .editingChanged) // the real editing path
            registry.drain()
            return true
        }
        guard let action = record?.events["onChanged"] ?? record?.events["onChange"] else { return false }
        try? runtime.callEvent(action, payloadJson: JSON.stringify(["value": value]))
        registry.drain()
        return true
    }

    /// A1 submit: the keyboard done path. Ends editing on the field (the
    /// return-key equivalent, `textFieldShouldReturn`) and dispatches
    /// onSubmit/onSubmitted with the field's live value.
    @discardableResult
    public func submit(node target: String) -> Bool {
        guard let nodeId = resolveNodeId(target), let view = mapper.views[nodeId],
              let record = mapper.records[nodeId] else { return false }
        guard let action = record.events["onSubmit"] ?? record.events["onSubmitted"] else { return false }
        if let field = editableField(in: view) {
            field.endEditing(true) // return-key equivalent
            textFieldShouldReturn(field)
            return true
        }
        let value = liveText(nodeId: nodeId) ?? record.textContent ?? ""
        try? runtime.callEvent(action, payloadJson: JSON.stringify(["value": value]))
        registry.drain()
        return true
    }

    /// A2 scroll: `setContentOffset` by the delta at the surface center — the
    /// iOS equivalent of a pointer scroll by [dx, dy] (AppKit synthesizes a
    /// scroll wheel event; UIKit scrolls the enclosing UIScrollView directly).
    public func scroll(dx: Double, dy: Double) {
        guard let scrollView = enclosingScrollView() else { return }
        mapper.container.layoutIfNeeded() // windowless hosts never run layout on their own
        let current = scrollView.contentOffset
        let maxOffsetX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let maxOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let next = CGPoint(x: min(max(0, current.x + dx), maxOffsetX),
                           y: min(max(0, current.y + dy), maxOffsetY))
        scrollView.setContentOffset(next, animated: false)
    }

    public func swipe(x1: Double, y1: Double, x2: Double, y2: Double, ms: Double) {
        // touch flick: the content carries the gesture delta plus the momentum
        // coast (A3: the dumped scrollOffset reflects the real touch gesture)
        scroll(dx: flickCarry(x2 - x1, ms: ms), dy: flickCarry(y1 - y2, ms: ms))
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

    /// A1: the return key commits the field — dispatch onSubmit/onSubmitted
    /// with the live value.
    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        guard let nodeId = textField.accessibilityIdentifier, !nodeId.isEmpty,
              let record = mapper.records[nodeId] else { return true }
        guard let action = record.events["onSubmit"] ?? record.events["onSubmitted"] else { return true }
        try? runtime.callEvent(action, payloadJson: JSON.stringify(["value": textField.text ?? ""]))
        registry.drain()
        return true
    }

    // MARK: - plumbing

    /// nodeId when target matches /^n\d+$/, else the first mapped view whose
    /// live text matches the target.
    func resolveNodeId(_ target: String) -> String? {
        if target.range(of: "^n\\d+$", options: .regularExpression) != nil {
            return mapper.views[target] != nil ? target : nil
        }
        for (nodeId, view) in mapper.views {
            if liveText(nodeId: nodeId) == target { return nodeId }
            if let button = view as? UIButton, button.title(for: .normal) == target { return nodeId }
        }
        return nil
    }

    private func liveText(nodeId: String) -> String? {
        guard let view = mapper.views[nodeId] else { return nil }
        if let label = view as? UILabel { return label.text }
        if let field = view as? UITextField { return field.text }
        if let button = view as? UIButton { return button.title(for: .normal) }
        return nil
    }

    private func editableField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        for subview in view.subviews {
            if let field = editableField(in: subview) { return field }
        }
        return nil
    }

    private func enclosingScrollView() -> UIScrollView? {
        for view in mapper.views.values.reversed() {
            var current: UIView? = view
            while let node = current {
                if let scrollView = node as? UIScrollView { return scrollView }
                current = node.superview
            }
        }
        return nil
    }
}
#endif
