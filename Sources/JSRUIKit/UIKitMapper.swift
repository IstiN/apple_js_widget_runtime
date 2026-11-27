#if canImport(UIKit) && os(iOS)
import UIKit
import JSRCore

// iOS mapping: jsr nodes -> UIKit (issue #2). Same patch machinery and dump
// contract as the AppKit mapper: reconciler ops applied to real views,
// accessibilityIdentifier = nodeId on every mapped root, live text read from
// the views, other props from the applied records. UIKit is flipped by
// default (top-left origin), so no flipped-host shim is needed.

/// Flipped by default; container views host their children with Auto Layout.
final class UIKitContainerView: UIView {}

public final class UIKitMapper: NSObject {
    /// Host-to-JS lane for widget events (callEvent on the runtime).
    public var onEvent: ((_ actionId: String, _ payloadJson: String) -> Void)?

    let container: UIView
    /// The reconciler operations applied by the last render (patch, not rebuild).
    /// Setter internal: tests clear between renders.
    internal(set) var lastOperations: [PatchOperation] = []
    private(set) var childIds: [String: [String]] = [:]
    private(set) var rootId: String?
    /// Applied node records (normalized trees) by nodeId — the dump's prop source.
    /// Setter internal: tests inject views/records (e.g. editable fields).
    internal(set) var records: [String: WidgetNode] = [:]
    /// Mapped root views by nodeId.
    internal(set) var views: [String: UIView] = [:]
    /// The tree the CURRENT views/records reflect (the last applied render).
    private var lastTree: WidgetNode?

    public init(container: UIView) {
        self.container = container
        super.init()
        container.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Renders a raw `__jsr_render` payload: first render builds, later renders
    /// reconcile and apply patches (same retained-tree contract as AppKit).
    public func render(payloadJSON: String) throws {
        let tree = try AuiDump.normalizeTree(payloadJSON: payloadJSON)
        guard let previous = lastTree else {
            lastOperations = []
            mountRoot(tree)
            lastTree = tree
            return
        }
        let mapped = Reconciler.reconcileMapped(previous, tree)
        lastOperations = mapped.operations
        for operation in mapped.operations {
            apply(operation)
        }
        lastTree = mapped.retained
    }

    private func apply(_ operation: PatchOperation) {
        switch operation {
        case let .updateProps(nodeId, props):
            updateProps(nodeId: nodeId, props: props)
        case let .insertChild(parentNodeId, index, node):
            mountChild(node, parentId: parentNodeId, index: index)
            if let siblings = childIds[parentNodeId] {
                childIds[parentNodeId] = siblings // order already correct via insert
            }
        case let .removeChild(parentNodeId, index):
            removeChild(parentNodeId: parentNodeId, index: index)
        case let .moveChild(parentNodeId, from, to):
            moveChild(parentNodeId: parentNodeId, from: from, to: to)
        case let .replaceSubtree(nodeId, node):
            replaceSubtree(nodeId: nodeId, node: node)
        }
    }

    func updateProps(nodeId: String, props: [String: Any]) {
        guard let view = views[nodeId], let record = records[nodeId] else { return }
        applyProps(props, to: view, record: record)
        var merged = record.props
        for (key, value) in props { merged[key] = value }
        records[nodeId] = record.withProps(merged)
    }

    private func removeChild(parentNodeId: String, index: Int) {
        guard let siblings = childIds[parentNodeId], index < siblings.count else { return }
        let nodeId = siblings[index]
        guard let view = views[nodeId] else { return }
        if let stack = view.superview as? UIStackView {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        view.removeFromSuperview()
        unregisterSubtree(nodeId)
        childIds[parentNodeId] = siblings.filter { $0 != nodeId }
    }

    private func moveChild(parentNodeId: String, from: Int, to: Int) {
        guard var siblings = childIds[parentNodeId], from < siblings.count, let view = views[siblings[from]] else { return }
        let nodeId = siblings.remove(at: from)
        let target = min(to, siblings.count)
        siblings.insert(nodeId, at: target)
        childIds[parentNodeId] = siblings
        if let stack = view.superview as? UIStackView {
            stack.removeArrangedSubview(view)
            stack.insertArrangedSubview(view, at: min(target, stack.arrangedSubviews.count))
        }
    }

    private func replaceSubtree(nodeId: String, node: WidgetNode) {
        guard let oldView = views[nodeId], let parentId = parentId(of: nodeId),
              let parentRecord = records[parentId] else { return }
        let superview = oldView.superview
        let stackIndex = (superview as? UIStackView)?.arrangedSubviews.firstIndex(where: { $0 === oldView })
        let originalIndex = childIds[parentId]?.firstIndex(of: nodeId)
        unregisterSubtree(nodeId)
        childIds[parentId]?.removeAll { $0 == nodeId }
        let view = build(node)
        registerSubtree(node, view: view, parentId: parentId)
        // registerSubtree appends; a REPLACED child keeps its original position
        if let originalIndex, var siblings = childIds[parentId],
           siblings.last == node.nodeId, siblings.count > 1 {
            siblings.removeLast()
            siblings.insert(node.nodeId, at: min(originalIndex, siblings.count))
            childIds[parentId] = siblings
        }
        if let superview {
            if let stack = superview as? UIStackView, let index = stackIndex {
                stack.insertArrangedSubview(view, at: index)
            } else {
                superview.addSubview(view)
                if nodeId == rootId {
                    pinToEdges(view, in: superview)
                } else {
                    pinChild(view, in: superview, parentRecord: parentRecord)
                }
            }
        }
        for (childIndex, child) in node.children.enumerated() {
            mountChild(child, parentId: node.nodeId, index: childIndex)
        }
    }

    private func unregisterSubtree(_ nodeId: String) {
        for child in childIds[nodeId] ?? [] {
            unregisterSubtree(child)
        }
        childIds.removeValue(forKey: nodeId)
        records.removeValue(forKey: nodeId)
        views.removeValue(forKey: nodeId)
    }

    private func parentId(of nodeId: String) -> String? {
        childIds.first(where: { $0.value.contains(nodeId) })?.key
    }

    // MARK: - initial mount

    private func mountRoot(_ node: WidgetNode) {
        let view = build(node)
        registerSubtree(node, view: view, parentId: nil)
        container.addSubview(view)
        pinToEdges(view, in: container)
        for (index, child) in node.children.enumerated() {
            mountChild(child, parentId: node.nodeId, index: index)
        }
    }

    private func mountChild(_ child: WidgetNode, parentId: String, index: Int) {
        guard let parentView = views[parentId], let parentRecord = records[parentId] else { return }
        let view = build(child)
        registerSubtree(child, view: view, parentId: parentId)
        let host = hostForChild(in: parentView, parentRecord: parentRecord)
        if let stack = host as? UIStackView {
            stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
        } else {
            host.addSubview(view)
            pinChild(view, in: host, parentRecord: parentRecord)
        }
        for (childIndex, grandChild) in child.children.enumerated() {
            mountChild(grandChild, parentId: child.nodeId, index: childIndex)
        }
    }

    private func registerSubtree(_ node: WidgetNode, view: UIView, parentId: String?) {
        records[node.nodeId] = node
        views[node.nodeId] = view
        childIds[node.nodeId] = node.children.map { $0.nodeId }
        if let parentId {
            var siblings = childIds[parentId] ?? []
            if !siblings.contains(node.nodeId) { siblings.append(node.nodeId) }
            childIds[parentId] = siblings
        } else {
            rootId = node.nodeId
        }
    }

    /// The view that hosts a child of `parentView`: stacks host directly, a
    /// scroll view embeds its content stack, plain views host directly.
    private func hostForChild(in parentView: UIView, parentRecord: WidgetNode) -> UIView {
        if parentRecord.type == "scroll", let scrollView = parentView as? UIScrollView {
            if let content = scrollView.subviews.first(where: { $0 is UIStackView }) {
                return content
            }
            let content = UIStackView()
            content.axis = .vertical
            content.alignment = .fill
            content.distribution = .fill
            content.spacing = 0
            content.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            ])
            return content
        }
        return parentView
    }

    // MARK: - props

    /// Canonical prop key: the contract's alias keys collapse to one applier.
    private static let textValueKeys: Set<String> = ["data", "text", "title", "label"]
    private static let colorKeys: Set<String> = ["color", "backgroundColor"]

    static func canonicalPropKey(_ key: String) -> String {
        if textValueKeys.contains(key) { return "text" }
        if colorKeys.contains(key) { return "color" }
        return key
    }

    private func applyProps(_ props: [String: Any], to view: UIView, record: WidgetNode) {
        for (key, value) in props {
            applyProp(key, value, to: view, record: record)
        }
    }

    private func applyProp(_ key: String, _ value: Any, to view: UIView, record: WidgetNode) {
        applyCanonicalProp(UIKitMapper.canonicalPropKey(key), value, to: view, record: record)
    }

    private func applyCanonicalProp(_ canonical: String, _ value: Any, to view: UIView, record: WidgetNode) {
        switch canonical {
        case "text":
            applyTextValue(value, to: view)
        case "color":
            applyColor(value, to: view, record: record)
        case "decoration":
            applyDecoration(view, record: record.withProps(["decoration": value]))
        case "fontSize", "fontWeight", "borderRadius", "spacing":
            applyMetricProp(canonical, value, to: view, record: record)
        default:
            break // remaining props live on the applied record (dump source)
        }
    }

    private func applyMetricProp(_ canonical: String, _ value: Any, to view: UIView, record: WidgetNode) {
        switch canonical {
        case "fontSize":
            applyFontSize(value, to: view, record: record)
        case "fontWeight":
            applyFontWeight(value, to: view, record: record)
        case "borderRadius":
            applyBorderRadius(value, to: view)
        case "spacing":
            applySpacing(value, to: view)
        default:
            break
        }
    }

    private func applyTextValue(_ value: Any, to view: UIView) {
        guard let text = value as? String else { return }
        if let label = view as? UILabel { label.text = text }
        if let field = view as? UITextField { field.text = text }
        if let button = view as? UIButton { button.setTitle(text, for: .normal) }
    }

    private func applyColor(_ value: Any, to view: UIView, record: WidgetNode) {
        guard let color = colorValue(value) else { return }
        if record.type == "text", let label = view as? UILabel {
            label.textColor = color
        } else {
            view.backgroundColor = color
        }
    }

    private func applyFontSize(_ value: Any, to view: UIView, record: WidgetNode) {
        let size = (value as? NSNumber)?.doubleValue ?? 14
        let weightName = record.props["fontWeight"] as? String ?? "regular"
        setFontSize(size, of: view, weightName: weightName)
    }

    private func applyFontWeight(_ value: Any, to view: UIView, record: WidgetNode) {
        let size = (record.props["fontSize"] as? NSNumber)?.doubleValue ?? 14
        let weightName = value as? String ?? "regular"
        setFontSize(size, of: view, weightName: weightName)
    }

    private func setFontSize(_ size: Double, of view: UIView, weightName: String) {
        guard let label = view as? UILabel else { return }
        label.font = .systemFont(ofSize: size, weight: fontWeight(weightName))
    }

    private func applyBorderRadius(_ value: Any, to view: UIView) {
        view.layer.cornerRadius = (value as? NSNumber)?.doubleValue ?? 0
        view.layer.masksToBounds = true
    }

    private func applySpacing(_ value: Any, to view: UIView) {
        (view as? UIStackView)?.spacing = (value as? NSNumber)?.doubleValue ?? 0
    }

    private func applyDecoration(_ view: UIView, record: WidgetNode) {
        var background = record.props["backgroundColor"]
        if let decoration = record.props["decoration"] as? [String: Any] {
            if decoration["color"] != nil { background = decoration["color"] }
            if let radius = (decoration["radius"] as? NSNumber)?.doubleValue ?? (decoration["borderRadius"] as? NSNumber)?.doubleValue {
                view.layer.cornerRadius = radius
                view.layer.masksToBounds = true
            }
        }
        if let color = colorValue(background) {
            view.backgroundColor = color
        }
    }

    private func colorValue(_ value: Any?) -> UIColor? {
        guard let hex = value as? String else { return nil }
        var cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if cleaned.count == 3 { cleaned = cleaned.map { "\($0)\($0)" }.joined() }
        guard let rgb = UInt64(cleaned, radix: 16) else { return nil }
        if cleaned.count == 8 {
            return rgba(rgb)
        }
        if cleaned.count == 6 {
            return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                           green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                           blue: CGFloat(rgb & 0xFF) / 255.0,
                           alpha: 1)
        }
        return nil
    }

    private func rgba(_ rgb: UInt64) -> UIColor {
        UIColor(red: CGFloat((rgb >> 24) & 0xFF) / 255.0,
                green: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                blue: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                alpha: CGFloat(rgb & 0xFF) / 255.0)
    }

    private static let fontWeights: [String: UIFont.Weight] = [
        "bold": .bold, "w600": .semibold, "semibold": .semibold,
        "w500": .medium, "medium": .medium, "light": .light, "black": .black,
    ]

    private func fontWeight(_ name: String) -> UIFont.Weight {
        UIKitMapper.fontWeights[name] ?? .regular
    }

    // MARK: - view construction

    /// Builder table: node type → view constructor; unknown types fall back.
    private static let builders: [String: (UIKitMapper, WidgetNode) -> UIView] = [
        "column": { mapper, node in mapper.buildStack(node, horizontal: false) },
        "row": { mapper, node in mapper.buildStack(node, horizontal: true) },
        "text": { mapper, node in mapper.buildText(node) },
        "textField": { mapper, node in mapper.buildEditableField(node) },
        "sizedBox": { mapper, node in mapper.buildSizedBox(node) },
        "textButton": { mapper, node in mapper.buildTextButton(node) },
        "scroll": { mapper, _ in mapper.buildScroll() },
        "container": { mapper, node in mapper.buildContainer(node) },
        "center": { _, _ in UIView() },
    ]

    private func build(_ node: WidgetNode) -> UIView {
        let view: UIView
        if let make = UIKitMapper.builders[node.type] {
            view = make(self, node)
        } else {
            view = buildFallback(node)
        }
        view.accessibilityIdentifier = node.nodeId
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func buildStack(_ node: WidgetNode, horizontal: Bool) -> UIStackView {
        let stack = UIStackView()
        stack.axis = horizontal ? .horizontal : .vertical
        stack.alignment = horizontal ? .center : .fill
        stack.distribution = .fill
        stack.spacing = (node.props["spacing"] as? NSNumber)?.doubleValue ?? 0
        return stack
    }

    private func buildText(_ node: WidgetNode) -> UILabel {
        let label = UILabel()
        label.text = node.textContent ?? ""
        label.numberOfLines = 0
        styleText(label, record: node)
        return label
    }

    private func buildEditableField(_ node: WidgetNode) -> UITextField {
        let field = UITextField()
        field.placeholder = node.props["hint"] as? String ?? node.props["placeholder"] as? String
        field.text = node.props["value"] as? String ?? node.textContent
        field.borderStyle = .roundedRect
        field.addTarget(self, action: #selector(fieldEditingChanged(_:)), for: .editingChanged)
        return field
    }

    @objc private func fieldEditingChanged(_ field: UITextField) {
        dispatchTextChanged(fieldId: field.accessibilityIdentifier ?? "", value: field.text ?? "")
    }

    /// Dispatches the node's onChanged/onChange event through the host-to-JS lane.
    func dispatchTextChanged(fieldId: String, value: String) {
        guard let record = records[fieldId],
              let action = record.events["onChanged"] ?? record.events["onChange"] else { return }
        let payload = JSON.stringify(["value": value])
        onEvent?(action, payload)
    }

    private func styleText(_ label: UILabel, record: WidgetNode) {
        let fontSize = (record.props["fontSize"] as? NSNumber)?.doubleValue ?? 14
        label.font = .systemFont(ofSize: fontSize, weight: fontWeight(record.props["fontWeight"] as? String ?? "regular"))
        if let color = colorValue(record.props["color"]) {
            label.textColor = color
        }
    }

    private func buildSizedBox(_ node: WidgetNode) -> UIView {
        let view = UIView()
        if let width = (node.props["width"] as? NSNumber)?.doubleValue {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        if let height = (node.props["height"] as? NSNumber)?.doubleValue {
            view.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        return view
    }

    private func buildTextButton(_ node: WidgetNode) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(node.textContent ?? node.props["text"] as? String ?? "", for: .normal)
        button.addTarget(self, action: #selector(handleButton(_:)), for: .touchUpInside)
        return button
    }

    @objc private func handleButton(_ sender: UIButton) {
        dispatchTap(nodeId: sender.accessibilityIdentifier ?? "")
    }

    /// Dispatches the node's tap event through the host-to-JS lane.
    func dispatchTap(nodeId: String) {
        guard let record = records[nodeId],
              let action = record.events["onTap"] ?? record.events["onClick"] ?? record.events["onPressed"] else { return }
        onEvent?(action, "{}")
    }

    private func buildScroll() -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        return scrollView
    }

    private func buildContainer(_ node: WidgetNode) -> UIView {
        let view = UIKitContainerView()
        applyDecoration(view, record: node)
        return view
    }

    private func buildFallback(_ node: WidgetNode) -> UIView {
        let card = UIKitContainerView()
        card.backgroundColor = UIColor.secondarySystemBackground
        card.layer.cornerRadius = 8
        card.layer.masksToBounds = true
        let label = UILabel()
        label.text = node.type
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 8),
            label.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -8),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        return card
    }

    // MARK: - constraints

    private func pinToEdges(_ view: UIView, in parent: UIView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: parent.topAnchor),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    /// Container/center children: centered with top+lead pinning (resize-safe).
    private func pinChild(_ view: UIView, in parent: UIView, parentRecord: WidgetNode) {
        if parentRecord.type == "center" {
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: parent.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: parent.topAnchor),
                view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                view.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor),
            ])
        }
    }

    // MARK: - dump (AUI section 2)

    /// AUI dump: type from the node registry, props from the applied record,
    /// text-bearing props read live from the views.
    public func dump() -> [String: Any] {
        dumpNode(rootId ?? "n0")
    }

    func dumpNode(_ nodeId: String) -> [String: Any] {
        guard let record = records[nodeId] else { return [:] }
        var props = record.props
        mergeLiveText(of: nodeId, into: &props)
        mergeScrollState(of: nodeId, record: record, into: &props)
        let children = (childIds[nodeId] ?? []).compactMap { id -> [String: Any]? in
            views[id] != nil ? dumpNode(id) : nil
        }
        return record.withProps(props).jsonObject.merging(["children": children]) { _, new in new }
    }

    /// A3: live scroll state of a scrollable container (resolved type
    /// `scroll`), read from the UIScrollView at dump time — offset =
    /// `contentOffset.y`, extent = the full `contentSize.height`, viewport =
    /// `bounds.height` (logical points, primary axis, ≥ 0).
    private func mergeScrollState(of nodeId: String, record: WidgetNode, into props: inout [String: Any]) {
        guard record.type == "scroll", let scrollView = views[nodeId] as? UIScrollView else { return }
        container.layoutIfNeeded() // windowless hosts never run layout on their own
        props["scrollOffset"] = scrollView.contentOffset.y
        props["scrollExtent"] = scrollView.contentSize.height
        props["viewportExtent"] = scrollView.bounds.height
    }

    /// Live text-bearing props (the dump proves what is on screen): labels
    /// and buttons report their on-screen text, fields their live value.
    private func mergeLiveText(of nodeId: String, into props: inout [String: Any]) {
        guard let view = views[nodeId] else { return }
        if let label = view as? UILabel, let text = label.text {
            props["data"] = text
        } else if let field = view as? UITextField, let text = field.text {
            props["value"] = text
        } else if let button = view as? UIButton, let title = button.title(for: .normal) {
            props["data"] = title
        }
    }
}

public extension UIView {
    /// Windowless hosts (the demo conformance loop and the test host) hold the
    /// mapper container in no window: with `translatesAutoresizingMaskIntoConstraints`
    /// off, `layoutIfNeeded` collapses an unconstrained frame to zero. The
    /// host states its surface size explicitly; the app path sizes the
    /// container by its own constraints and is unaffected.
    func constrainToWindowSize(width: CGFloat, height: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }
}
#endif
