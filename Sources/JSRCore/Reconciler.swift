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
    /// `from` and `to` are indices into the child list AS THE OPERATIONS
    /// BEFORE THIS ONE HAVE LEFT IT — the list the mapper holds when it
    /// applies this op (remove at `from`, insert at `to`), NOT indices into
    /// the old child list. The reconciler simulates that list while emitting,
    /// so the whole sequence applied in order lands exactly on the new order.
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
        var retainedChildren: [WidgetNode] = []
        pairChildren(old, new, into: &operations, retained: &retainedChildren)
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

    /// Children: each new child is placed at its final index of the mapper's
    /// CURRENT child list. The reconciler simulates that list (`working`)
    /// while emitting — every move/insert/remove index is valid at its point
    /// of application, so a mapper that applies the operations in order
    /// (remove at `from`, insert at `to`, …) lands exactly on the new order.
    /// Multi-move reorders ([A,B,C] → [C,B,A]) and move+remove batches stay
    /// consistent (review 2026-11-26, finding 1). `retained` collects the
    /// reconciled children in the NEW order.
    private static func pairChildren(_ old: WidgetNode, _ new: WidgetNode, into operations: inout [PatchOperation], retained: inout [WidgetNode]) {
        var working: [(node: WidgetNode, consumed: Bool)] = old.children.map { ($0, false) }
        for newIndex in new.children.indices {
            place(new.children[newIndex], at: newIndex, working: &working,
                  parentNodeId: old.nodeId, into: &operations, retained: &retained)
        }
        removeLeftovers(working, parentNodeId: old.nodeId, into: &operations)
    }

    /// One new child at its final index: in place, moved, replaced, or inserted.
    private static func place(_ newChild: WidgetNode, at newIndex: Int, working: inout [(node: WidgetNode, consumed: Bool)], parentNodeId: String, into operations: inout [PatchOperation], retained: inout [WidgetNode]) {
        let newIdentity = identity(newChild)
        if matchInPlace(newChild, at: newIndex, identity: newIdentity, working: &working, into: &operations, retained: &retained) { return }
        if moveIntoPlace(newChild, at: newIndex, identity: newIdentity, working: &working, parentNodeId: parentNodeId, into: &operations, retained: &retained) { return }
        insertOrReplace(newChild, at: newIndex, working: &working, parentNodeId: parentNodeId, into: &operations, retained: &retained)
    }

    /// The child is already at its new position: consume it in place (no op).
    private static func matchInPlace(_ newChild: WidgetNode, at newIndex: Int, identity newIdentity: String, working: inout [(node: WidgetNode, consumed: Bool)], into operations: inout [PatchOperation], retained: inout [WidgetNode]) -> Bool {
        guard newIndex < working.count, !working[newIndex].consumed, identity(working[newIndex].node) == newIdentity else { return false }
        working[newIndex].consumed = true
        append(reconcileMapped(working[newIndex].node, newChild), into: &operations, retained: &retained)
        return true
    }

    /// First unconsumed child at or after `newIndex` with this identity moves
    /// to `newIndex`; `from` is the CURRENT list index (mapper index space).
    private static func moveIntoPlace(_ newChild: WidgetNode, at newIndex: Int, identity newIdentity: String, working: inout [(node: WidgetNode, consumed: Bool)], parentNodeId: String, into operations: inout [PatchOperation], retained: inout [WidgetNode]) -> Bool {
        guard let from = working.indices.first(where: { $0 >= newIndex && !working[$0].consumed && identity(working[$0].node) == newIdentity }) else { return false }
        working.insert(working.remove(at: from), at: newIndex)
        working[newIndex].consumed = true
        operations.append(.moveChild(parentNodeId: parentNodeId, from: from, to: newIndex))
        append(reconcileMapped(working[newIndex].node, newChild), into: &operations, retained: &retained)
        return true
    }

    /// The identity is gone from the new tree: the leftover at the slot is
    /// replaced in place; past the end the child is inserted.
    private static func insertOrReplace(_ newChild: WidgetNode, at newIndex: Int, working: inout [(node: WidgetNode, consumed: Bool)], parentNodeId: String, into operations: inout [PatchOperation], retained: inout [WidgetNode]) {
        if newIndex < working.count {
            operations.append(.replaceSubtree(nodeId: working[newIndex].node.nodeId, node: newChild))
            working[newIndex] = (newChild, true)
            retained.append(newChild) // fresh id: the mapper registers it
        } else {
            operations.append(.insertChild(parentNodeId: parentNodeId, index: newIndex, node: newChild))
            working.append((newChild, true))
            retained.append(newChild)
        }
    }

    /// Children the new tree does not contain, removed in descending CURRENT
    /// positions so each removal is valid after the ones before it.
    private static func removeLeftovers(_ working: [(node: WidgetNode, consumed: Bool)], parentNodeId: String, into operations: inout [PatchOperation]) {
        for index in working.indices.reversed() where !working[index].consumed {
            operations.append(.removeChild(parentNodeId: parentNodeId, index: index))
        }
    }

    private static func append(_ result: (operations: [PatchOperation], retained: WidgetNode), into operations: inout [PatchOperation], retained: inout [WidgetNode]) {
        operations.append(contentsOf: result.operations)
        retained.append(result.retained)
    }
}
