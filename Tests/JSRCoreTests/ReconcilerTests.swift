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
}
