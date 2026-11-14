// What an engine in the app's own process gives that a web view doesn't, and
// the reverse, measured on one launch per engine (launch argument
// `-limits webview|interpreted|mixed`, so each starts cold in a fresh
// process):
//   webview      WebViewBench.swift (tools/mixed/webview): cold start,
//                memory, a guest's synchronous calls into the app, the long
//                paced run, memory again, the web process killed three times;
//   interpreted  WasmKit: a guest's call into the app, then the 2048 side
//                module over the runtime: cold start, the long paced run,
//                memory;
//   mixed        the same in mixed mode.
// The long run: 100 drags, each render (60 `changed` events, the release,
// its animation's frames) paced at 120 Hz, every render a sample.
import Foundation
import SwiftUI
import UIKit
import WebKit
@_spi(OnlyForCLI) import WasmKit

let limitsMode: String? = {
    let arguments = ProcessInfo.processInfo.arguments
    guard let i = arguments.firstIndex(of: "-limits"), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}()

nonisolated(unsafe) var limitsStarted = ContinuousClock.now

enum LimitsBench {
    static let drags = 100
    static let paceMs = 1000.0 / 120

    /// page.html's LOOP: `run(n)` calls the import `env.f` n times.
    static let loop: [UInt8] = [
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x02, 0x09, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x66, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x07, 0x01, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x01,
        0x0a, 0x1a, 0x01, 0x18, 0x01, 0x01, 0x7f,
        0x03, 0x40, 0x20, 0x01, 0x10, 0x00, 0x21, 0x01, 0x20, 0x00, 0x41, 0x01, 0x6b, 0x22, 0x00, 0x0d, 0x00, 0x0b,
        0x20, 0x01, 0x0b,
    ]

    /// A guest's synchronous call into the app under WasmKit: a Swift closure.
    static func hostCalls(n: Int) throws -> String {
        let engine = Engine()
        let store = Store(engine: engine)
        var imports = Imports()
        imports.define(module: "env", name: "f", Function(store: store, type: FunctionType(parameters: [.i32], results: [.i32])) { _, args in
            [.i32(args[0].i32 &+ 1)]
        })
        let instance = try parseWasm(bytes: loop).instantiate(store: store, imports: imports)
        let run = instance.exports[function: "run"]!
        let clock = ContinuousClock()
        let t = clock.now
        let result = try run.invoke([.i32(UInt32(n))])
        let ms = WebViewBench.ms(clock.now - t)
        return String(format: "guest→app call, WasmKit host function: %.3f µs a call (%d calls in %.0f ms; result %@)", ms * 1000 / Double(n), n, ms, "\(result)")
    }

    /// DragBench.long: the first frame (timed from `limitsStarted`), then the
    /// long paced run.
    static func installLongRun(label: String) {
        DragBench.long = { call, write, stream, clearStream, takeWantsRender in
            let clock = ContinuousClock()
            _ = try call("iso_hot_start", [.f64(390.0.bitPattern), .f64(680.0.bitPattern)])
            _ = try call("iso_hot_render", [])
            let cold = WebViewBench.ms(clock.now - limitsStarted)
            guard let dragID = DragBench.firstID(in: stream(), suffix: ".drag") else { return "no drag id" }
            func send(_ value: String) throws {
                let id = Array(dragID.utf8), v = Array(value.utf8)
                let idPtr = try call("iso_hot_alloc", [.i32(UInt32(id.count))])[0].i32
                let vPtr = try call("iso_hot_alloc", [.i32(UInt32(max(v.count, 1)))])[0].i32
                write(idPtr, id)
                write(vPtr, v)
                _ = try call("iso_hot_event", [.i32(idPtr), .i32(UInt32(id.count)), .i32(vPtr), .i32(UInt32(v.count))])
                _ = try call("iso_hot_free", [.i32(idPtr)])
                _ = try call("iso_hot_free", [.i32(vPtr)])
            }
            var pacer = Pacer(intervalMs: paceMs)
            var samples: [Double] = []
            let directions = [(2, 0), (-2, 0), (0, 2), (0, -2)]
            for drag in 0..<drags {
                let (dx, dy) = directions[drag % 4]
                for step in 1...60 {
                    pacer.wait()
                    clearStream()
                    let t = clock.now
                    try send("changed:\(step * dx),\(step * dy)")
                    _ = try call("iso_hot_render", [])
                    samples.append(WebViewBench.ms(clock.now - t))
                }
                pacer.wait()
                _ = takeWantsRender()
                clearStream()
                var t = clock.now
                try send("ended:\(60 * dx),\(60 * dy)")
                _ = try call("iso_hot_render", [])
                samples.append(WebViewBench.ms(clock.now - t))
                var n = 1
                while takeWantsRender() && n < 40 {
                    pacer.wait()
                    clearStream()
                    t = clock.now
                    _ = try call("iso_hot_render", [])
                    samples.append(WebViewBench.ms(clock.now - t))
                    n += 1
                }
            }
            let memory = Footprint.ofSelf().map { String(format: "%.1f MB", Double($0) / 1e6) } ?? "?"
            return String(format: "cold start %.0f ms to the first frame (the modules already read) | memory after the run: app %@ | long run (paced %.1f ms): ", cold, memory, paceMs)
                + LongStats.line(samples, unit: "ms")
        }
    }

    static func runWasmKit(mode: String, say: (String) -> Void) {
        func resource(_ name: String) -> [UInt8] {
            Array(try! Data(contentsOf: Bundle.main.url(forResource: name, withExtension: nil)!))
        }
        let runtime = resource("runtime.wasm")
        let side = resource("game2048_side.wasm")
        say("RESULT memory, \(mode), before: app " + (Footprint.ofSelf().map { String(format: "%.1f MB", Double($0) / 1e6) } ?? "?"))
        installLongRun(label: mode)
        do {
            if mode == "interpreted" {
                say("RESULT " + (try hostCalls(n: 1_000_000)))
                limitsStarted = .now
                for line in try runInterpretedBench(main: runtime, sides: [side]) { say("RESULT \(mode): \(line)") }
            } else {
                let namedRuntime = resource("runtime_named.wasm")
                let shim = resource("shim.wasm")
                let slots = String(decoding: resource("slots.txt"), as: UTF8.self)
                let routed = Set(String(decoding: resource("routed.txt"), as: UTF8.self).split(separator: "\n").map(String.init))
                limitsStarted = .now
                for line in try runMixedBench(runtime: namedRuntime, shim: shim, slots: slots, sides: [side], routed: routed) {
                    say("RESULT \(mode): \(line)")
                }
            }
        } catch {
            say("RESULT \(mode) failed: \(error)")
        }
        say("RESULT done")
    }
}

@MainActor
final class LimitsRunner: ObservableObject {
    @Published var lines: [String] = ["limits (\(limitsMode ?? "?")): running…"]
    let bench: WebViewBench?
    private var started = false

    init() {
        // The web view made at launch, as an app would: its cold start
        // counts from here.
        bench = limitsMode == "webview" ? WebViewBench(root: Bundle.main.resourceURL!) : nil
    }

    func start() {
        guard !started, let mode = limitsMode else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outURL = docs.appendingPathComponent("bench_output.txt")
        try? FileManager.default.removeItem(at: outURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let out = try? FileHandle(forWritingTo: outURL)
        setvbuf(stdout, nil, _IONBF, 0)
        let emit: @Sendable (String) -> Void = { line in
            print(line)
            out?.write(Data((line + "\n").utf8))
            Task { @MainActor in self.lines.append(line) }
        }
        let device = UIDevice.current
        emit("RESULT device \(device.model) \(device.systemName) \(device.systemVersion); limits \(mode)")
        if let bench {
            Task {
                do {
                    try await bench.coldStart(say: emit)
                    bench.memory(say: emit, label: "after the first frame")
                    try await bench.calls(say: emit)
                    try await bench.longRun(drags: LimitsBench.drags, paceMs: LimitsBench.paceMs, say: emit)
                    bench.memory(say: emit, label: "after the long run")
                    for _ in 1...3 { try await bench.killAndRecover(say: emit) }
                } catch {
                    emit("RESULT failed: \(error)")
                }
                emit("RESULT done")
            }
        } else {
            let thread = Thread { LimitsBench.runWasmKit(mode: mode, say: emit) }
            thread.stackSize = 64 << 20
            thread.start()
        }
    }
}

struct LimitsView: View {
    @StateObject private var runner = LimitsRunner()

    var body: some View {
        ZStack {
            // On screen, in the app's window (WebKit throttles a web view
            // that isn't), behind the report.
            if let webView = runner.bench?.webView { WebViewHost(webView: webView) }
            ScrollView {
                Text(runner.lines.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(uiColor: .systemBackground))
        }
        .onAppear { runner.start() }
    }
}

struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
