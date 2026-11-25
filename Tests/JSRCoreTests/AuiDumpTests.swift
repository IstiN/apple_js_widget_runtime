import Testing
import Foundation
@testable import JSRCore

// AUI dump normalization tests (plan 1.3 rules 1-7): the Swift port must match
// the pinned harness reference (harness/normalize.mjs + aliases.mjs).
@Suite struct AuiDumpTests {
    private static let helloInitial = """
    {"type":"center","child":{
      "type":"column","mainAxisSize":"min","spacing":12,"children":[
        {"type":"text","data":"Hello from JS!","style":{"fontSize":24,"fontWeight":"bold","color":"#f1f5f9"}},
        {"type":"sizedBox","height":12},
        {"type":"textButton","text":"Tap me","onTap":"tap"}]}}
    """

    @Test func styleMergesIntoPropsAndNodeKeysWin() throws {
        let tree = try AuiDump.normalizeTree(payloadJSON: Self.helloInitial)
        #expect(tree.type == "center")
        let column = tree.children[0]
        #expect(column.type == "column")
        #expect((column.props["mainAxisSize"] as? String) == "min")
        let text = column.children[0]
        #expect((text.props["fontSize"] as? NSNumber)?.intValue == 24) // rule 1: style merged
        #expect((text.props["fontWeight"] as? String) == "bold")
        #expect((text.props["color"] as? String) == "#F1F5F9") // rule 6: upper-case hex
    }

    @Test func buttonLabelAliasAndEventsMove() throws {
        let tree = try AuiDump.normalizeTree(payloadJSON: Self.helloInitial)
        let button = tree.children[0].children[2]
        #expect(button.type == "textButton")
        #expect((button.props["data"] as? String) == "Tap me") // aliasButtonLabel: text -> data
        #expect(button.props["text"] == nil)
        #expect(button.events["onTap"] == "tap") // rule 2
    }

    @Test func nodeIdsAreDepthFirstPreOrder() throws {
        let tree = try AuiDump.normalizeTree(payloadJSON: Self.helloInitial)
        #expect(tree.nodeId == "n0")
        #expect(tree.children[0].nodeId == "n1")
        #expect(tree.children[0].children[0].nodeId == "n2")
        #expect(tree.children[0].children[1].nodeId == "n3")
        #expect(tree.children[0].children[2].nodeId == "n4")
    }

    @Test func normalizationIsIdempotent() throws {
        let once = try AuiDump.normalizeTree(payloadJSON: Self.helloInitial)
        let twice = try AuiDump.normalizeTree(payloadJSON: JSON.stringify(once.jsonObject))
        let a = JSON.parse(JSON.stringify(once.jsonObject))
        let b = JSON.parse(JSON.stringify(twice.jsonObject))
        #expect(JSON.valuesEqual(a!, b!))
    }

    @Test func colorNormalization() {
        #expect((AuiDump.normalizeColor("#f1f5f9") as? String) == "#F1F5F9")
        #expect((AuiDump.normalizeColor("#abc") as? String) == "#AABBCC")
        #expect((AuiDump.normalizeColor("#abcd") as? String) == "#AABBCCDD")
        #expect((AuiDump.normalizeColor("rgb(255, 0, 10)") as? String) == "#FF000A")
        #expect((AuiDump.normalizeColor("rgba(1, 2, 3, 0.5)") as? String) == "#01020380")
        #expect((AuiDump.normalizeColor("not-a-color") as? String) == "not-a-color")
        #expect((AuiDump.normalizeColor(42) as? NSNumber)?.intValue == 42)
    }

    @Test func typeAliasesResolve() {
        #expect(AuiDump.resolveTypeAlias("View") == "column")
        #expect(AuiDump.resolveTypeAlias("Text") == "text")
        #expect(AuiDump.resolveTypeAlias("box") == "container")
        #expect(AuiDump.resolveTypeAlias("input") == "textField")
        #expect(AuiDump.resolveTypeAlias("TextInput") == "textField")
        #expect(AuiDump.resolveTypeAlias("model3d") == "scene3d")
        #expect(AuiDump.resolveTypeAlias("wobble") == "wobble") // unknown passes through
    }

    @Test func fieldAliasesMirrorTheReference() throws {
        let tree = try AuiDump.normalizeTree(payloadJSON: """
        {"type":"container","content":"hi","backgroundColor":"#ff0000",
         "items":[{"type":"input","placeholder":"name","value":"x","onChanged":"ch"},{"type":"svg","markup":"<svg/>"}]}
        """)
        let box = tree // the container is the root
        #expect(box.type == "container")
        let decoration = box.props["decoration"] as? [String: Any]
        #expect((decoration?["color"] as? String) == "#FF0000")
        #expect(box.props["backgroundColor"] == nil)
        #expect((box.props["data"] as? String) == "hi") // content -> data
        let item = box.children[0] // items -> children
        #expect(item.type == "textField") // alias + input canonicalization
        #expect((item.props["hint"] as? String) == "name") // placeholder -> hint
        #expect((item.props["initialValue"] as? String) == "x") // value -> initialValue
        #expect(item.events["onChange"] == "ch") // onChanged -> onChange
        let svg = box.children[1]
        #expect(svg.type == "svg")
        #expect((svg.props["data"] as? String) == "<svg/>") // markup -> data
    }

    @Test func imageSourceAliasesMoveUriAndSourceToUrl() throws {
        let tree = try AuiDump.normalizeTree(payloadJSON: """
        {"type":"image","uri":"http://x/1.png","items":[
          {"type":"img","source":"http://x/2.png"},
          {"type":"networkImage","url":"http://x/3.png"}]}
        """)
        #expect(tree.type == "image")
        #expect((tree.props["url"] as? String) == "http://x/1.png")
        #expect(tree.props["uri"] == nil)
        let second = tree.children[0]
        #expect(second.type == "image")
        #expect((second.props["url"] as? String) == "http://x/2.png")
        let third = tree.children[1]
        #expect((third.props["url"] as? String) == "http://x/3.png") // url kept, no alias applied
    }

    @Test func routingTagStripsAsStructuralAndIidStaysAProp() throws {
        // The canonical __tag merges `iid` into object payloads; normalize strips
        // `__iid` (structural) and keeps `iid` as a root prop — identical to the
        // harness derivation of the expected dump.
        let payload = "{\"type\":\"text\",\"__iid\":\"w1\",\"iid\":\"w1\",\"data\":\"x\"}"
        let tree = try AuiDump.normalizeTree(payloadJSON: payload)
        #expect(tree.props["__iid"] == nil)
        #expect((tree.props["iid"] as? String) == "w1")
    }

    @Test func rootWrapperAccepted() throws {
        let tree = try AuiDump.normalizeTree(payloadJSON: #"{"root":{"type":"text","data":"x"}}"#)
        #expect(tree.type == "text")
        #expect(tree.nodeId == "n0")
    }

    @Test func stringChildrenBecomeTextNodes() throws {
        let tree = try AuiDump.normalizeTree(payloadJSON: #"{"type":"column","children":["plain"]}"#)
        let child = tree.children[0]
        #expect(child.type == "text")
        #expect((child.props["data"] as? String) == "plain")
    }
}
