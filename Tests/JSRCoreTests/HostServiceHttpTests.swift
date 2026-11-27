import Foundation
import Testing
@testable import JSRCore

// URLSessionHttp: response shaping (status/parse branches) and a full fetch
// through a stubbed URLProtocol — no network.

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubProtocol.handler, let url = request.url else { return }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Blocking wait for the completion callback (serialized suite; URLProtocol
/// responses arrive on a session queue).
private func waitForCompletion(_ body: (@escaping (Any) -> Void) -> Void) -> Any? {
    let semaphore = DispatchSemaphore(value: 0)
    var payload: Any?
    body { payload = $0; semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 5)
    return payload
}

@Suite(.serialized) struct HostServiceHttpTests {
    @Test func shapeMapsErrorStatusAndParsesBody() {
        #expect((URLSessionHttp.shape(status: 404, data: Data("{}".utf8)) as? [String: Any])?["__error"] != nil)
        let ok = URLSessionHttp.shape(status: 200, data: Data(#"{"temp": 9}"#.utf8)) as? [String: Any]
        #expect((ok?["temp"] as? NSNumber)?.intValue == 9)
        #expect((URLSessionHttp.shape(status: 200, data: Data("not json".utf8)) as? [String: Any])?.isEmpty == true)
        #expect((URLSessionHttp.shape(status: 200, data: nil) as? [String: Any])?.isEmpty == true)
    }

    @Test func fetchResolvesInvalidUrlImmediately() {
        let http = URLSessionHttp()
        let payload = waitForCompletion { http.fetch(FetchRequest(url: "", method: "GET", headers: [:]), completion: $0) } // URL(string: "") is nil
        #expect(payload != nil) // synchronous, no session involved
        #expect((payload as? [String: Any])?["__error"] != nil)
    }

    @Test func fetchThroughStubbedProtocolParsesBodyAndSendsHeaders() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let http = URLSessionHttp(session: URLSession(configuration: config))
        var seenMethod: String?
        var seenToken: String?
        StubProtocol.handler = { request in
            seenMethod = request.httpMethod
            seenToken = request.value(forHTTPHeaderField: "X-Token")
            return (200, Data(#"{"ok": true}"#.utf8))
        }
        let payload = waitForCompletion { http.fetch(FetchRequest(url: "http://stub.local/data", method: "POST", headers: ["X-Token": "abc"]), completion: $0) }
        #expect(payload != nil)
        #expect(seenMethod == "POST")
        #expect(seenToken == "abc")
        #expect((payload as? [String: Any])?["ok"] as? Bool == true)
        StubProtocol.handler = nil
    }
}
