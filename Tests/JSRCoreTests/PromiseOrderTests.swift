import Testing
import Foundation
@testable import JSRCore

// Promise order: a promise resolves by evaluating the reference resolve global
// after the current job — the resolution must not land inside the dispatching
// sendMessage call.
@Suite struct PromiseOrderTests {
    @Test func fetchResolutionArrivesOnlyAfterTheCurrentJob() throws {
        let mock: [String: Any] = ["/p": ["status": 200, "body": ["ok": true]]]
        let host = try TestHost.make(services: HostServices(http: MockHttp(mock: mock)))
        try host.eval("""
        console.log('before');
        jsr.fetchJson('http://h/p').then(function(v){ console.log('after:' + v.ok); });
        console.log('during');
        """)
        // current synchronous job finished: 'before' and 'during' logged, no resolve yet
        #expect(host.recorder.consoleLines == ["before", "during"])
        host.registry.drain()
        #expect(host.recorder.consoleLines == ["before", "during", "after:true"])
    }

    @Test func resolutionOfChainedThenSettlesInOneDrain() throws {
        let mock: [String: Any] = ["/c": ["status": 200, "body": ["n": 2]]]
        let host = try TestHost.make(services: HostServices(http: MockHttp(mock: mock)))
        try host.eval("""
        jsr.fetchJson('http://h/c')
          .then(function(v){ return v.n * 10; })
          .then(function(n){ console.log('chain:' + n); });
        """)
        #expect(host.recorder.consoleLines.isEmpty)
        host.registry.drain()
        #expect(host.recorder.consoleLines == ["chain:20"])
    }

    @Test func errorValueShapeRejectsThePromise() throws {
        let host = try TestHost.make()
        try host.eval("jsr.hostCall('nope', {}).catch(function(e){ console.log('err:' + e.message); });")
        host.registry.drain()
        #expect(host.recorder.consoleLines == ["err:hostCall is not supported by this host"])
    }
}

// PROTOCOL v0.2 amendment A1: `submit` dispatches onSubmit ?? onSubmitted.
@Suite struct TreeDriverSubmitTests {
    @Test func submitDispatchesOnSubmitWithValue() throws {
        let host = try TestHost.make()
        try host.eval("""
        jsr.render({type: 'column', children: [{type: 'textField', value: 'typed', onSubmit: 'go'}]});
        jsr.onEvent(function(actionId, payload) {
          if (actionId === 'go') { jsr.setTitle('submitted:' + payload.value); }
        });
        """)
        let driver = TreeInteractionDriver(runtime: host.runtime, recorder: host.registry.recorder, registry: host.registry, engine: host.engine)
        #expect(driver.submit(node: "n1"))
        #expect(host.registry.recorder.title == "submitted:typed")
    }

    @Test func submitPrefersOnSubmitOverOnSubmitted() throws {
        let host = try TestHost.make()
        try host.eval("""
        jsr.render({type: 'textField', onSubmitted: 'legacy', onSubmit: 'modern'});
        jsr.onEvent(function(actionId) { jsr.setTitle('got:' + actionId); });
        """)
        let driver = TreeInteractionDriver(runtime: host.runtime, recorder: host.registry.recorder, registry: host.registry, engine: host.engine)
        #expect(driver.submit(node: "n0"))
        #expect(host.registry.recorder.title == "got:modern")
    }

    @Test func submitWithoutHandlersReturnsFalse() throws {
        let host = try TestHost.make()
        try host.eval("jsr.render({type: 'textField'});")
        let driver = TreeInteractionDriver(runtime: host.runtime, recorder: host.registry.recorder, registry: host.registry, engine: host.engine)
        #expect(!driver.submit(node: "n0"))
    }
}
