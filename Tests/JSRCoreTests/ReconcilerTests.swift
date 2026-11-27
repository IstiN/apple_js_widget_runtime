import Testing
import Foundation
@testable import JSRCore

// Reconciler tests (issue #2): patch-not-rebuild; one updateProps for one
// counter tap; a child keeps its identity; identity = key prop first, then
// the same type at the same position. The reconciler runs on the RAW parsed
// trees (WidgetNode.parse) — normalization removes the `key` prop (rule 4),
// so key identity is only visible before the dump.
@Suite struct ReconcilerTests {
    private func tree(_ payload: String) -> WidgetNode {
        (try? WidgetNode.parse(payloadJSON: payload))!
    }

    private let counterBefore = """
    {"type":"center","child":{"type":"column","spacing":16,"children":[
      {"type":"text","data":"QuickJS counter"},
      {"type":"text","data":"0"},
      {"type":"row","children":[
        {"type":"textButton","text":"-1","onTap":"dec"},
        {"type":"textButton","text":"+1","onTap":"inc"},
        {"type":"textButton","text":"reset","onTap":"reset"}]},
      {"type":"text","data":"pererender"}]}}
    """

    private let counterAfterInc = """
    {"type":"center","child":{"type":"column","spacing":16,"children":[
      {"type":"text","data":"QuickJS counter"},
      {"type":"text","data":"1"},
      {"type":"row","children":[
        {"type":"textButton","text":"-1","onTap":"dec"},
        {"type":"textButton","text":"+1","onTap":"inc"},
        {"type":"textButton","text":"reset","onTap":"reset"}]},
      {"type":"text","data":"pererender"}]}}
    """

    @Test func counterTapProducesOneUpdateProps() {
        let operations = Reconciler.reconcile(tree(counterBefore), tree(counterAfterInc))
        guard operations.count == 1, case let .updateProps(nodeId, props) = operations[0] else {
            Issue.record("expected exactly one updateProps, got \(operations)")
            return
        }
        // center n0, column n1, "QuickJS counter" n2, the count text is n3
        #expect(nodeId == "n3")
        #expect((props["data"] as? String) == "1")
    }

    @Test func unchangedChildrenKeepIdentity() {
        // same structure, only the third child changes: siblings get no ops
        let old = tree(#"{"type":"column","children":[{"type":"text","data":"a"},{"type":"text","data":"b"},{"type":"text","data":"c"}]}"#)
        let new = tree(#"{"type":"column","children":[{"type":"text","data":"a"},{"type":"text","data":"b"},{"type":"text","data":"C"}]}"#)
        let operations = Reconciler.reconcile(old, new)
        guard operations.count == 1, case let .updateProps(nodeId, _) = operations[0] else {
            Issue.record("expected one updateProps, got \(operations)")
            return
        }
        #expect(nodeId == "n3") // only the changed child; a/b untouched
    }

    @Test func appendedChildIsAnInsert() {
        let old = tree(#"{"type":"column","children":[{"type":"text","data":"a"}]}"#)
        let new = tree(#"{"type":"column","children":[{"type":"text","data":"a"},{"type":"text","data":"b"}]}"#)
        let operations = Reconciler.reconcile(old, new)
        guard operations.count == 1, case let .insertChild(parent, index, node) = operations[0] else {
            Issue.record("expected one insertChild, got \(operations)")
            return
        }
        #expect(parent == "n0" && index == 1 && node.nodeId == "n2")
    }

    @Test func removedChildIsARemove() {
        let old = tree(#"{"type":"column","children":[{"type":"text","data":"a"},{"type":"text","data":"b"}]}"#)
        let new = tree(#"{"type":"column","children":[{"type":"text","data":"a"}]}"#)
        let operations = Reconciler.reconcile(old, new)
        guard operations.count == 1, case let .removeChild(parent, index) = operations[0] else {
            Issue.record("expected one removeChild, got \(operations)")
            return
        }
        #expect(parent == "n0" && index == 1)
    }

    @Test func keyedReorderProducesMove() {
        // Unkeyed same-type siblings at swapped positions reconcile as updates
        // (identity = same type at the same position); keyed nodes move.
        let old = tree("""
        {"type":"column","children":[
          {"type":"text","key":"a","data":"a"},{"type":"sizedBox","height":8},{"type":"text","key":"b","data":"b"}]}
        """)
        let new = tree("""
        {"type":"column","children":[
          {"type":"text","key":"b","data":"b"},{"type":"sizedBox","height":8},{"type":"text","key":"a","data":"a"}]}
        """)
        let operations = Reconciler.reconcile(old, new)
        #expect(operations.contains { op in
            if case .moveChild = op { return true }
            return false
        })
        #expect(operations.count == 2) // two moves, no rebuild
    }

    @Test func typeChangeAtSamePositionReplacesSubtree() {
        let old = tree(#"{"type":"column","children":[{"type":"text","data":"a"}]}"#)
        let new = tree(#"{"type":"column","children":[{"type":"textButton","data":"a","onTap":"go"}]}"#)
        let operations = Reconciler.reconcile(old, new)
        guard operations.count == 1, case let .replaceSubtree(nodeId, node) = operations[0] else {
            Issue.record("expected one replaceSubtree, got \(operations)")
            return
        }
        #expect(nodeId == "n1" && node.type == "textButton")
    }

    @Test func keyPropWinsOverTypeAtPosition() {
        let old = tree(#"{"type":"column","children":[{"type":"text","key":"hero","data":"a"},{"type":"text","data":"b"}]}"#)
        let new = tree(#"{"type":"column","children":[{"type":"text","key":"hero","data":"a"},{"type":"text","key":"extra","data":"b"}]}"#)
        let operations = Reconciler.reconcile(old, new)
        // "hero" keeps its identity (no ops); the keyed "extra" is not the old
        // unkeyed "b" — the position becomes a replaceSubtree, b does not survive
        guard operations.count == 1, case let .replaceSubtree(nodeId, node) = operations[0] else {
            Issue.record("expected one replaceSubtree, got \(operations)")
            return
        }
        #expect(nodeId == "n2" && node.props["key"] as? String == "extra")
    }

    @Test func changedPropsAndEventsLandInOneUpdate() {
        let old = tree(#"{"type":"textButton","text":"go","onTap":"a1"}"#)
        let new = tree(##"{"type":"textButton","text":"go","onTap":"a2","color":"#818CF8"}"##)
        let operations = Reconciler.reconcile(old, new)
        guard operations.count == 1, case let .updateProps(_, props) = operations[0] else {
            Issue.record("expected one updateProps, got \(operations)")
            return
        }
        #expect((props["onTap"] as? String) == "a2")
        #expect(props["events"] != nil || props["onTap"] != nil)
        #expect((props["color"] as? String) == "#818CF8")
    }

    @Test func eventsMapChangesRideOnTheUpdate() {
        let old = tree(#"{"type":"textButton","text":"go","events":{"onTap":"a1"}}"#)
        let new = tree(#"{"type":"textButton","text":"go","events":{"onTap":"a9"}}"#)
        let operations = Reconciler.reconcile(old, new)
        guard operations.count == 1, case let .updateProps(_, props) = operations[0] else {
            Issue.record("expected one updateProps, got \(operations)")
            return
        }
        #expect((props["events"] as? [String: String])?["onTap"] == "a9")
    }

    // MARK: multi-move reorder (review 2026-11-26, finding 1)

    /// Applies operations to a child-id list EXACTLY like the mappers do:
    /// remove at the index, insert at the index, replace swaps the id in
    /// place. The ops must therefore carry CURRENT-list indices.
    private func applyLikeMappers(_ operations: [PatchOperation], to ids: inout [String]) {
        for operation in operations {
            switch operation {
            case .moveChild(_, let from, let to):
                let id = ids.remove(at: from)
                ids.insert(id, at: min(to, ids.count))
            case .insertChild(_, let index, let node):
                ids.insert(node.nodeId, at: min(index, ids.count))
            case .removeChild(_, let index):
                ids.remove(at: index)
            case .replaceSubtree(let nodeId, let node):
                if let position = ids.firstIndex(of: nodeId) { ids[position] = node.nodeId }
            case .updateProps:
                break
            }
        }
    }

    private func keyedColumn(_ keys: [String]) -> WidgetNode {
        let children = keys.map { key in
            "{\"type\":\"text\",\"key\":\"\(key)\",\"data\":\"\(key)\"}"
        }.joined(separator: ",")
        return tree("{\"type\":\"column\",\"children\":[\(children)]}")
    }

    /// The reviewer's counterexample: [A,B,C] → [C,B,A] used to desync the
    /// index spaces and end [C,A,B]. Ops applied in mapper order must produce
    /// exactly the retained order (matched nodes keep their old ids), whose
    /// identity sequence is the new payload order.
    @Test func threeChildReverseEndsInTheNewOrder() {
        let old = keyedColumn(["a", "b", "c"])
        let new = keyedColumn(["c", "b", "a"])
        let result = Reconciler.reconcileMapped(old, new)
        let moves = result.operations.filter { if case .moveChild = $0 { return true }; return false }
        #expect(moves.count >= 2, "at least two moves in one diff, got \(result.operations)")
        var ids = old.children.map(\.nodeId)
        applyLikeMappers(result.operations, to: &ids)
        #expect(ids == result.retained.children.map(\.nodeId))
        #expect(result.retained.children.map(Reconciler.identity) == ["c", "b", "a"])
    }

    /// A longer reorder (4-child reversal) plus a move+remove batch: the
    /// simulated mapper list still lands on the new order.
    @Test func fourChildReverseAndMoveWithRemovalsStayConsistent() {
        let reverseOld = keyedColumn(["a", "b", "c", "d"])
        let reverseNew = keyedColumn(["d", "c", "b", "a"])
        let reverse = Reconciler.reconcileMapped(reverseOld, reverseNew)
        var ids = reverseOld.children.map(\.nodeId)
        applyLikeMappers(reverse.operations, to: &ids)
        #expect(ids == reverse.retained.children.map(\.nodeId))
        #expect(reverse.retained.children.map(Reconciler.identity) == ["d", "c", "b", "a"])

        // move the two survivors to the front, then remove the two leftovers
        let shrinkOld = keyedColumn(["a", "b", "c", "d"])
        let shrinkNew = keyedColumn(["c", "d"])
        let shrink = Reconciler.reconcileMapped(shrinkOld, shrinkNew)
        var shrinkIds = shrinkOld.children.map(\.nodeId)
        applyLikeMappers(shrink.operations, to: &shrinkIds)
        #expect(shrinkIds == shrink.retained.children.map(\.nodeId))
        #expect(shrink.retained.children.map(Reconciler.identity) == ["c", "d"])
    }
}
