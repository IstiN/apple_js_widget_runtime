import Testing
import Foundation
@testable import JSRCore

// Timer tests: the scheduling point is the injectable ManualTimerDriver, so
// tests fire ticks by hand (no sleeping). Ticks evaluate the reference globals
// `__jsrInterval(id)` / `__jsrRaf(id, elapsed)` on the engine.
@Suite struct TimerTests {
    @Test func setTimeoutFiresOnceAndDropsTheTimer() throws {
        let host = try TestHost.make()
        try host.eval("setTimeout(function(){ jsr.setTitle('fired'); }, 50);")
        #expect(host.timers.pendingIds.count == 1)
        host.timers.fireAll()
        #expect(host.recorder.title == "fired")
        #expect(host.timers.pendingIds.isEmpty) // one-shot is dropped
    }

    @Test func setIntervalRepeatsUntilCleared() throws {
        let host = try TestHost.make()
        try host.eval("var __n = 0; var __iv = setInterval(function(){ __n++; jsr.setTitle('n' + __n); }, 100);")
        host.timers.fireAll()
        host.timers.fireAll()
        #expect(host.recorder.title == "n2")
        #expect(host.timers.pendingIds.count == 1) // still armed
        try host.eval("clearInterval(__iv);")
        #expect(host.timers.pendingIds.isEmpty)
    }

    @Test func clearTimeoutCancelsBeforeFire() throws {
        let host = try TestHost.make()
        try host.eval("var __t = setTimeout(function(){ jsr.setTitle('late'); }, 10); clearTimeout(__t);")
        host.timers.fireAll()
        #expect(host.recorder.title == nil)
    }

    @Test func requestAnimationFrameTicksOnceWithElapsed() throws {
        let host = try TestHost.make()
        try host.eval("requestAnimationFrame(function(elapsed){ jsr.setTitle('raf:' + elapsed); });")
        #expect(host.timers.pendingIds.count == 1)
        host.timers.fireAll()
        #expect(host.recorder.title?.hasPrefix("raf:") == true)
        #expect(host.timers.pendingIds.isEmpty) // one frame per request
    }

    @Test func cancelAnimationFrameDropsThePendingFrame() throws {
        let host = try TestHost.make()
        try host.eval("var __f = requestAnimationFrame(function(){ jsr.setTitle('frame'); }); cancelAnimationFrame(__f);")
        host.timers.fireAll()
        #expect(host.recorder.title == nil)
    }

    @Test func timerTickCanQueueAndDrainResolutions() throws {
        let mock: [String: Any] = ["/x": ["status": 200, "body": ["v": 7]]]
        let host = try TestHost.make(services: HostServices(http: MockHttp(mock: mock)))
        try host.eval("setTimeout(function(){ jsr.fetchJson('http://h/x').then(function(r){ console.log('tickfetch:' + r.v); }); }, 0);")
        host.timers.fireAll() // tick -> fetch queued -> evaluate drains it
        #expect(host.recorder.consoleLines.contains("tickfetch:7"))
    }
}
