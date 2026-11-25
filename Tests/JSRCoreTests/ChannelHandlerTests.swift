import Testing
import Foundation
@testable import JSRCore

// Channel handler tests: documented payload in, documented payload out,
// through the real bootstrap halves on JSC (PROTOCOL.md v0.1 semantics).
@Suite struct ChannelHandlerTests {
    @Test func storageRoundTripThroughRegistry() throws {
        // The reference caches writes in JS (`_c`), so the round trip through the
        // HOST store is proven with a fresh engine sharing the storage service.
        let storage = InMemoryStorage()
        let writer = try TestHost.make(services: HostServices(storage: storage))
        try writer.eval("jsr.storage.set('theme', 'dark');")
        writer.registry.drain()

        let reader = try TestHost.make(services: HostServices(storage: storage))
        try reader.eval("jsr.storage.get('theme').then(function(v){ console.log('got:' + v); });")
        reader.registry.drain()
        #expect(reader.recorder.consoleLines.contains("got:dark"))
        #expect(reader.recorder.trace.contains("storage_get"))

        // An uncached miss resolves null through the channel.
        try reader.eval("jsr.storage.get('missing').then(function(v){ console.log('miss:' + (v === null)); });")
        reader.registry.drain()
        #expect(reader.recorder.consoleLines.contains("miss:true"))
    }

    @Test func storageSetHasNoIdAndNoResponse() throws {
        let host = try TestHost.make()
        let before = host.recorder.trace.count
        try host.eval("jsr.storage.set('k', 'v');")
        // storage_set is fire-and-forget: nothing queued "after the current job"
        #expect(host.recorder.trace.count == before + 1)
        try host.eval("jsr.storage.get('k').then(function(v){ console.log('v=' + v); });")
        host.registry.drain()
        #expect(host.recorder.consoleLines.contains("v=v"))
    }

    @Test func fetchResolvesMockBody() throws {
        let mock: [String: Any] = ["/api": ["status": 200, "body": ["ok": 1]]]
        let host = try TestHost.make(services: HostServices(http: MockHttp(mock: mock)))
        try host.eval("jsr.fetchJson('http://127.0.0.1:1/api').then(function(v){ console.log('ok=' + v.ok); });")
        host.registry.drain()
        #expect(host.recorder.consoleLines.contains("ok=1"))
    }

    @Test func fetchRejectsWithHttpErrorStatus() throws {
        let mock: [String: Any] = ["/boom": ["status": 500, "body": [:]]]
        let host = try TestHost.make(services: HostServices(http: MockHttp(mock: mock)))
        try host.eval("jsr.fetchJson('http://127.0.0.1:1/boom').catch(function(e){ console.log('caught:' + e.message); });")
        host.registry.drain()
        #expect(host.recorder.consoleLines.contains("caught:HTTP 500"))
    }

    @Test func secretsGetSetResolve() throws {
        let host = try TestHost.make()
        try host.eval("jsr.secrets.set('token', 's3cret').then(function(ok){ console.log('set:' + ok); });")
        host.registry.drain()
        try host.eval("jsr.secrets.get('token').then(function(v){ console.log('secret=' + v); });")
        host.registry.drain()
        #expect(host.recorder.consoleLines.contains("set:true"))
        #expect(host.recorder.consoleLines.contains("secret=s3cret"))
    }

    @Test func unsupportedHostCallResolvesNamedError() throws {
        let host = try TestHost.make()
        try host.eval("jsr.hostCall('asr.record', {lang: 'en'}).catch(function(e){ console.log('caught:' + e.message); });")
        host.registry.drain()
        #expect(host.recorder.consoleLines.contains("caught:hostCall is not supported by this host"))
    }

    @Test func execRefusedByCapabilityByDefault() throws {
        let host = try TestHost.make()
        try host.eval("jsr.exec('ls -l').catch(function(e){ console.log('caught:' + e.message); });")
        host.registry.drain()
        #expect(host.recorder.consoleLines.contains("caught:exec is not permitted by this host"))
    }

    @Test func execRunsWhenAllowed() throws {
        let host = try TestHost.make(configuration: JSRConfiguration(allowsExec: true))
        try host.eval("jsr.exec('echo hello-apple').then(function(r){ console.log('out:' + r.stdout.trim()); });")
        // Process runs off-main; wait briefly for the completion
        let deadline = Date().addingTimeInterval(5)
        while !host.recorder.consoleLines.contains(where: { $0.hasPrefix("out:") }) && Date() < deadline {
            host.registry.drain()
            Thread.sleep(forTimeInterval: 0.05)
        }
        host.registry.drain()
        #expect(host.recorder.consoleLines.contains("out:hello-apple"))
    }

    @Test func openUrlEmptyUrlRejects() throws {
        let host = try TestHost.make()
        try host.eval("jsr.openUrl('').catch(function(e){ console.log('caught:' + e.message); });")
        host.registry.drain()
        #expect(host.recorder.consoleLines.contains("caught:openUrl: empty url"))
    }

    @Test func captureResolvesUnsupported() throws {
        let host = try TestHost.make()
        try host.eval("jsr.capture({format: 'png'}).catch(function(e){ console.log('caught:' + e.message); });")
        host.registry.drain()
        #expect(host.recorder.consoleLines.contains("caught:capture is not supported by this host"))
    }

    @Test func loadAssetResolvesFileContentAndNullOnMiss() throws {
        let dir = TestHost.fixturesDir() + "/hello"
        let host = try TestHost.make(services: HostServices(assets: FileAssetLoader(rootPath: dir)))
        try host.eval("jsr.loadAsset('meta.json').then(function(v){ console.log('has:' + (v.categories ? 'yes' : 'no')); });")
        host.registry.drain()
        try host.eval("jsr.loadAsset('../secrets.txt').then(function(v){ console.log('miss:' + (v === null)); });")
        host.registry.drain()
        #expect(host.recorder.consoleLines.contains("has:yes"))
        #expect(host.recorder.consoleLines.contains("miss:true"))
    }

    @Test func setTitleAndLogUnwrapRawPayloads() throws {
        let host = try TestHost.make()
        try host.eval("jsr.setTitle('Counter'); console.log('hello world'); console.warn('careful');")
        #expect(host.recorder.title == "Counter")
        #expect(host.recorder.consoleLines == ["hello world", "[W] careful"])
    }

    @Test func exportStateStoresSnapshot() throws {
        let host = try TestHost.make()
        try host.eval("jsr.exportState({count: 3});")
        let state = host.recorder.state as? [String: Any]
        #expect((state?["count"] as? NSNumber)?.intValue == 3)
    }

    @Test func extendedFireAndForgetLanesAreDropped() throws {
        let host = try TestHost.make()
        let before = host.recorder.trace.count
        try host.eval("__send('__jsr_scene3d_command', JSON.stringify({kind:'create', sceneId:'s1', payload:{}})); __send('__jsr_event_done', '{}');")
        #expect(host.recorder.trace.count == before + 2)
        host.registry.drain()
        // nothing resolved, nothing crashed
        #expect(host.recorder.consoleLines.isEmpty)
    }

    @Test func rawStringChannelsArriveTaggedAndUnwrap() throws {
        // clearInterval/cancelAnimationFrame wrap as {iid, id}; the title/log
        // lanes prove unwrapRaw against exactly-two-keys payloads.
        let host = try TestHost.make()
        try host.eval("var __t = setTimeout(function(){}, 10); clearTimeout(__t);")
        #expect(host.timers.pendingIds.isEmpty)
    }

    @Test func everyDocumentedChannelHasARegisteredHandler() {
        let registry = try? TestHost.make()
        let channels = [
            "__jsr_log", "__jsr_render", "__jsr_set_title", "__jsr_set_interval",
            "__jsr_clear_interval", "__jsr_raf", "__jsr_caf", "__jsr_fetch", "__jsr_exec",
            "__jsr_open_url", "__jsr_host_call", "__jsr_host_call_binary", "__jsr_capture",
            "__jsr_storage_get", "__jsr_storage_set", "__jsr_secrets_get", "__jsr_secrets_set",
            "__jsr_load_asset", "__jsr_export_state", "__jsr_scene3d_command", "__jsr_event_done",
        ]
        guard let registry else { Issue.record("host failed to boot"); return }
        for channel in channels {
            #expect(registry.registry.handler(for: channel) != nil, "missing handler for \(channel)")
        }
    }
}
