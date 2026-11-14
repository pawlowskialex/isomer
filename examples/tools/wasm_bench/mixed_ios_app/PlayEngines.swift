// 2048 to play, its side module run two ways behind Isomer's own WasmView
// (the same native renderer, IsomerTreeView, either way), each a WasmRuntime:
//   MixedEngine    WasmKit in the app's process, the runtime's hot functions
//                  native (MixedBench.swift's bridge), on the main thread as
//                  WasmKitRuntime runs;
//   WebViewEngine  the web view's JavaScriptCore (tools/mixed/webview's
//                  game.js), the guest's loop in the page: events and calls
//                  go in asynchronously, frames come back as messages.
// PlayStats records what the person playing did and what it cost (latency
// from an event to its frame reaching the renderer, the main thread's time
// in the engine, the display's dropped frames, memory, CPU, energy proxies)
// into Documents/play-<engine>-<time>.json.
import Foundation
import QuartzCore
import SwiftUI
import UIKit
import WebKit
@_spi(OnlyForCLI) import WasmKit
import WasmKitWASI
import IsomerWasmKitRuntime
import IsomerWasmRuntime
import IsomerWasmView
import SwiftFFIWasmHost

enum PlayEngineKind: String, CaseIterable {
    case mixed, mixedThread = "mixed-thread", webview
    var title: String {
        switch self {
        case .mixed: return "Mixed (WasmKit + native)"
        case .mixedThread: return "Mixed, on its own thread"
        case .webview: return "Web view (JavaScriptCore)"
        }
    }
    var short: String {
        switch self {
        case .mixed: return "mixed"
        case .mixedThread: return "mixed thread"
        case .webview: return "web view"
        }
    }
}

// MARK: - Stats

@MainActor
final class PlayStats: ObservableObject {
    static var shared: PlayStats?

    let engine: PlayEngineKind
    let started = ContinuousClock.now
    let startedDate = Date()
    private let clock = ContinuousClock()
    var coldStart: [String: Double] = [:]
    private(set) var firstFrameMs: Double?

    // Event → the frame that follows it, handed to the renderer.
    private var pendingEvents: [ContinuousClock.Instant] = []
    private(set) var eventLatencies: [Double] = []
    private(set) var events = 0
    private(set) var frames = 0
    private(set) var frameBytes = 0
    /// Frames with no event before them: animations, tasks, timers.
    private(set) var unpromptedFrames = 0

    // The main thread's time inside the engine (MixedEngine: the guest runs
    // there; WebViewEngine: posting and receiving).
    private(set) var engineCallMs: [Double] = []
    private(set) var hostValues = 0
    private(set) var hostValueMs = 0.0
    private(set) var jobs = 0

    // The display: CADisplayLink's intervals against its target.
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private(set) var displayFrames = 0
    private(set) var hitches = 0
    private(set) var hitchMs = 0.0
    private(set) var interactiveDisplayFrames = 0
    private(set) var interactiveHitches = 0
    private var lastActivity = ContinuousClock.now

    // Memory, CPU, energy proxies.
    private(set) var memorySamples: [Double] = []
    private var sampler: Timer?
    private let cpuAtStart = PlayStats.cpuSeconds()
    private var batteryAtStart: Float = -1
    private var thermal: [String] = []
    var webProcessNote = ""
    var pageStats: [String: Any] = [:]
    private var saver: Timer?
    let file: URL

    init(engine: PlayEngineKind) {
        self.engine = engine
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("play-\(engine.rawValue)-\(stamp).json")
        PlayStats.shared = self
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryAtStart = UIDevice.current.batteryLevel
        noteThermal()
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        sampler = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        saver = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    private final class DisplayLinkTarget: NSObject {
        weak var stats: PlayStats?
        init(_ stats: PlayStats) { self.stats = stats }
        @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { stats?.tick(link) } }
    }

    private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else { return }
        let interval = link.timestamp - lastTimestamp
        let target = link.targetTimestamp - link.timestamp
        displayFrames += 1
        let interactive = clock.now - lastActivity < .milliseconds(500)
        if interactive { interactiveDisplayFrames += 1 }
        if interval > target * 1.5 {
            hitches += 1
            hitchMs += (interval - target) * 1000
            if interactive { interactiveHitches += 1 }
        }
    }

    private func noteThermal() {
        let state: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: state = "nominal"
        case .fair: state = "fair"
        case .serious: state = "serious"
        case .critical: state = "critical"
        @unknown default: state = "unknown"
        }
        if thermal.last.map({ !$0.hasSuffix(state) }) ?? true {
            thermal.append(String(format: "%.0fs %@", WebViewBench.ms(clock.now - started) / 1000, state))
        }
    }

    private func sample() {
        if let footprint = Footprint.ofSelf() { memorySamples.append(Double(footprint) / 1e6) }
        noteThermal()
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    func eventSent() {
        events += 1
        lastActivity = clock.now
        pendingEvents.append(clock.now)
    }

    /// The first frame (the self-test finds the board's drag id in it).
    private(set) var firstFrame: [UInt8] = []

    func frameDelivered(_ frame: [UInt8]) {
        let bytes = frame.count
        if firstFrame.isEmpty { firstFrame = frame }
        let now = clock.now
        lastActivity = now
        frames += 1
        frameBytes += bytes
        if firstFrameMs == nil { firstFrameMs = WebViewBench.ms(now - started) }
        if pendingEvents.isEmpty {
            unpromptedFrames += 1
        } else {
            for sent in pendingEvents { eventLatencies.append(WebViewBench.ms(now - sent)) }
            pendingEvents.removeAll()
        }
        objectWillChange.send()
    }

    func engineCall(_ ms: Double) { engineCallMs.append(ms) }
    /// MixedThreadEngine: the engine thread's time per piece of work.
    private(set) var engineThreadBusyMs: [Double] = []
    func engineThreadBusy(_ ms: Double) { engineThreadBusyMs.append(ms) }
    func hostValue(_ ms: Double) { hostValues += 1; hostValueMs += ms }
    func jobsRan(_ n: Int) { jobs += n }

    static func percentiles(_ values: [Double]) -> [String: Double] {
        guard !values.isEmpty else { return [:] }
        let s = values.sorted()
        func p(_ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * q))] }
        return ["count": Double(s.count), "mean": s.reduce(0, +) / Double(s.count), "p50": p(0.5), "p90": p(0.9),
                "p99": p(0.99), "max": s.last!, "over8_3": Double(s.filter { $0 > 1000.0 / 120 }.count),
                "over16_7": Double(s.filter { $0 > 1000.0 / 60 }.count)]
    }

    var summaryLine: String {
        let l = PlayStats.percentiles(eventLatencies)
        let mem = memorySamples.last ?? 0
        return String(format: "%@ · %d events · event→frame mean %.2f ms, p90 %.2f, max %.1f · dropped frames %d (%d while playing) · app %.0f MB",
                      engine.short, events, l["mean"] ?? 0, l["p90"] ?? 0, l["max"] ?? 0,
                      hitches, interactiveHitches, mem)
    }

    func save() {
        let elapsed = WebViewBench.ms(clock.now - started) / 1000
        let mainThread = PlayStats.percentiles(engineCallMs)
        var report: [String: Any] = [
            "engine": engine.rawValue,
            "device": "\(UIDevice.current.model) \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "started": ISO8601DateFormatter().string(from: startedDate),
            "seconds": elapsed,
            "coldStartMs": coldStart.merging(["firstFrameDelivered": firstFrameMs ?? -1]) { a, _ in a },
            "events": events,
            "frames": frames,
            "unpromptedFrames": unpromptedFrames,
            "frameBytes": frameBytes,
            "eventToFrameMs": PlayStats.percentiles(eventLatencies),
            "mainThreadInEngineMs": mainThread.merging(["total": engineCallMs.reduce(0, +)]) { a, _ in a },
            "hostValueCalls": ["count": Double(hostValues), "totalMs": hostValueMs],
            "swiftJobs": jobs,
            "display": ["frames": displayFrames, "dropped": hitches, "droppedMs": hitchMs,
                        "framesWhilePlaying": interactiveDisplayFrames, "droppedWhilePlaying": interactiveHitches],
            "appMemoryMB": ["last": memorySamples.last ?? 0, "peak": memorySamples.max() ?? 0,
                            "mean": memorySamples.isEmpty ? 0 : memorySamples.reduce(0, +) / Double(memorySamples.count)],
            "appCPUSeconds": PlayStats.cpuSeconds() - cpuAtStart,
            "battery": ["start": batteryAtStart, "now": UIDevice.current.batteryLevel],
            "thermal": thermal,
            "eventToFrameSamplesMs": eventLatencies.map { ($0 * 1000).rounded() / 1000 },
        ]
        if !engineThreadBusyMs.isEmpty {
            report["engineThreadBusyMs"] = PlayStats.percentiles(engineThreadBusyMs).merging(["total": engineThreadBusyMs.reduce(0, +)]) { a, _ in a }
        }
        if !webProcessNote.isEmpty { report["webProcess"] = webProcessNote }
        // COUNT=1 (MixedEngine): calls from native code into the interpreter
        // by table slot, as MixedCheck prints them, for split/grow_set.py.
        if engine == .mixed, let b = bridge, b.counting {
            let lines = b.counts.sorted { $0.value > $1.value }.map { "  \($0.value)  slot \($0.key)" }
            try? (lines.joined(separator: "\n") + "\n").write(to: file.deletingPathExtension().appendingPathExtension("crossings.txt"), atomically: true, encoding: .utf8)
        }
        if !pageStats.isEmpty { report["page"] = pageStats }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file)
        }
    }
}

// MARK: - Display pacing

/// A render the guest asks for (an animation's next frame) waits for the
/// display's next refresh, for every engine alike; an event's or a Swift
/// job's frame doesn't wait. Without it the engines off the main thread
/// rendered twice as many frames as the display shows.
@MainActor
final class DisplayPacer: NSObject {
    static let shared = DisplayPacer()
    private var link: CADisplayLink?
    private var waiting: [() -> Void] = []

    func next(_ work: @escaping () -> Void) {
        waiting.append(work)
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    @objc private func tick() {
        let due = waiting
        waiting = []
        for work in due { work() }
        if waiting.isEmpty { link?.isPaused = true }
    }
}

// MARK: - The bundle

/// The 2048 side module, packaged.
final class Game2048Provider: WasmBundleProvider {
    func initialBundle() -> WasmBundle? {
        guard let url = Bundle.main.url(forResource: "game2048_side.wasm", withExtension: nil),
              let data = try? Data(contentsOf: url) else { return nil }
        return WasmBundle(label: "2048", wasm: Array(data))
    }
    func bundleUpdates() -> AsyncStream<WasmBundle> { AsyncStream { $0.finish() } }
}

enum PlayEngineError: Error { case noExport(String) }

private func resourceBytes(_ name: String) -> [UInt8] {
    Array(try! Data(contentsOf: Bundle.main.url(forResource: name, withExtension: nil)!))
}

// MARK: - Mixed

@MainActor
final class MixedEngine: WasmRuntime, MixedLiveHost {
    static let installExecutor = "$s9IsomerFFI23swiftFFIInstallExecutoryyF"
    private var host: WasmHostImports!
    private var b: Bridge!
    private var runtime: Instance!
    private var wasi: WASIBridgeToHost?
    private var jobQueue: [UInt32] = []
    private var drainScheduled = false
    private let clock = ContinuousClock()
    private var depth = 0

    func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        host = hostImports
        liveHost = self
        let stats = PlayStats.shared
        let t = clock.now
        let routed = Set(String(decoding: resourceBytes("routed.txt"), as: UTF8.self).split(separator: "\n").map(String.init))
        let made = try setUpMixed(runtime: resourceBytes("runtime_named.wasm"), shim: resourceBytes("shim.wasm"),
                                  slots: String(decoding: resourceBytes("slots.txt"), as: UTF8.self), sides: [wasm], routed: routed)
        b = made.bridge
        runtime = made.runtime
        wasi = made.wasi
        // swift_ffi's executor, so the guest's Swift tasks reach the host's
        // job queue (a real host installs it through a dependency's register
        // export; without it no `Task` ever runs).
        // Its Swift signature is () -> (); on wasm it takes the context and
        // error registers too.
        _ = b.call(Self.installExecutor, [.i32(0), .i32(0)], interpreted: runtime)
        NSLog("[mixed-engine] executor installed (native copy: \(b.nativeExports[Self.installExecutor] != nil))")
        stats?.coldStart["engineReady"] = WebViewBench.ms(clock.now - (stats?.started ?? t))
        stats?.coldStart["engineSetUp"] = WebViewBench.ms(clock.now - t)
        stats?.webProcessNote = made.log.joined(separator: "; ")
    }

    func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency]) {}

    private static func value(_ s: WasmScalar) -> Value {
        switch s {
        case .i32(let v): return .i32(UInt32(bitPattern: v))
        case .i64(let v): return .i64(UInt64(bitPattern: v))
        case .f32(let v): return .f32(v.bitPattern)
        case .f64(let v): return .f64(v.bitPattern)
        }
    }

    private static func scalar(_ v: Value) -> WasmScalar? {
        switch v {
        case .i32(let x): return .i32(Int32(bitPattern: x))
        case .i64(let x): return .i64(Int64(bitPattern: x))
        case .f32(let x): return .f32(Float(bitPattern: x))
        case .f64(let x): return .f64(Double(bitPattern: x))
        default: return nil
        }
    }

    /// The main thread's time in the guest, outermost calls only.
    private func timed<T>(_ work: () throws -> T) rethrows -> T {
        depth += 1
        let t = clock.now
        defer {
            depth -= 1
            if depth == 0 { PlayStats.shared?.engineCall(WebViewBench.ms(clock.now - t)) }
        }
        return try work()
    }

    func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? {
        guard b.nativeExports[name] != nil || runtime.exports[function: name] != nil else { throw PlayEngineError.noExport(name) }
        if name == "iso_hot_event" { PlayStats.shared?.eventSent() }
        return try timed { b.call(name, args.map(Self.value), interpreted: runtime).first.flatMap(Self.scalar) }
    }

    func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] {
        guard len > 0 else { return [] }
        return b.memory.withUnsafeBufferPointer(offset: UInt(ptr), count: Int(len)) { Array($0) }
    }

    func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        b.memory.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: bytes.count) { d in bytes.withUnsafeBytes { d.copyMemory(from: $0) } }
    }

    func pumpGuestJobs() { runJobs() }

    func renderPending() {
        timed { _ = b.call("iso_hot_render_pending", [], interpreted: runtime) }
    }

    // MixedLiveHost: the guest's imports, on the main thread.
    func renderTree(_ bytes: [UInt8]) {
        PlayStats.shared?.frameDelivered(bytes)
        host.onRenderTree(bytes)
    }
    private var renderPaced = false
    func scheduleRender() {
        guard !renderPaced else { return }
        renderPaced = true
        DisplayPacer.shared.next { [weak self] in
            self?.renderPaced = false
            self?.host.onScheduleRender()
        }
    }
    func log(_ message: String) { host.onLog(message) }
    func platformCommand(_ key: String, _ value: String) { host.onPlatformCommand(key, value) }
    func hostValue(_ key: String) -> String? {
        let t = clock.now
        defer { PlayStats.shared?.hostValue(WebViewBench.ms(clock.now - t)) }
        return host.hostValue(key)
    }
    func taskEnqueue(_ job: UInt32) {
        jobQueue.append(job)
        scheduleDrain()
    }
    func taskEnqueueAfter(_ job: UInt32, milliseconds: Int32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, milliseconds)))) { [weak self] in
            self?.jobQueue.append(job)
            self?.runJobs()
        }
    }
    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.drainScheduled = false
            self?.runJobs()
        }
    }
    /// As SwiftFFIHostRuntime.runQueuedJobs, then a render (onJobsDrained).
    private func runJobs() {
        var n = 0
        timed {
            while !jobQueue.isEmpty, n < 10_000 {
                n += 1
                _ = b.call("swift_ffi_task_run", [.i32(jobQueue.removeFirst())], interpreted: runtime)
            }
        }
        PlayStats.shared?.jobsRan(n)
        renderPending()
    }
}

// MARK: - Web view

@MainActor
final class WebViewEngine: NSObject, WasmRuntime, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { NSLog("[webview-engine] didFail \(error)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { NSLog("[webview-engine] didFailProvisional \(error)") }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { NSLog("[webview-engine] didFinish") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { NSLog("[webview-engine] web process terminated") }

    private var host: WasmHostImports!
    private var feature: [UInt8] = []
    let webView: WKWebView
    private var booted = false
    private var queued: [(String, [String: Any])] = []
    /// iso_hot_alloc's buffers stay on this side: an event's strings go to
    /// the page with it.
    private var staged: [UInt32: [UInt8]] = [:]
    private var nextStage: UInt32 = 0x7000_0000
    private let clock = ContinuousClock()

    /// The one this launch made (the screen asks it for the page's counts).
    static weak var current: WebViewEngine?

    /// The scheme handler and message handlers, registered before the web
    /// view is made (it copies its configuration then); they forward here.
    @MainActor
    private final class Relay: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
        weak var engine: WebViewEngine?
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) { engine?.webView(webView, start: task) }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            engine?.userContentController(controller, didReceive: message)
        }
    }
    private let relay: Relay

    override init() {
        let relay = Relay()
        let configuration = WKWebViewConfiguration()
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.setURLSchemeHandler(relay, forURLScheme: "bench")
        for name in ["ready", "frame", "log", "platform", "wantsRender"] {
            configuration.userContentController.add(relay, name: name)
        }
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: configuration)
        self.relay = relay
        super.init()
        relay.engine = self
        webView.isUserInteractionEnabled = false
        WebViewEngine.current = self
    }

    func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        host = hostImports
        feature = wasm
        // On screen in the app's window, behind everything (WebKit throttles
        // a web view that isn't in a foreground window).
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.insertSubview(webView, at: 0)
        if let stats = PlayStats.shared {
            stats.webProcessNote = window == nil ? "no key window for the web view" : "in the key window"
        }
        webView.navigationDelegate = self
        NSLog("[webview-engine] launch, window \(window != nil)")
        webView.load(URLRequest(url: URL(string: "bench://app/game.html")!))
    }

    func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency]) {}

    // The page's files; the feature from launch; host values, synchronously.
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        let name = url.lastPathComponent
        let data: Data
        var type = "application/wasm"
        if name == "hostValue" {
            let t = clock.now
            let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value ?? ""
            let answer = host.hostValue(key)
            PlayStats.shared?.hostValue(WebViewBench.ms(clock.now - t))
            let response = HTTPURLResponse(url: url, statusCode: answer == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/plain", "Cross-Origin-Resource-Policy": "same-origin"])!
            task.didReceive(response)
            task.didReceive(Data((answer ?? "").utf8))
            task.didFinish()
            return
        } else if name == "feature.wasm" {
            data = Data(feature)
        } else if let url = Bundle.main.url(forResource: name, withExtension: nil), let file = try? Data(contentsOf: url) {
            data = file
            if name.hasSuffix(".html") { type = "text/html" } else if name.hasSuffix(".js") { type = "text/javascript" }
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type, "Content-Length": String(data.count),
            "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp",
            "Cross-Origin-Resource-Policy": "same-origin",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "wantsRender":
            // The page's guest asked for a frame: at the display's next refresh.
            DisplayPacer.shared.next { [weak self] in self?.send("game.render()") }
        case "ready":
            NSLog("[webview-engine] page ready")
            boot()
        case "frame":
            let t = clock.now
            guard let text = message.body as? String, let data = Data(base64Encoded: text) else { return }
            let bytes = Array(data)
            PlayStats.shared?.frameDelivered(bytes)
            host.onRenderTree(bytes)
            PlayStats.shared?.engineCall(WebViewBench.ms(clock.now - t))
        case "log":
            NSLog("[webview-engine] page: \(message.body)")
            host.onLog("\(message.body)")
        case "platform":
            if let pair = message.body as? [String], pair.count == 2 { host.onPlatformCommand(pair[0], pair[1]) }
        default:
            break
        }
    }

    private func boot() {
        let stats = PlayStats.shared
        let pageReady = stats.map { WebViewBench.ms(clock.now - $0.started) }
        webView.callAsyncJavaScript("return await game.boot()", arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            if case .success(let value) = result, let info = value as? [String: Any] {
                stats?.coldStart["pageReady"] = pageReady ?? -1
                stats?.coldStart["engineReady"] = stats.map { WebViewBench.ms(self.clock.now - $0.started) } ?? -1
                stats?.coldStart["compileAndInstantiateInPage"] = info["loadMs"] as? Double ?? -1
                NSLog("[webview-engine] booted: \(info)")
            } else if case .failure(let error) = result {
                NSLog("[webview-engine] boot failed: \(error)")
                self.host.onLog("boot failed: \(error)")
            }
            self.booted = true
            let pending = self.queued
            self.queued = []
            for (body, args) in pending { self.send(body, args) }
        }
    }

    /// In order, without waiting: callAsyncJavaScript's messages reach the
    /// page in the order they are sent.
    private func send(_ body: String, _ args: [String: Any] = [:]) {
        guard booted else { queued.append((body, args)); return }
        let t = clock.now
        webView.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result { NSLog("[webview-engine] \(body) failed: \(error)") }
        }
        PlayStats.shared?.engineCall(WebViewBench.ms(clock.now - t))
    }

    private func string(_ ptr: WasmScalar, _ len: WasmScalar) -> String {
        let bytes = staged[UInt32(bitPattern: ptr.i32Value)] ?? []
        return String(decoding: bytes.prefix(Int(len.i32Value)), as: UTF8.self)
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
            send("game.event(id, value)", ["id": string(args[0], args[1]), "value": string(args[2], args[3])])
            return nil
        case "iso_hot_configure":
            send("game.configure(key, value)", ["key": string(args[0], args[1]), "value": string(args[2], args[3])])
            return nil
        case "iso_hot_pending_tasks":
            return .i32(0)
        default:
            let numbers: [Double] = args.map {
                switch $0 {
                case .i32(let v): return Double(v)
                case .i64(let v): return Double(v)
                case .f32(let v): return Double(v)
                case .f64(let v): return v
                }
            }
            send("game.call(name, args)", ["name": name, "args": numbers])
            return nil
        }
    }

    func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] { [] }

    func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) { staged[ptr] = bytes }

    /// As the other engines': at the display's next refresh.
    private var renderPaced = false
    func renderPending() {
        guard !renderPaced else { return }
        renderPaced = true
        DisplayPacer.shared.next { [weak self] in
            self?.renderPaced = false
            self?.send("game.render()")
        }
    }

    /// The page's own counts, into the stats.
    func collectPageStats() {
        guard booted else { return }
        webView.callAsyncJavaScript("return game.stats()", arguments: [:], in: nil, in: .page) { result in
            if case .success(let value) = result, let page = value as? [String: Any] {
                PlayStats.shared?.pageStats = page
            }
        }
    }
}

// MARK: - The screen

struct PlayScreen: View {
    let engine: PlayEngineKind
    @StateObject private var stats: PlayStats
    @StateObject private var model: WasmViewModel

    init(engine: PlayEngineKind) {
        self.engine = engine
        // Made once, when SwiftUI first installs the screen (the stats
        // before the engine, which reports to them).
        _stats = StateObject(wrappedValue: PlayStats(engine: engine))
        _model = StateObject(wrappedValue: WasmViewModel(runtime: { _ in
            switch engine {
            case .mixed: return MixedEngine() as any WasmRuntime
            case .mixedThread: return MixedThreadEngine()
            case .webview: return WebViewEngine()
            }
        }))
    }

    var body: some View {
        VStack(spacing: 0) {
            WasmView(model: model, provider: Game2048Provider())
            Text(stats.summaryLine)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            WebViewEngine.current?.collectPageStats()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            stats.save()
        }
        .task {
            // `-play-selftest`: scripted drags through WasmView's own event
            // path (what a finger's DragGesture sends), to check an engine.
            guard ProcessInfo.processInfo.arguments.contains("-play-selftest") else { return }
            while stats.firstFrame.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(1))
            guard let id = DragBench.firstID(in: stats.firstFrame, suffix: ".drag") else {
                print("SELFTEST no drag id in the first frame (\(stats.firstFrame.count) bytes)")
                return
            }
            let directions = [(2, 0), (-2, 0), (0, 2), (0, -2)]
            for drag in 0..<12 {
                let (dx, dy) = directions[drag % 4]
                for step in 1...60 {
                    model.send(id: id, value: "changed:\(step * dx),\(step * dy)")
                    try? await Task.sleep(for: .milliseconds(8))
                }
                model.send(id: id, value: "ended:\(60 * dx),\(60 * dy)")
                try? await Task.sleep(for: .milliseconds(400))
            }
            try? await Task.sleep(for: .seconds(1))
            stats.save()
            print("SELFTEST " + stats.summaryLine + " · frames \(stats.frames) · jobs \(stats.jobs) · file \(stats.file.lastPathComponent)")
        }
    }
}

struct PlayChooser: View {
    @State private var chosen: PlayEngineKind?

    init() {
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-play"), i + 1 < ProcessInfo.processInfo.arguments.count {
            _chosen = State(initialValue: PlayEngineKind(rawValue: ProcessInfo.processInfo.arguments[i + 1]))
        }
    }

    var body: some View {
        if let chosen {
            PlayScreen(engine: chosen)
        } else {
            VStack(spacing: 24) {
                Text("2048 Lab").font(.largeTitle.bold())
                Text("The same 2048, drawn by the same native renderer; only the engine that runs it differs. Play one, then swipe the app away, reopen it and play the other. Each game's stats are saved as you play.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ForEach(PlayEngineKind.allCases, id: \.rawValue) { kind in
                    Button { chosen = kind } label: {
                        Text(kind.title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(32)
        }
    }
}
