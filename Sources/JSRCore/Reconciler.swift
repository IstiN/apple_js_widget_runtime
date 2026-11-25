import Foundation

// Reconciler: diff of the previous tree and the new tree gives patch
// operations (issue #2: patch, not rebuild). Node identity: the `key` prop
// first, then the same type at the same position. Platform-neutral — works on
// widget node trees (raw WidgetNode.parse trees: normalization removes the
// `key` prop, so identity is only visible before the dump); the AppKit/UIKit
// mappers apply the patches to views.

public enum PatchOperation {
    case updateProps(nodeId: String, props: [String: Any])
    case insertChild(parentNodeId: String, index: Int, node: WidgetNode)
    case removeChild(parentNodeId: String, index: Int)
    /// `from` is the index in the old child list, `to` the index in the new list.
    case moveChild(parentNodeId: String, from: Int, to: Int)
    case replaceSubtree(nodeId: String, node: WidgetNode)
}

public enum Reconciler {
    /// Identity of a node for reconciliation: `key` prop first, then the type.
    static func identity(_ node: WidgetNode) -> String {
        (node.props["key"] as? String) ?? node.type
    }

    public static func reconcile(_ old: WidgetNode, _ new: WidgetNode) -> [PatchOperation] {
        // identity mismatch at the root: the whole subtree is replaced
        guard identity(old) == identity(new) else {
            return [.replaceSubtree(nodeId: old.nodeId, node: new)]
        }
        var operations: [PatchOperation] = []
        reconcileChildren(old, new, into: &operations)
        return operations
    }

    /// Diffs two nodes of the same identity: props, then children.
    static func reconcileChildren(_ old: WidgetNode, _ new: WidgetNode, into operations: inout [PatchOperation]) {
        // props: compared by key; every change lands in one updateProps
        var changed: [String: Any] = [:]
        for (key, value) in new.props {
            guard let oldValue = old.props[key] else {
                changed[key] = value
                continue
            }
            if !JSON.valuesEqual(oldValue, value) { changed[key] = value }
        }
        for key in old.props.keys where new.props[key] == nil {
            changed[key] = NSNull() // removed prop
        }
        if old.events != new.events { changed["events"] = new.events }
        if !changed.isEmpty {
            operations.append(.updateProps(nodeId: old.nodeId, props: changed))
        }

        // children paired by identity: same position first, then elsewhere (move),
        // else the old child at the cursor is replaced, else inserted at the end
        var matchedOld = Set<Int>()
        var cursor = 0 // next old child expected at the same position
        for (newIndex, newChild) in new.children.enumerated() {
            let newIdentity = identity(newChild)
            if cursor < old.children.count, identity(old.children[cursor]) == newIdentity {
                matchedOld.insert(cursor)
                reconcileChildren(old.children[cursor], newChild, into: &operations)
                cursor += 1
                continue
            }
            var found: Int?
            for (oldIndex, oldChild) in old.children.enumerated()
            where !matchedOld.contains(oldIndex) && identity(oldChild) == newIdentity {
                found = oldIndex
                break
            }
            if let oldIndex = found {
                matchedOld.insert(oldIndex)
                operations.append(.moveChild(parentNodeId: old.nodeId, from: oldIndex, to: newIndex))
                reconcileChildren(old.children[oldIndex], newChild, into: &operations)
            } else if cursor < old.children.count {
                // the old child at the cursor is gone from the new tree: replace it
                matchedOld.insert(cursor)
                operations.append(.replaceSubtree(nodeId: old.children[cursor].nodeId, node: newChild))
                cursor += 1
            } else {
                operations.append(.insertChild(parentNodeId: old.nodeId, index: newIndex, node: newChild))
            }
        }
        // remaining unmatched old children are removed (descending index order)
        for index in old.children.indices.filter({ !matchedOld.contains($0) }).reversed() {
            operations.append(.removeChild(parentNodeId: old.nodeId, index: index))
        }
    }
}
