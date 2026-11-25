import Foundation

// Parsed jsr render tree (contract: js_widget_runtime docs/contract inventory).
public struct WidgetNode {
    public let type: String
    public let props: [String: Any]
    /// Event key -> action id ("onTap": "a1"); normalization moves `on*` string props here.
    public let events: [String: String]
    public private(set) var children: [WidgetNode]
    /// Stable id assigned in depth-first render order ("n0..nN") — feeds AUI dump nodeId.
    public let nodeId: String

    public init(type: String, props: [String: Any], events: [String: String] = [:], children: [WidgetNode], nodeId: String) {
        self.type = type
        self.props = props
        self.events = events
        self.children = children
        self.nodeId = nodeId
    }

    /// Parses the raw __jsr_render payload JSON into a tree (no normalization).
    public static func parse(payloadJSON: String) throws -> WidgetNode {
        guard let obj = JSON.parse(payloadJSON) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "payload is not JSON"))
        }
        var counter = 0
        func walk(_ any: Any) throws -> WidgetNode {
            guard let dict = any as? [String: Any],
                  let type = dict["type"] as? String else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "node without 'type': \(any)"))
            }
            let events = (dict["events"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            // structural keys are not props (rule 3 keeps `child`/`children` out;
            // `key` STAYS — the reconciler's identity reads it)
            let structural: Set<String> = ["type", "children", "child", "events"]
            let props = dict.filter { !structural.contains($0.key) }
            var node = WidgetNode(type: type, props: props, events: events, children: [],
                                  nodeId: "n\(counter)")
            counter += 1
            if let arr = dict["children"] as? [Any] {
                node.children = try arr.map(walk)
            } else if let child = dict["child"], !(child is NSNull) {
                node.children = [try walk(child)] // rule 3: child (one object) becomes children
            }
            return node
        }
        return try walk(obj)
    }

    public func withChildren(_ children: [WidgetNode]) -> WidgetNode {
        WidgetNode(type: type, props: props, events: events, children: children, nodeId: nodeId)
    }

    public func withNodeId(_ nodeId: String) -> WidgetNode {
        WidgetNode(type: type, props: props, events: events, children: children, nodeId: nodeId)
    }

    public func withProps(_ props: [String: Any]) -> WidgetNode {
        WidgetNode(type: type, props: props, events: events, children: children, nodeId: nodeId)
    }

    /// Dump/patch shape: {type, props, events, children, nodeId}.
    public var jsonObject: [String: Any] {
        [
            "type": type,
            "props": props,
            "events": events,
            "children": children.map { $0.jsonObject },
            "nodeId": nodeId,
        ]
    }

    /// Depth-first search.
    public func first(where predicate: (WidgetNode) -> Bool) -> WidgetNode? {
        if predicate(self) { return self }
        for child in children {
            if let hit = child.first(where: predicate) { return hit }
        }
        return nil
    }

    /// Text-bearing props per PROTOCOL.md section 2 (read live from the node record).
    public var textContent: String? {
        for key in ["data", "text", "hint", "value", "label", "title"] {
            if let text = props[key] as? String { return text }
        }
        return nil
    }
}
