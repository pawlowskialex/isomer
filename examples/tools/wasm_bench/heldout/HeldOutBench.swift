// One recorded game of 2048 (tools/mixed/replay/make_game.swift's: 150
// seeded swipes at a person's pace) played as the drag events a host sends,
// paced to a 120 Hz display, against 2048 as a side module over a runtime
// module: in mixed mode with the native set named by HELDOUT_SET, or
// interpreted (HELDOUT_MODE=interpreted). Prints event-to-frame latency for
// the drag's `changed` events, its release and the animation frames after;
// with ISO_MIXED_COUNT=1, native code's calls into the interpreter. The last
// frame's hash says every run ended on the same board.

import CoreFoundation
import Foundation
import IsomerMixedRuntime
import IsomerWasmKitRuntime
import IsomerWasmRuntime
import XCTest

/// make_game.swift's swipes: direction and length, duration; then a wait.
struct Swipe {
    var dx: Double, dy: Double, duration: Double, wait: Double

    static func game(swipes: Int = 150, seed: UInt64 = 2048) -> [Swipe] {
        var state = seed
        func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        var game: [Swipe] = []
        for _ in 0..<swipes {
            let r = next()
            let (dx, dy): (Double, Double) = r < 0.35 ? (0, 1) : r < 0.6 ? (-1, 0) : r < 0.85 ? (1, 0) : (0, -1)
            let length = 90 + 50 * next()
            _ = next(); _ = next()  // the start point, which a drag's translation doesn't carry
            let duration = round2(0.12 + 0.1 * next())
            let wait = round2(0.3 + 0.35 * next())
            game.append(Swipe(dx: dx * length, dy: dy * length, duration: duration, wait: wait))
        }
        return game
    }
}

struct Samples {
    var values: [Double] = []
    mutating func add(_ ms: Double) { values.append(ms) }
    var summary: String {
        guard !values.isEmpty else { return "none" }
        let s = values.sorted()
        func p(_ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * q))] }
        let mean = s.reduce(0, +) / Double(s.count)
        return String(format: "n %d, mean %.3f ms, median %.3f, p90 %.3f, p99 %.3f, max %.3f, total %.0f ms",
                      s.count, mean, p(0.5), p(0.9), p(0.99), s.last!, s.reduce(0, +))
    }
}

@MainActor
final class HeldOutBench: XCTestCase {
    let environment = ProcessInfo.processInfo.environment

    func artifact(_ relative: String) throws -> [UInt8] {
        let dir = environment["TEST_SRCDIR"] ?? ""
        let workspace = environment["TEST_WORKSPACE"] ?? "_main"
        return [UInt8](try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(workspace)/tools/wasm_bench/heldout/\(relative)")))
    }

    func text(_ relative: String) throws -> String { String(decoding: try artifact(relative), as: UTF8.self) }

    func testPlayOneGame() throws {
        let set = environment["HELDOUT_SET"] ?? "storybook"
        let interpreted = environment["HELDOUT_MODE"] == "interpreted"
        let label = interpreted ? "interpreted" : "mixed, \(set) set"

        var lastFrame: [UInt8] = []
        var stream: [UInt8] = []
        var renderRequested = false
        let imports = WasmHostImports(
            onRenderTree: { lastFrame = $0; stream += $0 },
            onLog: { print("guest log: \($0)") },
            epochMillis: { Date().timeIntervalSince1970 * 1000 },
            onScheduleRender: { renderRequested = true })

        let runtime: any WasmRuntime
        var mixed: MixedWasmKitRuntime?
        let launchStart = Date()
        if interpreted {
            let wasmKit = WasmKitRuntime()
            try wasmKit.launch(wasm: try artifact("heldout_runtime.wasm"), hostImports: imports)
            try wasmKit.loadSideModule(wasm: try artifact("game2048_side.wasm"))
            runtime = wasmKit
        } else {
            let native = MixedNativePart(
                shim: try artifact("native_\(set)_generated/shim.wasm"),
                slots: try text("native_\(set)_generated/slots.txt"),
                routed: Set(try text("storybook_routed.txt").split(separator: "\n").map(String.init)))
            let m = MixedWasmKitRuntime(native: native)
            try m.launch(wasm: try artifact("heldout_runtime.wasm"), hostImports: imports)
            try m.loadSideModule(wasm: try artifact("game2048_side.wasm"))
            runtime = m
            mixed = m
        }

        // Runs the main thread's loop until the guest is idle (mixed: its
        // thread has nothing left; both: nothing on the main queue).
        func settle() {
            while true {
                let handled = CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource
                if !handled && (mixed?.isIdle ?? true) { return }
            }
        }
        func timed(_ body: () throws -> Void) rethrows -> Double {
            let t = DispatchTime.now().uptimeNanoseconds
            try body()
            settle()
            return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
        }
        // A 120 Hz display's ticks; between them the loop runs (timers).
        var tick = DispatchTime.now().uptimeNanoseconds
        func nextTick() {
            tick += 8_333_333
            while DispatchTime.now().uptimeNanoseconds < tick {
                CFRunLoopRunInMode(.defaultMode, 0.0005, true)
            }
        }

        _ = try runtime.call("iso_hot_start", [.f64(420), .f64(912)])
        _ = try runtime.call("iso_hot_render", [])
        settle()
        let firstFrameMs = Date().timeIntervalSince(launchStart) * 1000
        let dragID = try XCTUnwrap(Self.firstID(in: stream, suffix: ".drag"), "no drag gesture in the first frame")
        _ = mixed?.takeCrossings()

        func send(_ value: String) throws {
            let id = Array(dragID.utf8), v = Array(value.utf8)
            let idPointer = try runtime.call("iso_hot_alloc", [.i32(Int32(id.count))])?.u32Value ?? 0
            let valuePointer = try runtime.call("iso_hot_alloc", [.i32(Int32(v.count))])?.u32Value ?? 0
            runtime.writeBytes(idPointer, id)
            runtime.writeBytes(valuePointer, v)
            _ = try runtime.call("iso_hot_event", [
                .i32(Int32(bitPattern: idPointer)), .i32(Int32(id.count)),
                .i32(Int32(bitPattern: valuePointer)), .i32(Int32(v.count)),
            ])
            _ = try runtime.call("iso_hot_free", [.i32(Int32(bitPattern: idPointer))])
            _ = try runtime.call("iso_hot_free", [.i32(Int32(bitPattern: valuePointer))])
            _ = try runtime.call("iso_hot_render", [])
        }
        func frame() throws {
            renderRequested = false
            _ = try runtime.call("iso_hot_render", [])
        }

        var drag = Samples(), release = Samples(), animation = Samples()
        let playStart = Date()
        let swipes = Int(environment["HELDOUT_SWIPES"] ?? "") ?? 150
        for swipe in Swipe.game().prefix(swipes) {
            let steps = max(2, Int(swipe.duration * 120))
            for k in 1...steps {
                nextTick()
                let f = Double(k) / Double(steps)
                drag.add(try timed { try send("changed:\(Int(swipe.dx * f)),\(Int(swipe.dy * f))") })
            }
            nextTick()
            release.add(try timed { try send("ended:\(Int(swipe.dx)),\(Int(swipe.dy))") })
            let waitTicks = Int(swipe.wait * 120)
            for _ in 0..<waitTicks {
                nextTick()
                if renderRequested { animation.add(try timed { try frame() }) }
            }
        }
        let playSeconds = Date().timeIntervalSince(playStart)
        // Whatever is left (a last tile's animation), then the board.
        for _ in 0..<60 {
            nextTick()
            if renderRequested { try frame(); settle() }
        }

        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in lastFrame { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        var report = """
        [heldout] \(label)
        [heldout] launch to first frame: \(String(format: "%.0f", firstFrameMs)) ms; played in \(String(format: "%.1f", playSeconds)) s
        [heldout] drag changed → frame: \(drag.summary)
        [heldout] release → frame: \(release.summary)
        [heldout] animation frames: \(animation.summary)
        [heldout] busy: \(String(format: "%.0f", (drag.values + release.values + animation.values).reduce(0, +))) ms
        [heldout] last frame: \(lastFrame.count) bytes, hash \(String(hash, radix: 16))
        """
        if let mixed, ProcessInfo.processInfo.environment["ISO_MIXED_COUNT"] != nil {
            let c = mixed.takeCrossings()
            report += String(format: "\n[heldout] into the interpreter: runtime functions %d calls (%.0f ms, outermost), feature %d calls (%.0f ms), host %d",
                             c.runtimeCalls, Double(c.runtimeNanos) / 1e6, c.featureCalls, Double(c.featureNanos) / 1e6, c.hostCalls)
            let slots = c.runtimeSlots.sorted { $0.value > $1.value }
                .map { "\($0.value) slot \($0.key) \(c.runtimeSlotNanos[$0.key] ?? 0)" }.joined(separator: "\n")
            if let out = environment["TEST_UNDECLARED_OUTPUTS_DIR"] {
                try slots.write(toFile: "\(out)/crossings_\(set).txt", atomically: true, encoding: .utf8)
            }
        }
        print(report)
        if let out = environment["TEST_UNDECLARED_OUTPUTS_DIR"] {
            try report.write(toFile: "\(out)/report.txt", atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(release.values.count, swipes)
    }

    /// The first `<…>.drag` id in a frame's bytes (DragBench's).
    static func firstID(in bytes: [UInt8], suffix: String) -> String? {
        let s = Array(suffix.utf8)
        func ok(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || c == 46 || (c >= 97 && c <= 122) }
        var i = 0
        while i + s.count <= bytes.count {
            if Array(bytes[i..<(i + s.count)]) == s {
                var start = i
                while start > 0 && ok(bytes[start - 1]) { start -= 1 }
                var id = String(decoding: bytes[start..<(i + s.count)], as: UTF8.self)
                while id.hasPrefix(".") { id.removeFirst() }
                if !id.isEmpty { return id }
            }
            i += 1
        }
        return nil
    }
}
