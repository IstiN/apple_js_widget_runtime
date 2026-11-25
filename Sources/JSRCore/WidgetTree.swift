import Foundation

// Parsed jsr render tree (contract: js_widget_runtime docs/contract inventory).
public struct WidgetNode {
    public let type: String
    public let props: [String: Any]
    public private(set) var children: [WidgetNode]
    /// Stable id assigned in depth-first render order ("n0..nN") — feeds AUI dump nodeId.
    public let nodeId: String

    public init(type: String, props: [String: Any], children: [WidgetNode], nodeId: String) {
        self.type = type
        self.props = props
        self.children = children
        self.nodeId = nodeId
    }

    /// Parses the __jsr_render payload JSON into a tree, assigning nodeIds depth-first.
    public static func parse(payloadJSON: Data) throws -> WidgetNode {
        let obj = try JSONSerialization.jsonObject(with: payloadJSON, options: [.fragmentsAllowed])
        var counter = 0
        func walk(_ any: Any) throws -> WidgetNode {
            guard let dict = any as? [String: Any],
                  let type = dict["type"] as? String else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "node without 'type': \(any)"))
            }
            var node = WidgetNode(type: type, props: dict, children: [],
                                  nodeId: "n\(counter)")
            counter += 1
            if let arr = dict["children"] as? [Any] {
                node.children = try arr.map(walk)
            }
            return node
        }
        return try walk(obj)
    }
}
