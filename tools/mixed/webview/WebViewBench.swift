// The 2048 drag benchmark in a WKWebView (JavaScriptCore, with its JIT),
// and what a web view costs beyond the engine's speed:
//   in page:      the whole benchmark inside the page (drag_bench.js's
//                 dragBench): the engine alone;
//   host-driven:  the app sends each event to the page and gets its frame
//                 back (callAsyncJavaScript, the frame as base64), timed in
//                 the app: what an app whose wasm runs in a web view pays;
//   cold start:   from making the web view to the first frame (the web
//                 process launched, the page loaded, the modules compiled);
//   calls:        a guest's synchronous call into the app (a synchronous
//                 XHR to the scheme handler, `prompt` answered by the UI
//                 delegate), beside a JavaScript import, an awaited message
//                 with a reply, and the app's own round trip into the page;
//   long run:     10,000-odd renders paced at 120 Hz: the tail;
//   memory:       the app's footprint and the web process's;
//   kill:         the web process killed, the time until the guest draws
//                 again (its state gone).
// Shared by the Mac command (main_mac.swift) and the iPhone app
// (examples/tools/wasm_bench/mixed_ios_app, which links it).
import Foundation
import WebKit

@MainActor
final class WebViewBench: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
    let root: URL
    let reactor: String, runtime: String, side: String
    let created = ContinuousClock.now
    private(set) var webView: WKWebView!
    private var ready: CheckedContinuation<Void, Never>?
    private var terminated: CheckedContinuation<Void, Never>?
    private(set) var syncRequests = 0

    init(root: URL, reactor: String = "game2048_release.wasm", runtime: String = "runtime.wasm", side: String = "game2048_side.wasm") {
        self.root = root
        self.reactor = reactor
        self.runtime = runtime
        self.side = side
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(self, forURLScheme: "bench")
        configuration.userContentController.add(self, name: "ready")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "reply")
        // Not throttled when not frontmost (macOS 14, iOS 17).
        configuration.preferences.inactiveSchedulingPolicy = .none
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 200), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load() async {
        await withCheckedContinuation { continuation in
            ready = continuation
            webView.load(URLRequest(url: URL(string: "bench://app/page.html")!))
        }
    }

    // Files from `root`, cross-origin isolated; /sync answers a guest's
    // synchronous call.
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let name = task.request.url!.lastPathComponent
        let data: Data
        if name == "sync" {
            syncRequests += 1
            data = Data("1".utf8)
        } else if let file = try? Data(contentsOf: root.appendingPathComponent(name)) {
            data = file
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = name.hasSuffix(".html") ? "text/html" : name.hasSuffix(".js") ? "text/javascript" : name == "sync" ? "text/plain" : "application/wasm"
        let response = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type,
            "Content-Length": String(data.count),
            "Cross-Origin-Opener-Policy": "same-origin",
            "Cross-Origin-Embedder-Policy": "require-corp",
            "Cross-Origin-Resource-Policy": "same-origin",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        ready?.resume()
        ready = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        replyHandler(message.body, nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        completionHandler("1")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        terminated?.resume()
        terminated = nil
    }

    private func js(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
    }

    nonisolated static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func line(_ first: Double, _ samples: [Double], _ releases: [Double], _ frames: Int) -> String {
        let s = samples.sorted()
        let mean = s.reduce(0, +) / Double(s.count)
        return String(format: "first frame %.1f ms; event→frame (%d drag events): mean %.2f ms, median %.2f, p90 %.2f, max %.2f; release %.1f ms mean (%.1f frames)",
                      first, s.count, mean, s[s.count / 2], s[s.count * 9 / 10], s.last!,
                      releases.reduce(0, +) / Double(releases.count), Double(frames) / Double(releases.count))
    }

    func run(say: (String) -> Void) async {
        do {
            try await info(say: say)
            let configurations: [(String, String, [String])] = [
                ("self-contained reactor", reactor, []),
                ("side module", runtime, [side]),
            ]
            for (label, main, sides) in configurations {
                for run in 1...3 {
                    let r = try await js("return bench.inPage(main, sides)", ["main": main, "sides": sides]) as! [String: Any]
                    say(String(format: "RESULT in page, %@ #%d: load %.0f ms; %@", label, run, r["loadMs"] as! Double, r["line"] as! String))
                }
            }
            for (label, main, sides) in configurations {
                for run in 1...3 {
                    say("RESULT host-driven, \(label) #\(run): " + (try await hostDriven(main: main, sides: sides)))
                }
            }
        } catch {
            say("RESULT failed: \(error)")
        }
    }

    private func info(say: (String) -> Void) async throws {
        let info = try await js("return bench.info()") as? [String: Any] ?? [:]
        say("RESULT web view: crossOriginIsolated \(info["crossOriginIsolated"] ?? "?"); \(info["userAgent"] ?? "")")
        _ = try await js("return await bench.fetch(names)", ["names": [reactor, runtime, side]])
    }

    // DragBench's loop, each event a call into the page and its frame back.
    private func hostDriven(main: String, sides: [String]) async throws -> String {
        let clock = ContinuousClock()
        let t0 = clock.now
        let opened = try await js("return bench.open(main, sides)", ["main": main, "sides": sides]) as! [String: Any]
        let first = Self.ms(clock.now - t0)
        var samples: [Double] = [], engine: [Double] = [], releases: [Double] = [], frames = 0, bytes = 0
        let directions = [(2, 0), (-2, 0), (0, 2), (0, -2)]
        for drag in 0..<10 {
            let (dx, dy) = directions[drag % 4]
            for step in 1...60 {
                let t = clock.now
                let r = try await js("return bench.event(v)", ["v": "changed:\(step * dx),\(step * dy)"]) as! [String: Any]
                bytes += Data(base64Encoded: r["frame"] as! String)!.count
                samples.append(Self.ms(clock.now - t))
                engine.append(r["engineMs"] as! Double)
            }
            let t = clock.now
            var r = try await js("return bench.event(v)", ["v": "ended:\(60 * dx),\(60 * dy)"]) as! [String: Any]
            var n = 1
            while (r["wantsRender"] as? Bool ?? false) && n < 40 {
                r = try await js("return bench.frame()") as! [String: Any]
                n += 1
            }
            releases.append(Self.ms(clock.now - t))
            frames += n
        }
        let e = engine.sorted()
        return Self.line(first, samples, releases, frames)
            + String(format: " | load %.0f ms, first frame in page %.1f ms; engine's share of an event: mean %.2f ms, median %.2f; %d frame bytes",
                     opened["loadMs"] as! Double, opened["firstMs"] as! Double, e.reduce(0, +) / Double(e.count), e[e.count / 2], bytes)
    }

    // MARK: The limits

    /// From this bench's creation (the web view made) to the first frame of
    /// the side module over the runtime: the web process and page, the
    /// modules' transfer, their compilation and instantiation, the first
    /// render. Call first, on a fresh web view.
    func coldStart(say: (String) -> Void) async throws {
        let clock = ContinuousClock()
        await load()
        let pageReady = Self.ms(clock.now - created)
        let t = clock.now
        try await info(say: say)
        let fetched = Self.ms(clock.now - t)
        let t2 = clock.now
        let opened = try await js("return bench.open(main, sides)", ["main": runtime, "sides": [side]]) as! [String: Any]
        let open = Self.ms(clock.now - t2)
        say(String(format: "RESULT cold start, web view: %.0f ms to the first frame = page ready %.0f (web process, page, script) + modules in %.0f + compile and instantiate %.0f + first frame %.0f (the last two in page; %.0f with the call)",
                   Self.ms(clock.now - created), pageReady, fetched, opened["loadMs"] as! Double, opened["firstMs"] as! Double, open))
    }

    /// A guest's synchronous call into the app, each way there is, `n` calls
    /// from a wasm loop; and the app's own round trip into the page.
    func calls(say: (String) -> Void) async throws {
        for (kind, n) in [("js", 1_000_000), ("xhr", 1000), ("prompt", 1000)] {
            let before = syncRequests
            do {
                let r = try await js("return bench.calls(kind, n)", ["kind": kind, "n": n]) as! [String: Any]
                say(String(format: "RESULT guest→app call, %@: %.2f µs a call (%d calls in %.0f ms; result %@)%@",
                           kind, r["perCallUs"] as! Double, n, r["ms"] as! Double, "\(r["result"] ?? "?")",
                           kind == "xhr" ? " [\(syncRequests - before) reached the app]" : ""))
            } catch {
                say("RESULT guest→app call, \(kind): failed: \(error)")
            }
        }
        let r = try await js("return await bench.asyncCalls(n)", ["n": 1000]) as! [String: Any]
        say(String(format: "RESULT guest→app message with reply (awaited; wasm can't wait for it): %.1f µs a call (1000)", r["perCallUs"] as! Double))
        let clock = ContinuousClock()
        var round: [Double] = []
        for _ in 0..<1000 {
            let t = clock.now
            _ = try await js("return 1")
            round.append(Self.ms(clock.now - t) * 1000)
        }
        say("RESULT app→guest round trip (callAsyncJavaScript, empty): " + LongStats.line(round, unit: "µs"))
    }

    /// Host-driven drags of the side module, each render paced to `paceMs`
    /// (as a display's frames come), every render a sample.
    func longRun(drags: Int, paceMs: Double, say: (String) -> Void) async throws {
        _ = try await js("return bench.open(main, sides)", ["main": runtime, "sides": [side]])
        let clock = ContinuousClock()
        var pacer = Pacer(intervalMs: paceMs)
        var samples: [Double] = []
        let directions = [(2, 0), (-2, 0), (0, 2), (0, -2)]
        for drag in 0..<drags {
            let (dx, dy) = directions[drag % 4]
            for step in 1...60 {
                await pacer.waitAsync()
                let t = clock.now
                let r = try await js("return bench.event(v)", ["v": "changed:\(step * dx),\(step * dy)"]) as! [String: Any]
                _ = Data(base64Encoded: r["frame"] as! String)
                samples.append(Self.ms(clock.now - t))
            }
            await pacer.waitAsync()
            var t = clock.now
            var r = try await js("return bench.event(v)", ["v": "ended:\(60 * dx),\(60 * dy)"]) as! [String: Any]
            samples.append(Self.ms(clock.now - t))
            var n = 1
            while (r["wantsRender"] as? Bool ?? false) && n < 40 {
                await pacer.waitAsync()
                t = clock.now
                r = try await js("return bench.frame()") as! [String: Any]
                _ = Data(base64Encoded: r["frame"] as! String)
                samples.append(Self.ms(clock.now - t))
                n += 1
            }
        }
        say(String(format: "RESULT long run, web view (host-driven, paced %.1f ms): ", paceMs) + LongStats.line(samples, unit: "ms"))
    }

    var webProcessID: pid_t? {
        (webView.value(forKey: "_webProcessIdentifier") as? NSNumber).map { pid_t($0.int32Value) }
    }

    func memory(say: (String) -> Void, label: String) {
        var app = Footprint.ofSelf().map { String(format: "%.1f MB", Double($0) / 1e6) } ?? "?"
        if let peak = Footprint.peak(pid: getpid()) { app += String(format: " (peak %.1f MB)", Double(peak) / 1e6) }
        var web = "?"
        if let pid = webProcessID {
            web = Footprint.of(pid: pid).map { String(format: "%.1f MB", Double($0) / 1e6) } ?? "unreadable from the app (pid \(pid))"
            if let peak = Footprint.peak(pid: pid) { web += String(format: " (peak %.1f MB)", Double(peak) / 1e6) }
        }
        say("RESULT memory, web view, \(label): app \(app), web process \(web)")
    }

    /// Kills the web process (WebKit's own test hook), then reloads and
    /// redraws: the time until the guest draws again.
    func killAndRecover(say: (String) -> Void) async throws {
        // WebKit's test hook drops the web process as a crash or jetsam
        // would (the plain `_killWebContentProcess` leaves it running on a
        // Mac); the app finds out when its next call into the page fails.
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        guard webView.responds(to: kill) else {
            say("RESULT kill: WKWebView has no _killWebContentProcessAndResetState here")
            return
        }
        let clock = ContinuousClock()
        let t0 = clock.now
        let pid = webProcessID
        webView.perform(kill)
        var gone = false
        for _ in 0..<500 {
            if webProcessID == 0 { gone = true; break }
            do { _ = try await js("return 1") } catch { gone = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let noticed = Self.ms(clock.now - t0)
        say("RESULT kill: web process \(pid.map(String.init) ?? "?") dropped; \(gone ? "the app saw it" : "calls still answered after 0.5 s")")
        let t1 = clock.now
        await load()
        let pageReady = Self.ms(clock.now - t1)
        let t2 = clock.now
        _ = try await js("return await bench.fetch(names)", ["names": [reactor, runtime, side]])
        let fetched = Self.ms(clock.now - t2)
        let opened = try await js("return bench.open(main, sides)", ["main": runtime, "sides": [side]]) as! [String: Any]
        say(String(format: "RESULT kill and recover: drawing again %.0f ms after the kill = noticed %.0f + page ready %.0f + modules in %.0f + compile and instantiate %.0f + first frame %.0f; the guest's state (the board, the score) starts over",
                   Self.ms(clock.now - t0), noticed, pageReady, fetched, opened["loadMs"] as! Double, opened["firstMs"] as! Double))
    }
}

/// Waits for the next tick of a display-like clock; a late caller starts the
/// ticks again from now instead of catching up.
struct Pacer {
    let interval: Duration
    var next = ContinuousClock.now
    init(intervalMs: Double) { interval = .microseconds(Int64(intervalMs * 1000)) }

    mutating func wait() {
        let now = ContinuousClock.now
        if next > now { Thread.sleep(forTimeInterval: WebViewBench.ms(next - now) / 1000) }
        next = max(next, now) + interval
    }

    mutating func waitAsync() async {
        let now = ContinuousClock.now
        if next > now { try? await Task.sleep(until: next, tolerance: .microseconds(200), clock: .continuous) }
        next = max(next, now) + interval
    }
}

enum LongStats {
    /// Count, mean, percentiles, max; and, in ms, how many missed a 120 Hz
    /// and a 60 Hz frame.
    static func line(_ samples: [Double], unit: String) -> String {
        let s = samples.sorted()
        func p(_ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * q))] }
        var out = String(format: "%d samples: mean %.2f %@, median %.2f, p90 %.2f, p99 %.2f, p99.9 %.2f, max %.2f",
                         s.count, s.reduce(0, +) / Double(s.count), unit, p(0.5), p(0.9), p(0.99), p(0.999), s.last!)
        if unit == "ms" {
            out += String(format: "; over 8.3 ms (a 120 Hz frame): %d, over 16.7 ms: %d",
                          s.filter { $0 > 1000.0 / 120 }.count, s.filter { $0 > 1000.0 / 60 }.count)
        }
        return out
    }
}

enum Footprint {
    static func ofSelf() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// Another process's footprint, by proc_pid_rusage (looked up at run
    /// time: the iOS SDK doesn't declare it); nil where the sandbox refuses.
    static func of(pid: pid_t) -> UInt64? {
        typealias Rusage = @convention(c) (Int32, Int32, UnsafeMutableRawPointer) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage") else { return nil }
        let rusage = unsafeBitCast(symbol, to: Rusage.self)
        var usage = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &usage) { rusage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer($0)) }
        return r == 0 ? usage.ri_phys_footprint : nil
    }

    /// The most a process's footprint has been (proc_pid_rusage's lifetime
    /// maximum); nil where the sandbox refuses.
    static func peak(pid: pid_t) -> UInt64? {
        typealias Rusage = @convention(c) (Int32, Int32, UnsafeMutableRawPointer) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage") else { return nil }
        let rusage = unsafeBitCast(symbol, to: Rusage.self)
        var usage = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &usage) { rusage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer($0)) }
        return r == 0 ? usage.ri_lifetime_max_phys_footprint : nil
    }
}
