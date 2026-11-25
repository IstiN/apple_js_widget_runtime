import AppKit
import JSRCore

// AppKit mapper (issue #3): the seed node types of the three fixtures —
// center, column, row, text, sizedBox, textButton, scroll, container — mapped
// to NSStackView / NSTextField / NSButton / NSScrollView (+ NSView where a
// prop needs it). Every mapped root view carries accessibilityIdentifier =
// nodeId (AUI dump anchor). Unimplemented node types render the fallback card
// (type name + node id tag). Re-renders apply the reconciler's patch
// operations: one counter tap is one updateProps, not a rebuild.

/// Flipped vertical stack: scroll document view (top-down, scrollable).
final class FlippedScrollDocument: NSStackView {
    override var isFlipped: Bool { true }
}

/// Plain flipped view for container children.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

public final class AppKitMapper: NSObject {
    /// The surface the widget renders into; the mapped root is pinned to it.
    public let container: NSView
    /// Host-to-JS event dispatch: (actionId, payloadJson) → callEvent.
    public var onEvent: ((_ actionId: String, _ payloadJson: String) -> Void)?

    /// Applied node records (normalized trees) by nodeId — the dump's prop source.
    private(set) var records: [String: WidgetNode] = [:]
    /// Mapped root views by nodeId.
    private(set) var views: [String: NSView] = [:]
    /// parent → ordered child nodeIds (the applied tree order).
    private(set) var childIds: [String: [String]] = [:]
    private(set) var rootId: String?
    /// Patch operations of the last render (patch-not-rebuild evidence).
    private(set) var lastOperations: [PatchOperation] = []

    public init(container: NSView) {
        self.container = container
        super.init()
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Renders a raw `__jsr_render` payload: first render builds, later renders
    /// reconcile and apply patches.
    public func render(payloadJSON: String) throws {
        let tree = try AuiDump.normalizeTree(payloadJSON: payloadJSON)
        let previous = rootId.flatMap { records[$0] }
        guard let previous else {
            lastOperations = []
            mountRoot(tree)
            return
        }
        let operations = Reconciler.reconcile(previous, tree)
        lastOperations = operations
        for operation in operations {
            apply(operation)
        }
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
        if let stack = host as? NSStackView {
            stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
        } else {
            host.addSubview(view)
            pinChild(view, in: host, parentRecord: parentRecord)
        }
        for (childIndex, grandChild) in child.children.enumerated() {
            mountChild(grandChild, parentId: child.nodeId, index: childIndex)
        }
    }

    private func registerSubtree(_ node: WidgetNode, view: NSView, parentId: String?) {
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
    /// scroll view embeds its (cached) flipped document stack, plain views
    /// (center/container/fallback) host directly.
    private func hostForChild(in parentView: NSView, parentRecord: WidgetNode) -> NSView {
        if parentRecord.type == "scroll" {
            if let scrollView = parentView as? NSScrollView {
                if let document = scrollView.documentView as? FlippedScrollDocument {
                    return document
                }
                let document = FlippedScrollDocument()
                document.orientation = .vertical
                document.alignment = .leading
                document.spacing = 0
                document.edgeInsets = NSEdgeInsetsZero
                document.translatesAutoresizingMaskIntoConstraints = false
                scrollView.documentView = document
                NSLayoutConstraint.activate([
                    document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
                    document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
                    document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
                    document.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
                ])
                return document
            }
        }
        return parentView
    }

    // MARK: - patch application

    private func apply(_ operation: PatchOperation) {
        switch operation {
        case let .updateProps(nodeId, props):
            updateProps(nodeId: nodeId, props: props)
        case let .insertChild(parentNodeId, index, node):
            mountChild(node, parentId: parentNodeId, index: index)
        case let .removeChild(parentNodeId, index):
            removeChild(parentNodeId: parentNodeId, index: index)
        case let .moveChild(parentNodeId, from, to):
            moveChild(parentNodeId: parentNodeId, from: from, to: to)
        case let .replaceSubtree(nodeId, node):
            replaceSubtree(nodeId: nodeId, node: node)
        }
    }

    private func updateProps(nodeId: String, props: [String: Any]) {
        guard let view = views[nodeId], let record = records[nodeId] else { return }
        // only the changed props touch the view: an unchanged text keeps its
        // live content (property keeping)
        applyProps(props, to: view, record: record)
        var merged = record.props
        for (key, value) in props { merged[key] = value }
        records[nodeId] = record.withProps(merged)
    }

    private func removeChild(parentNodeId: String, index: Int) {
        guard let siblings = childIds[parentNodeId], index < siblings.count else { return }
        let nodeId = siblings[index]
        guard let view = views[nodeId] else { return }
        if let stack = view.superview as? NSStackView {
            stack.removeArrangedSubview(view)
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
        if let stack = view.superview as? NSStackView {
            stack.removeArrangedSubview(view)
            stack.insertArrangedSubview(view, at: min(target, stack.arrangedSubviews.count))
        }
    }

    private func replaceSubtree(nodeId: String, node: WidgetNode) {
        guard let oldView = views[nodeId], let parentId = parentId(of: nodeId),
              let parentRecord = records[parentId] else { return }
        let superview = oldView.superview
        let stackIndex = (superview as? NSStackView)?.arrangedSubviews.firstIndex(where: { $0 === oldView })
        unregisterSubtree(nodeId)
        let view = build(node)
        registerSubtree(node, view: view, parentId: parentId)
        if let superview {
            if let stack = superview as? NSStackView, let index = stackIndex {
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

    // MARK: - view construction

    private func build(_ node: WidgetNode) -> NSView {
        let view: NSView
        switch node.type {
        case "center":
            view = NSView()
            view.wantsLayer = true
        case "column":
            view = buildStack(node, horizontal: false)
        case "row":
            view = buildStack(node, horizontal: true)
        case "text":
            view = buildText(node)
        case "sizedBox":
            view = buildSizedBox(node)
        case "textButton":
            view = buildTextButton(node)
        case "scroll":
            view = buildScroll()
        case "container":
            view = buildContainer(node)
        default:
            view = buildFallback(node)
        }
        view.setAccessibilityIdentifier(node.nodeId)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func buildStack(_ node: WidgetNode, horizontal: Bool) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = horizontal ? .horizontal : .vertical
        stack.alignment = horizontal ? .centerY : .centerX
        stack.distribution = .fill
        stack.spacing = (node.props["spacing"] as? NSNumber)?.doubleValue ?? 0
        stack.wantsLayer = true
        return stack
    }

    private func buildText(_ node: WidgetNode) -> NSTextField {
        let field = NSTextField(labelWithString: node.textContent ?? "")
        field.lineBreakMode = .byWordWrapping
        field.isSelectable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        styleText(field, record: node)
        return field
    }

    private func styleText(_ field: NSTextField, record: WidgetNode) {
        let fontSize = (record.props["fontSize"] as? NSNumber)?.doubleValue ?? 14
        field.font = .systemFont(ofSize: fontSize, weight: fontWeight(record.props["fontWeight"] as? String ?? "regular"))
        if let color = colorValue(record.props["color"]) {
            field.textColor = color
        }
    }

    private func buildSizedBox(_ node: WidgetNode) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        if let width = (node.props["width"] as? NSNumber)?.doubleValue {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        if let height = (node.props["height"] as? NSNumber)?.doubleValue {
            view.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        return view
    }

    private func buildTextButton(_ node: WidgetNode) -> NSButton {
        let button = NSButton(title: node.textContent ?? "", target: self, action: #selector(handleButton(_:)))
        button.isBordered = false
        button.wantsLayer = true
        return button
    }

    @objc private func handleButton(_ sender: NSButton) {
        dispatchTap(nodeId: sender.accessibilityIdentifier())
    }

    /// Dispatches the node's tap event through the host-to-JS lane.
    public func dispatchTap(nodeId: String) {
        guard let record = records[nodeId],
              let action = record.events["onTap"] ?? record.events["onClick"] ?? record.events["onPressed"] else { return }
        onEvent?(action, "{}")
    }

    private func buildScroll() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        return scrollView
    }

    private func buildContainer(_ node: WidgetNode) -> NSView {
        let view = FlippedView()
        view.wantsLayer = true
        applyDecoration(view, record: node)
        return view
    }

    private func buildFallback(_ node: WidgetNode) -> NSView {
        let card = FlippedView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.15).cgColor
        card.layer?.cornerRadius = 8
        let label = NSTextField(labelWithString: node.type)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
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

    private func pinToEdges(_ view: NSView, in parent: NSView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: parent.topAnchor),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    /// Children of plain views. `center` keeps the child centered — resize-safe.
    private func pinChild(_ view: NSView, in parent: NSView, parentRecord: WidgetNode) {
        if parentRecord.type == "center" {
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: parent.centerYAnchor),
            ])
        } else {
            let padding = (parentRecord.props["padding"] as? NSNumber)?.doubleValue ?? 0
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: parent.topAnchor, constant: padding),
                view.bottomAnchor.constraint(lessThanOrEqualTo: parent.bottomAnchor, constant: -padding),
                view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: padding),
                view.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -padding),
            ])
        }
    }

    // MARK: - props

    private func applyProps(_ props: [String: Any], to view: NSView, record: WidgetNode) {
        for (key, value) in props {
            switch key {
            case "data", "text", "title", "label":
                if let text = value as? String {
                    if let field = view as? NSTextField { field.stringValue = text }
                    if let button = view as? NSButton { button.title = text }
                }
            case "color", "backgroundColor":
                if let color = colorValue(value) {
                    if record.type == "text", let field = view as? NSTextField {
                        field.textColor = color
                    } else {
                        view.wantsLayer = true
                        view.layer?.backgroundColor = color.cgColor
                    }
                }
            case "decoration":
                applyDecoration(view, record: record.withProps([key: value]))
            case "fontSize":
                if let field = view as? NSTextField {
                    let size = (value as? NSNumber)?.doubleValue ?? 14
                    field.font = .systemFont(ofSize: size, weight: fontWeight(record.props["fontWeight"] as? String ?? "regular"))
                }
            case "fontWeight":
                if let field = view as? NSTextField {
                    let size = (record.props["fontSize"] as? NSNumber)?.doubleValue ?? 14
                    field.font = .systemFont(ofSize: size, weight: fontWeight(value as? String ?? "regular"))
                }
            case "borderRadius":
                view.wantsLayer = true
                view.layer?.cornerRadius = (value as? NSNumber)?.doubleValue ?? 0
            case "spacing":
                if let stack = view as? NSStackView {
                    stack.spacing = (value as? NSNumber)?.doubleValue ?? 0
                }
            default:
                break // remaining props live on the applied record (dump source)
            }
        }
    }

    private func applyDecoration(_ view: NSView, record: WidgetNode) {
        var background = record.props["backgroundColor"]
        if let decoration = record.props["decoration"] as? [String: Any] {
            background = decoration["color"] ?? background
        }
        if let color = colorValue(background) {
            view.layer?.backgroundColor = color.cgColor
        }
        if let radius = (record.props["borderRadius"] as? NSNumber)?.doubleValue {
            view.layer?.cornerRadius = radius
        }
    }

    private func colorValue(_ value: Any?) -> NSColor? {
        guard let hex = value as? String else { return nil }
        var cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if cleaned.count == 3 { cleaned = cleaned.map { "\($0)\($0)" }.joined() }
        guard cleaned.count == 6 || cleaned.count == 8, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        if cleaned.count == 8 {
            return NSColor(calibratedRed: CGFloat((rgb >> 24) & 0xFF) / 255.0,
                           green: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                           blue: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                           alpha: CGFloat(rgb & 0xFF) / 255.0)
        }
        return NSColor(calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                       green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(rgb & 0xFF) / 255.0,
                       alpha: 1)
    }

    private func fontWeight(_ name: String) -> NSFont.Weight {
        switch name {
        case "bold": return .bold
        case "w600", "semibold": return .semibold
        case "w500", "medium": return .medium
        case "light": return .light
        case "black": return .black
        default: return .regular
        }
    }

    // MARK: - AUI dump from live views (plan 1.3, AppKit row)

    /// Walks the applied records, reading text-bearing props LIVE from the
    /// views; all other props come from the applied-node record.
    public func dump() -> [String: Any] {
        guard let rootId, let root = records[rootId] else { return [:] }
        return dumpNode(root)
    }

    private func dumpNode(_ record: WidgetNode) -> [String: Any] {
        var props = record.props
        if let view = views[record.nodeId] {
            if let field = view as? NSTextField {
                props["data"] = field.stringValue
            } else if let button = view as? NSButton {
                props["data"] = button.title
            }
        }
        return [
            "type": record.type,
            "props": props,
            "events": record.events,
            "children": (childIds[record.nodeId] ?? []).compactMap { records[$0].map(dumpNode) },
            "nodeId": record.nodeId,
        ]
    }
}
