// The web-view drag benchmark on a Mac:
//   swiftc -O -parse-as-library main_mac.swift WebViewBench.swift -o webview_bench
//   ./webview_bench <dir with page.html, drag_bench.js and the three modules> [mode]
// mode: `drag` (the default: in page and host-driven, three runs each) or
// `limits` (cold start, calls, memory, a long paced run, memory again, kill
// and recover). The web view sits in a small window (WebKit throttles one
// that isn't in a window on screen); WINDOW=0 runs it with none.
import AppKit
import WebKit

@main
struct WebViewBenchMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments.dropFirst()
        let root = URL(fileURLWithPath: arguments.first ?? ".")
        let mode = arguments.dropFirst().first ?? "drag"
        let drags = Int(ProcessInfo.processInfo.environment["DRAGS"] ?? "") ?? 165
        Task { @MainActor in
            setvbuf(stdout, nil, _IONBF, 0)
            let say: (String) -> Void = { print($0) }
            let bench = WebViewBench(root: root)
            var window: NSWindow?
            if ProcessInfo.processInfo.environment["WINDOW"] != "0" {
                window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
                window!.contentView = bench.webView
                window!.orderFrontRegardless()
            }
            if mode == "limits" {
                do {
                    try await bench.coldStart(say: say)
                    bench.memory(say: say, label: "after the first frame")
                    try await bench.calls(say: say)
                    try await bench.longRun(drags: drags, paceMs: 1000.0 / 120, say: say)
                    bench.memory(say: say, label: "after the long run")
                    for _ in 1...3 { try await bench.killAndRecover(say: say) }
                } catch {
                    say("RESULT failed: \(error)")
                }
            } else {
                await bench.load()
                await bench.run(say: say)
            }
            window?.close()
            exit(0)
        }
        app.run()
    }
}
