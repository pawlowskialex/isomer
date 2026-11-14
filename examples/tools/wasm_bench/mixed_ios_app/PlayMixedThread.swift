// The mixed runtime on a thread of its own: the same engine as MixedEngine
// (WasmKit with the runtime's hot functions native, in the app's process),
// driven the way WebViewEngine drives the web view's: WasmFeatureRuntime's
// calls are posted to the engine's thread (an event's strings with it), the
// guest's loop (renders, Swift jobs, timers) runs there, and each frame is
// handed to the main thread for the renderer. What it isolates: the cost of
// running the guest on the main thread, against the cost of a second process.
import Foundation
@_spi(OnlyForCLI) import WasmKit
import WasmKitWASI
import IsomerWasmRuntime
import SwiftFFIWasmHost

/// A thread with a big stack (native code recurses on it) running posted
/// work in order.
final class EngineThread: Thread, @unchecked Sendable {
    private let condition = NSCondition()
    private var work: [() -> Void] = []

    override init() {
        super.init()
        stackSize = 64 << 20
        qualityOfService = .userInteractive
        name = "mixed-engine"
    }

    override func main() {
        while true {
            condition.lock()
            while work.isEmpty { condition.wait() }
            let next = work.removeFirst()
            condition.unlock()
            next()
        }
    }

    func post(_ item: @escaping () -> Void) {
        condition.lock()
        work.append(item)
        condition.signal()
        condition.unlock()
    }

    func post(afterMilliseconds ms: Int, _ item: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(max(0, ms))) { [self] in
            post(item)
        }
    }
}

/// The guest's side, on the engine thread only.
final class MixedThreadGuest: MixedLiveHost, @unchecked Sendable {
    let thread: EngineThread
    var host: WasmHostImports!
    private var b: Bridge!
    private var runtime: Instance!
    private var wasi: WASIBridgeToHost?
    private var jobs: [UInt32] = []
    private var drainQueued = false
    private var renderQueued = false
    private let clock = ContinuousClock()
    /// The engine thread's busy time per piece of work, for the stats.
    var busy: (Double) -> Void = { _ in }

    init(thread: EngineThread) { self.thread = thread }

    func setUp(feature: [UInt8], started: ContinuousClock.Instant, ready: @escaping @Sendable (Double, Double, String) -> Void) {
        let t = clock.now
        liveHost = self
        let routed = Set(String(decoding: Self.resource("routed.txt"), as: UTF8.self).split(separator: "\n").map(String.init))
        do {
            let made = try setUpMixed(runtime: Self.resource("runtime_named.wasm"), shim: Self.resource("shim.wasm"),
                                      slots: String(decoding: Self.resource("slots.txt"), as: UTF8.self), sides: [feature], routed: routed)
            b = made.bridge
            runtime = made.runtime
            wasi = made.wasi
            _ = b.call(MixedEngine.installExecutor, [.i32(0), .i32(0)], interpreted: runtime)
            ready(WebViewBench.ms(clock.now - started), WebViewBench.ms(clock.now - t), made.log.joined(separator: "; "))
        } catch {
            ready(-1, -1, "set-up failed: \(error)")
        }
    }

    private static func resource(_ name: String) -> [UInt8] {
        Array(try! Data(contentsOf: Bundle.main.url(forResource: name, withExtension: nil)!))
    }

    private func timed(_ work: () -> Void) {
        let t = clock.now
        work()
        busy(WebViewBench.ms(clock.now - t))
    }

    func call(_ name: String, _ args: [Value]) {
        guard b != nil, b.nativeExports[name] != nil || runtime.exports[function: name] != nil else { return }
        timed { _ = b.call(name, args, interpreted: runtime) }
    }

    func event(id: String, value: String) {
        guard b != nil else { return }
        timed {
            let idBytes = Array(id.utf8), valueBytes = Array(value.utf8)
            let idPtr = b.call("iso_hot_alloc", [.i32(UInt32(idBytes.count))], interpreted: runtime)[0].i32
            let valuePtr = b.call("iso_hot_alloc", [.i32(UInt32(max(valueBytes.count, 1)))], interpreted: runtime)[0].i32
            write(idPtr, idBytes)
            write(valuePtr, valueBytes)
            _ = b.call("iso_hot_event", [.i32(idPtr), .i32(UInt32(idBytes.count)), .i32(valuePtr), .i32(UInt32(valueBytes.count))], interpreted: runtime)
            _ = b.call("iso_hot_free", [.i32(idPtr)], interpreted: runtime)
            _ = b.call("iso_hot_free", [.i32(valuePtr)], interpreted: runtime)
            // As WasmFeatureRuntime.send: a frame after each event.
            _ = b.call("iso_hot_render_pending", [], interpreted: runtime)
        }
    }

    func configure(key: String, value: String) {
        guard b != nil else { return }
        let k = Array(key.utf8), v = Array(value.utf8)
        let kp = b.call("iso_hot_alloc", [.i32(UInt32(k.count))], interpreted: runtime)[0].i32
        let vp = b.call("iso_hot_alloc", [.i32(UInt32(v.count))], interpreted: runtime)[0].i32
        write(kp, k)
        write(vp, v)
        _ = b.call("iso_hot_configure", [.i32(kp), .i32(UInt32(k.count)), .i32(vp), .i32(UInt32(v.count))], interpreted: runtime)
        _ = b.call("iso_hot_free", [.i32(kp)], interpreted: runtime)
        _ = b.call("iso_hot_free", [.i32(vp)], interpreted: runtime)
    }

    private func write(_ ptr: UInt32, _ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        b.memory.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: bytes.count) { d in bytes.withUnsafeBytes { d.copyMemory(from: $0) } }
    }

    func render() {
        renderQueued = false
        guard b != nil else { return }
        timed { _ = b.call("iso_hot_render_pending", [], interpreted: runtime) }
    }

    // MixedLiveHost, on the engine thread.
    func renderTree(_ bytes: [UInt8]) {
        let host = self.host!
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                PlayStats.shared?.frameDelivered(bytes)
                host.onRenderTree(bytes)
            }
        }
    }
    /// At the display's next refresh (DisplayPacer), then on this thread.
    func scheduleRender() {
        guard !renderQueued else { return }
        renderQueued = true
        let thread = self.thread
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                DisplayPacer.shared.next { thread.post { [self] in render() } }
            }
        }
    }
    func log(_ message: String) {
        let host = self.host!
        DispatchQueue.main.async { host.onLog(message) }
    }
    func platformCommand(_ key: String, _ value: String) {
        let host = self.host!
        DispatchQueue.main.async { host.onPlatformCommand(key, value) }
    }
    /// Synchronous, as WasmKitRuntime's: the main thread answers while the
    /// guest waits (the main thread never waits on this thread).
    func hostValue(_ key: String) -> String? {
        let host = self.host!
        let t = clock.now
        let answer = DispatchQueue.main.sync { host.hostValue(key) }
        let ms = WebViewBench.ms(clock.now - t)
        DispatchQueue.main.async { MainActor.assumeIsolated { PlayStats.shared?.hostValue(ms) } }
        return answer
    }
    func taskEnqueue(_ job: UInt32) {
        jobs.append(job)
        guard !drainQueued else { return }
        drainQueued = true
        thread.post { [self] in drain() }
    }
    func taskEnqueueAfter(_ job: UInt32, milliseconds: Int32) {
        thread.post(afterMilliseconds: Int(milliseconds)) { [self] in
            jobs.append(job)
            drain()
        }
    }
    private func drain() {
        drainQueued = false
        var n = 0
        timed {
            while !jobs.isEmpty, n < 10_000 {
                n += 1
                _ = b.call("swift_ffi_task_run", [.i32(jobs.removeFirst())], interpreted: runtime)
            }
        }
        let ran = n
        DispatchQueue.main.async { MainActor.assumeIsolated { PlayStats.shared?.jobsRan(ran) } }
        render()
    }
}

@MainActor
final class MixedThreadEngine: WasmRuntime {
    private let thread = EngineThread()
    private let guest: MixedThreadGuest
    private var staged: [UInt32: [UInt8]] = [:]
    private var nextStage: UInt32 = 0x7000_0000
    private let clock = ContinuousClock()

    init() {
        guest = MixedThreadGuest(thread: thread)
        thread.start()
    }

    func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        guest.host = hostImports
        guest.busy = { ms in DispatchQueue.main.async { MainActor.assumeIsolated { PlayStats.shared?.engineThreadBusy(ms) } } }
        let started = PlayStats.shared?.started ?? ContinuousClock.now
        let guest = self.guest
        thread.post {
            guest.setUp(feature: wasm, started: started) { ready, setUp, note in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        PlayStats.shared?.coldStart["engineReady"] = ready
                        PlayStats.shared?.coldStart["engineSetUp"] = setUp
                        PlayStats.shared?.webProcessNote = note
                    }
                }
            }
        }
    }

    func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency]) {}

    private func post(_ work: @escaping @Sendable (MixedThreadGuest) -> Void) {
        let t = clock.now
        let guest = self.guest
        thread.post { work(guest) }
        PlayStats.shared?.engineCall(WebViewBench.ms(clock.now - t))
    }

    private func string(_ ptr: WasmScalar, _ len: WasmScalar) -> String {
        let bytes = staged[UInt32(bitPattern: ptr.i32Value)] ?? []
        return String(decoding: bytes.prefix(Int(len.i32Value)), as: UTF8.self)
    }

    private static func value(_ s: WasmScalar) -> Value {
        switch s {
        case .i32(let v): return .i32(UInt32(bitPattern: v))
        case .i64(let v): return .i64(UInt64(bitPattern: v))
        case .f32(let v): return .f32(v.bitPattern)
        case .f64(let v): return .f64(v.bitPattern)
        }
    }

    func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? {
        switch name {
        case "iso_hot_alloc":
            nextStage += 0x1_0000
            staged[nextStage] = []
            return .i32(Int32(bitPattern: nextStage))
        case "iso_hot_free":
            staged[UInt32(bitPattern: args[0].i32Value)] = nil
            return nil
        case "iso_hot_event":
            PlayStats.shared?.eventSent()
            let id = string(args[0], args[1]), value = string(args[2], args[3])
            post { $0.event(id: id, value: value) }
            return nil
        case "iso_hot_configure":
            let key = string(args[0], args[1]), value = string(args[2], args[3])
            post { $0.configure(key: key, value: value) }
            return nil
        case "iso_hot_pending_tasks":
            return .i32(0)
        default:
            let values = args.map(Self.value)
            post { $0.call(name, values) }
            return nil
        }
    }

    func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] { [] }
    func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) { staged[ptr] = bytes }
    func renderPending() { post { $0.scheduleRender() } }
}
