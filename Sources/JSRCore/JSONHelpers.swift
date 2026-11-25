import Foundation

// JSON plumbing shared by the channel handlers, the AUI dump and the runner.
// Values are the JSONSerialization object graph ([String: Any] / [Any] /
// NSNumber / String / NSNull), same as the harness reference (harness/host.mjs).

public enum JSON {
    /// Parses a JSON string; fragments (string/number/bool) allowed.
    public static func parse(_ payload: String) -> Any? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Serializes any JSON value to a string; returns "null" on failure.
    public static func stringify(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || isFragment(value) else { return "null" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    /// Object payloads arrive with the routing `iid` merged in (canonical `__tag`);
    /// the bridge strips the tag before handlers run (PROTOCOL.md 1/6).
    public static func parseTagged(_ payload: String) -> [String: Any]? {
        guard var object = parse(payload) as? [String: Any] else { return nil }
        object.removeValue(forKey: "iid")
        return object
    }

    /// Raw-payload channels arrive `{"iid","id"}`-wrapped: exactly those two
    /// string keys unwraps to the id; anything else comes through verbatim.
    public static func unwrapRaw(_ payload: String) -> String {
        guard let object = parse(payload) as? [String: Any],
              object.count == 2,
              let id = object["id"] as? String,
              object["iid"] is String else { return payload }
        return id
    }

    /// Deep equality over the JSON object graph (bools are not numbers).
    public static func valuesEqual(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case let (x as String, y as String):
            return x == y
        case let (x as Bool, y as Bool):
            return x == y
        case let (x as NSNumber, y as NSNumber):
            return !isBool(x) && !isBool(y) && x == y
        case let (x as [Any], y as [Any]):
            return x.count == y.count && zip(x, y).allSatisfy { valuesEqual($0, $1) }
        case let (x as [String: Any], y as [String: Any]):
            return x.count == y.count && x.allSatisfy { key, value in
                y[key] != nil && valuesEqual(value, y[key]!)
            }
        case (is NSNull, is NSNull):
            return true
        default:
            return false
        }
    }

    public static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    public static func isFragment(_ value: Any) -> Bool {
        value is String || value is NSNumber || value is Bool || value is NSNull
    }
}
