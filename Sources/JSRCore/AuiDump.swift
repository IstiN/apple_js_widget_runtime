import Foundation

// AUI normalization — plan 1.3 rules 1..7, Swift port of the pinned harness
// reference (js_widget_runtime harness/normalize.mjs + harness/aliases.mjs,
// itself copied from the Flutter UiViewTreeNormalizer). The harness derives
// the expected dump from the widget's own render payloads with the same rules,
// so this port must stay behavior-identical.

// Reference type-alias table (verbatim from UiViewTreeNormalizer._typeAliases).
private let typeAliases: [String: String] = [
    "Text": "text", "text": "text", "Label": "text", "label": "text", "p": "text", "span": "text",
    "Button": "button", "button": "button", "ElevatedButton": "button", "elevatedButton": "button",
    "TextButton": "textButton", "OutlinedButton": "outlinedButton", "IconButton": "iconButton",
    "Rect": "rect", "Circle": "circle", "Line": "line", "Polygon": "polygon",
    "View": "column", "view": "column", "div": "column", "box": "container", "Box": "container",
    "Fragment": "column", "ScrollView": "scroll", "scrollView": "scroll", "scroll": "scroll",
    "SingleChildScrollView": "scroll", "singleChildScrollView": "scroll",
    "ListView": "listView", "GridView": "gridView",
    "Image": "image", "networkImage": "image", "NetworkImage": "image", "img": "image",
    "Svg": "svg", "SVG": "svg", "Card": "card", "Row": "row", "Column": "column", "Stack": "stack",
    "Center": "center", "Padding": "padding", "SizedBox": "sizedBox", "Container": "container",
    "ListTile": "listTile", "listItem": "listTile", "ListItem": "listTile",
    "ProgressBar": "linearProgressIndicator", "progress": "linearProgressIndicator", "linearProgress": "linearProgressIndicator",
    "ActivityIndicator": "circularProgressIndicator", "spinner": "circularProgressIndicator",
    "TextInput": "textField", "textInput": "textField", "input": "textField",
    "TextArea": "textArea", "textarea": "textArea",
    "Switch": "switch", "Checkbox": "checkbox", "Slider": "slider",
    "Markdown": "markdown", "md": "markdown",
    "Avatar": "circleAvatar", "CircleAvatar": "circleAvatar", "avatar": "circleAvatar",
    "Chip": "chip", "Tag": "chip", "tag": "chip", "Badge": "badge",
    "Dropdown": "dropdown", "Select": "dropdown", "select": "dropdown",
    "InkWell": "inkWell", "GestureDetector": "gestureDetector", "SafeArea": "safeArea",
    "Divider": "divider", "Spacer": "spacer", "Icon": "icon",
    "Scene3d": "scene3d", "scene3d": "scene3d", "scene3D": "scene3d",
    "3d": "scene3d", "model3d": "scene3d", "model": "scene3d", "glb": "scene3d",
]

private let structuralKeys: Set<String> = ["type", "child", "children", "items", "key", "style", "props", "events", "nodeId", "__iid"]
private let boxTypes: Set<String> = ["container", "card", "animatedContainer"]
private let buttonTypes: Set<String> = ["button", "textButton", "outlinedButton"]
private let inputTypes: Set<String> = ["textField", "input", "textArea"]
private let imageTypes: Set<String> = ["image", "networkImage", "img"]
private let valueTypes: Set<String> = ["switch", "checkbox", "slider"]

public enum AuiDumpError: Error {
    case notANodeObject
    case missingStringType
}

public enum AuiDump {
    /// Colors become `#RRGGBB` or `#RRGGBBAA` with upper-case hex (rule 6);
    /// named CSS colors are out of contract.
    public static func normalizeColor(_ value: Any) -> Any {
        guard let string = value as? String else { return value }
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            return normalizeHexColor(trimmed) ?? value
        }
        if trimmed.lowercased().hasPrefix("rgb"), trimmed.hasSuffix(")"), trimmed.contains("(") {
            return normalizeRgbColor(trimmed) ?? value
        }
        return value
    }

    /// `#RGB`/`#RGBA` double each digit; `#RRGGBB(BB)` upper-case; else nil.
    static func normalizeHexColor(_ trimmed: String) -> String? {
        guard trimmed.count >= 4 else { return nil }
        let hex = String(trimmed.dropFirst())
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        if hex.count == 3 || hex.count == 4 {
            return "#" + hex.map { "\($0)\($0)" }.joined().uppercased()
        }
        if hex.count == 6 || hex.count == 8 {
            return "#\(hex.uppercased())"
        }
        return nil
    }

    /// `rgb(r, g, b)` / `rgba(r, g, b, a)` → `#RRGGBB(AA)`; nil when malformed.
    static func normalizeRgbColor(_ trimmed: String) -> String? {
        guard let open = trimmed.range(of: "(")?.upperBound, trimmed.hasSuffix(")") else { return nil }
        let inner = String(trimmed[open..<trimmed.index(before: trimmed.endIndex)])
        let nums = inner.split(whereSeparator: { " ,+/".contains($0) }).compactMap { Double($0) }
        guard nums.count == 3 || nums.count == 4 else { return nil }
        var out = "#" + nums.prefix(3).map { hexByte($0) }.joined()
        if nums.count == 4 {
            var alpha = nums[3]
            if alpha > 1 { alpha /= 255.0 } // alpha > 1 read as 0-255 scale
            out += hexByte((alpha * 255.0).rounded())
        }
        return out
    }

    private static func hexByte(_ n: Double) -> String {
        String(format: "%02X", max(0, min(255, Int(n.rounded()))))
    }

    /// Normalizes a raw `__jsr_render` payload string (rule 7: nodeIds assigned).
    /// Accepts the protocol `{ root: {...} }` wrapper for integration safety.
    public static func normalizeTree(payloadJSON: String) throws -> WidgetNode {
        guard let payload = JSON.parse(payloadJSON) as? [String: Any] else {
            throw AuiDumpError.notANodeObject
        }
        var root = payload
        if root["type"] == nil, let wrapper = root["root"] as? [String: Any] {
            root = wrapper
        }
        let tree = try buildNode(root)
        return assignNodeIds(tree, counter: 0).node
    }

    // MARK: - rule 1..6 node construction

    static func buildNode(_ node: Any) throws -> WidgetNode {
        guard let dict = node as? [String: Any] else { throw AuiDumpError.notANodeObject }
        guard let rawType = dict["type"] as? String else { throw AuiDumpError.missingStringType }

        var working = workingMap(of: dict)
        working["type"] = resolveTypeAlias(rawType)
        applyFieldAliases(&working)

        var props: [String: Any] = [:]
        var events: [String: String] = extractEvents(working)
        mergePropsAndStyle(working, dict, into: &props, events: &events)
        let identityKey = working["key"] as? String // rule 4: consumed, never dumped
        return WidgetNode(type: working["type"] as? String ?? rawType, props: props, events: events,
                          children: rawChildren(working).map(toChild), nodeId: "", identityKey: identityKey)
    }

    /// working map: normalized props first, then top-level keys (node keys win).
    private static func workingMap(of dict: [String: Any]) -> [String: Any] {
        var working: [String: Any] = [:]
        if let props = dict["props"] as? [String: Any] {
            for (key, value) in props { working[key] = value }
        }
        for (key, value) in dict where key != "props" && working[key] == nil {
            working[key] = value
        }
        return working
    }

    /// rule 2: `on*` string props move to events.
    private static func extractEvents(_ working: [String: Any]) -> [String: String] {
        guard let existing = working["events"] as? [String: Any] else { return [:] }
        var events: [String: String] = [:]
        for (key, value) in existing where value is String {
            events[key] = value as? String
        }
        return events
    }

    /// Props loop (rule 6 normalization) + rule 1 style merge (node keys win).
    private static func mergePropsAndStyle(_ working: [String: Any], _ dict: [String: Any], into props: inout [String: Any], events: inout [String: String]) {
        for (key, value) in working {
            if structuralKeys.contains(key) || key == "events" { continue }
            if key.range(of: "^on[A-Z]", options: .regularExpression) != nil, value is String {
                events[key] = value as? String // rule 2
                continue
            }
            props[key] = normalizePropValue(key, value) // rule 6
        }
        if let style = dict["style"] as? [String: Any] { // rule 1: node keys win over style keys
            for (key, value) in style where props[key] == nil && events[key] == nil {
                props[key] = normalizePropValue(key, value)
            }
        }
    }

    static func toChild(_ child: Any) -> WidgetNode {
        if let string = child as? String {
            return (try? buildNode(["type": "text", "data": string])) ?? WidgetNode(type: "text", props: [:], events: [:], children: [], nodeId: "")
        }
        return (try? buildNode(child)) ?? WidgetNode(type: "text", props: [:], events: [:], children: [], nodeId: "")
    }

    static func resolveTypeAlias(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespaces)
        return typeAliases[key] ?? typeAliases[key.lowercased()] ?? key
    }

    // Reference UiViewTreeNormalizer._aliasFields: an alias applies only when
    // its target prop is absent, so a dump that already carries both props
    // stays unchanged (idempotent). Dispatch is a table — one group per type set.
    private static let aliasGroups: [(types: Set<String>, apply: (inout [String: Any]) -> Void)] = [
        (boxTypes, { out in aliasBoxDecoration(&out, type: out["type"] as? String ?? "") }),
        (buttonTypes, { out in aliasButtonLabel(&out) }),
        (inputTypes, { out in aliasInputFields(&out, type: out["type"] as? String ?? "") }),
        (imageTypes, { out in aliasImageSource(&out) }),
        (["svg"], { out in aliasSvgMarkup(&out) }),
        (valueTypes, { out in aliasOnChanged(&out) }),
        (["dropdown", "select"], { out in
            out["type"] = "dropdown"
            aliasOnChanged(&out)
        }),
    ]

    static func applyFieldAliases(_ out: inout [String: Any]) {
        aliasTextContent(&out)
        let type = out["type"] as? String ?? ""
        for group in aliasGroups where group.types.contains(type) {
            group.apply(&out)
        }
    }

    private static func aliasTextContent(_ out: inout [String: Any]) {
        if out["content"] != nil, out["data"] == nil {
            out["data"] = out["content"]
            out.removeValue(forKey: "content")
        }
        if out["label"] != nil, out["data"] == nil, out["type"] as? String == "text" {
            out["data"] = out["label"] // reference keeps the label prop
        }
    }

    private static func aliasBoxDecoration(_ out: inout [String: Any], type: String) {
        if out["backgroundColor"] != nil, out["decoration"] == nil {
            out["decoration"] = ["color": out["backgroundColor"] as Any]
            out.removeValue(forKey: "backgroundColor")
        }
        if out["color"] != nil, out["decoration"] == nil, type == "container" {
            out["decoration"] = ["color": out["color"] as Any]
            out.removeValue(forKey: "color")
        }
    }

    private static func aliasButtonLabel(_ out: inout [String: Any]) {
        if out["title"] != nil, out["data"] == nil {
            out["data"] = out["title"]
            out.removeValue(forKey: "title")
        }
        if out["text"] != nil, out["data"] == nil {
            out["data"] = out["text"]
            out.removeValue(forKey: "text")
        }
    }

    private static func aliasInputFields(_ out: inout [String: Any], type: String) {
        out["type"] = type == "textArea" ? "textArea" : "textField"
        if out["placeholder"] != nil, out["hint"] == nil {
            out["hint"] = out["placeholder"]
            out.removeValue(forKey: "placeholder")
        }
        if out["value"] != nil, out["initialValue"] == nil {
            out["initialValue"] = out["value"]
            out.removeValue(forKey: "value")
        }
        aliasOnChanged(&out)
    }

    private static func aliasImageSource(_ out: inout [String: Any]) {
        out["type"] = "image"
        if out["uri"] != nil, out["url"] == nil {
            out["url"] = out["uri"]
            out.removeValue(forKey: "uri")
        }
        if out["source"] != nil, out["url"] == nil {
            out["url"] = out["source"]
            out.removeValue(forKey: "source")
        }
    }

    private static func aliasSvgMarkup(_ out: inout [String: Any]) {
        if out["markup"] != nil, out["data"] == nil {
            out["data"] = out["markup"]
            out.removeValue(forKey: "markup")
        }
    }

    private static func aliasOnChanged(_ out: inout [String: Any]) {
        if out["onChanged"] != nil, out["onChange"] == nil {
            out["onChange"] = out["onChanged"]
            out.removeValue(forKey: "onChanged")
        }
    }

    // rule 3: children (array) / child (one) / items (array); strings become text nodes.
    static func rawChildren(_ working: [String: Any]) -> [Any] {
        if let children = working["children"] as? [Any] { return children }
        if let child = working["child"], !(child is NSNull) { return [child] }
        if let items = working["items"] as? [Any] { return items } // reference: items -> children
        return []
    }

    static func normalizePropValue(_ key: String, _ value: Any) -> Any {
        if key.range(of: "color", options: .caseInsensitive) != nil { return normalizeColor(value) }
        if let array = value as? [Any] {
            return array.map { $0 is [String: Any] ? normalizePropValue("*", $0) : $0 }
        }
        if let object = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in object { out[k] = normalizePropValue(k, v) }
            return out
        }
        return value
    }

    // rule 7: nodeId = n<i>, depth-first pre-order, every node counted.
    static func assignNodeIds(_ node: WidgetNode, counter: Int) -> (node: WidgetNode, next: Int) {
        let tagged = node.withNodeId("n\(counter)")
        var next = counter + 1
        var children: [WidgetNode] = []
        for child in tagged.children {
            let result = assignNodeIds(child, counter: next)
            children.append(result.node)
            next = result.next
        }
        return (tagged.withChildren(children), next)
    }
}
