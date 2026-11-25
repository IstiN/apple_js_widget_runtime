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
        node.identityKey ?? (node.props["key"] as? String) ?? node.type
    }

    public static func reconcile(_ old: WidgetNode, _ new: WidgetNode) -> [PatchOperation] {
        // identity mismatch at the root: the whole subtree is replaced
        guard identity(old) == identity(new) else {
            return [.replaceSubtree(nodeId: old.nodeId, node: new)]
        }
        return reconcileMapped(old, new).operations
    }

    /// Diffs two same-identity nodes and returns the patches PLUS the new tree
    /// re-id'd to the ids the applied views carry: matched nodes inherit the
    /// old id, inserted/replaced nodes keep their fresh id. View-backed mappers
    /// reconcile against `retained` next time — otherwise moves desync the
    /// payload id space from the view id space.
    public static func reconcileMapped(_ old: WidgetNode, _ new: WidgetNode) -> (operations: [PatchOperation], retained: WidgetNode) {
        guard identity(old) == identity(new) else {
            return ([.replaceSubtree(nodeId: old.nodeId, node: new)], new)
        }
        var operations: [PatchOperation] = []
        let changed = changedProps(from: old, to: new)
        if !changed.isEmpty {
            operations.append(.updateProps(nodeId: old.nodeId, props: changed))
        }
        var matchedOld = Set<Int>()
        var retainedChildren: [WidgetNode] = []
        pairChildren(old, new, into: &operations, matchedOld: &matchedOld, retained: &retainedChildren)
        removeUnmatchedChildren(old, matchedOld: matchedOld, into: &operations)
        return (operations, new.withChildren(retainedChildren).withNodeId(old.nodeId))
    }

    /// Props: compared by key; every change (including the events map) lands
    /// in one updateProps payload.
    private static func changedProps(from old: WidgetNode, to new: WidgetNode) -> [String: Any] {
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
        return changed
    }

    /// Children paired by identity: same position first, then elsewhere (move),
    /// else the old child at the cursor is replaced, else inserted at the end.
    /// `retained` collects the reconciled children in the NEW order.
    private static func pairChildren(_ old: WidgetNode, _ new: WidgetNode, into operations: inout [PatchOperation], matchedOld: inout Set<Int>, retained: inout [WidgetNode]) {
        var cursor = 0 // next old child expected at the same position
        for (newIndex, newChild) in new.children.enumerated() {
            let newIdentity = identity(newChild)
            if cursor < old.children.count, identity(old.children[cursor]) == newIdentity {
                matchedOld.insert(cursor)
                append(reconcileMapped(old.children[cursor], newChild), into: &operations, retained: &retained)
                cursor += 1
                continue
            }
            if let oldIndex = movedMatch(newIdentity, in: old.children, matched: matchedOld) {
                matchedOld.insert(oldIndex)
                operations.append(.moveChild(parentNodeId: old.nodeId, from: oldIndex, to: newIndex))
                append(reconcileMapped(old.children[oldIndex], newChild), into: &operations, retained: &retained)
            } else if cursor < old.children.count {
                // the old child at the cursor is gone from the new tree: replace it
                matchedOld.insert(cursor)
                operations.append(.replaceSubtree(nodeId: old.children[cursor].nodeId, node: newChild))
                retained.append(newChild) // fresh id: the mapper registers it
                cursor += 1
            } else {
                operations.append(.insertChild(parentNodeId: old.nodeId, index: newIndex, node: newChild))
                retained.append(newChild)
            }
        }
    }

    private static func append(_ result: (operations: [PatchOperation], retained: WidgetNode), into operations: inout [PatchOperation], retained: inout [WidgetNode]) {
        operations.append(contentsOf: result.operations)
        retained.append(result.retained)
    }

    /// Remaining unmatched old children are removed (descending index order).
    private static func removeUnmatchedChildren(_ old: WidgetNode, matchedOld: Set<Int>, into operations: inout [PatchOperation]) {
        for index in old.children.indices.filter({ !matchedOld.contains($0) }).reversed() {
            operations.append(.removeChild(parentNodeId: old.nodeId, index: index))
        }
    }

    /// First unmatched old child (outside the cursor) with this identity.
    private static func movedMatch(_ identity: String, in children: [WidgetNode], matched: Set<Int>) -> Int? {
        for (oldIndex, oldChild) in children.enumerated()
        where !matched.contains(oldIndex) && self.identity(oldChild) == identity {
            return oldIndex
        }
        return nil
    }
}
