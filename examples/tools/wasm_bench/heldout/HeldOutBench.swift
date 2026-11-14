// Runs a feature as a side module over a runtime module and times each
// event to its frame, paced to a 120 Hz display (HELDOUT_FEATURE):
//   - game2048: one recorded game (tools/mixed/replay/make_game.swift's
//     seeded swipes, HELDOUT_SWIPES of them);
//   - storybook: every first-frame tap target (each story's page), its
//     frames, and drags on the drag targets it shows;
//   - corpus: tools/wasm_mixed_corpus's screens for HELDOUT_SECONDS, a
//     driver operating whatever each screen's frames show (taps, drags,
//     text, sliders, toggles and pickers, long presses, context menus).
// HELDOUT_MODE: mixed (with the native set HELDOUT_SET), interpreted, or
// profile (interpreted, each runtime function's calls and self time written
// to profile_<feature>.txt in the test's outputs). With ISO_MIXED_COUNT=1,
// mixed mode also counts native code's calls into the interpreter. The last
// frame's hash says whether runs ended the same.

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

    /// Interactive ids by kind (TreeEncoder's suffixes) a driver can send
    /// events to, with the values it sends.
    static let kinds = [".tap", ".drag", ".text", ".slider", ".host", ".longpress", ".ctx"]

    func testRun() throws {
        let feature = environment["HELDOUT_FEATURE"] ?? "game2048"
        let mode = environment["HELDOUT_MODE"] ?? "mixed"
        let set = environment["HELDOUT_SET"] ?? "storybook"
        let label = "\(feature), " + (mode == "mixed" ? "mixed, \(set) set" : mode)

        var lastFrame: [UInt8] = []
        var stream: [UInt8] = []
        var keepStream = true
        var renderRequested = false
        var frames = 0
        var onFrame: ([UInt8]) -> Void = { _ in }
        let imports = WasmHostImports(
            onRenderTree: { bytes in
                lastFrame = bytes
                frames += 1
                if ProcessInfo.processInfo.environment["HELDOUT_DEBUG"] != nil, frames < 6 {
                    print("[frame \(frames)] \(bytes.count) bytes: \(String(decoding: bytes.prefix(400).map { $0 >= 32 && $0 < 127 ? $0 : 46 }, as: UTF8.self))")
                }
                if keepStream { stream += bytes }
                onFrame(bytes)
            },
            onLog: { print("guest log: \($0)") },
            epochMillis: { Date().timeIntervalSince1970 * 1000 },
            onScheduleRender: { renderRequested = true })

        let runtime: any WasmRuntime
        var mixed: MixedWasmKitRuntime?
        var profile: WasmKitFunctionProfile?
        let launchStart = Date()
        let side = try artifact("\(feature)_side.wasm")
        if mode == "mixed" {
            let native = MixedNativePart(
                shim: try artifact("native_\(set)_generated/shim.wasm"),
                slots: try text("native_\(set)_generated/slots.txt"),
                routed: Set(try text("storybook_routed.txt").split(separator: "\n").map(String.init)))
            let m = MixedWasmKitRuntime(native: native)
            try m.launch(wasm: try artifact("heldout_runtime.wasm"), hostImports: imports)
            try m.loadSideModule(wasm: side)
            runtime = m
            mixed = m
        } else {
            let wasmKit = WasmKitRuntime()
            if mode == "profile" {
                profile = WasmKitFunctionProfile()
                wasmKit.profile = profile
            }
            try wasmKit.launch(wasm: try artifact("heldout_runtime.wasm"), hostImports: imports)
            try wasmKit.loadSideModule(wasm: side)
            runtime = wasmKit
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
            let now = DispatchTime.now().uptimeNanoseconds
            if now > tick + 100_000_000 { tick = now }  // far behind (profiling): don't hurry to catch up
            while DispatchTime.now().uptimeNanoseconds < tick {
                CFRunLoopRunInMode(.defaultMode, 0.0005, true)
            }
        }
        func send(_ id: String, _ value: String) throws {
            let idBytes = Array(id.utf8), v = Array(value.utf8)
            let idPointer = try runtime.call("iso_hot_alloc", [.i32(Int32(idBytes.count))])?.u32Value ?? 0
            let valuePointer = try runtime.call("iso_hot_alloc", [.i32(Int32(max(v.count, 1)))])?.u32Value ?? 0
            runtime.writeBytes(idPointer, idBytes)
            runtime.writeBytes(valuePointer, v)
            _ = try runtime.call("iso_hot_event", [
                .i32(Int32(bitPattern: idPointer)), .i32(Int32(idBytes.count)),
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

        // As a host injecting its dependencies does (WasmView's URLSession
        // hosts): registering one installs the guest's Swift executor, without
        // which no Task runs (2048's new tiles, the corpus's timers).
        _ = try runtime.call("swift_ffi_isomer_register_HTTPHost", [])
        settle()
        _ = try runtime.call("iso_hot_start", [.f64(420), .f64(912)])
        _ = try runtime.call("iso_hot_render", [])
        settle()
        let firstFrameMs = Date().timeIntervalSince(launchStart) * 1000
        _ = mixed?.takeCrossings()

        var events = Samples(), release = Samples(), animation = Samples()
        var detail = ""
        let playStart = Date()
        switch feature {
        case "game2048":
            let dragID = try XCTUnwrap(Self.ids(in: stream, suffix: ".drag").first, "no drag gesture in the first frame")
            let swipes = Int(environment["HELDOUT_SWIPES"] ?? "") ?? 150
            for swipe in Swipe.game().prefix(swipes) {
                let steps = max(2, Int(swipe.duration * 120))
                for k in 1...steps {
                    nextTick()
                    let f = Double(k) / Double(steps)
                    events.add(try timed { try send(dragID, "changed:\(Int(swipe.dx * f)),\(Int(swipe.dy * f))") })
                }
                nextTick()
                release.add(try timed { try send(dragID, "ended:\(Int(swipe.dx)),\(Int(swipe.dy))") })
                for _ in 0..<Int(swipe.wait * 120) {
                    nextTick()
                    if renderRequested { animation.add(try timed { try frame() }) }
                }
            }
            XCTAssertEqual(release.values.count, swipes)
        case "storybook":
            // Every first-frame tap target (each story's page), the frames
            // after it, and a drag on each drag target it shows.
            let taps = Self.ids(in: stream, suffix: ".tap")
            keepStream = false
            var pageStream: [UInt8] = []
            onFrame = { pageStream += $0 }
            for id in taps {
                pageStream = []
                nextTick()
                events.add(try timed { try send(id, "") })
                for _ in 0..<30 {
                    nextTick()
                    if renderRequested { animation.add(try timed { try frame() }) }
                }
                for drag in Self.ids(in: pageStream, suffix: ".drag").prefix(2) {
                    for k in 1...8 {
                        nextTick()
                        events.add(try timed { try send(drag, "changed:\(k * 6),\(k * 3)") })
                    }
                    release.add(try timed { try send(drag, "ended:48,24") })
                }
            }
            detail = "\(taps.count) taps"
            XCTAssertGreaterThan(taps.count, 50)
        default:
            // The corpus: each screen's interactive ids (from its frames), a
            // driver's event every third tick in turn; a drag is eight
            // `changed` and an `ended`.
            keepStream = false
            var pool: [String] = []
            var seen: Set<String> = []
            var screen = -1, screensSeen = 0
            let marker = Array("corpus-screen-".utf8)
            onFrame = { bytes in
                if let n = Self.number(after: marker, in: bytes), n != screen {
                    screen = n
                    screensSeen += 1
                    pool = []
                    seen = []
                }
                for kind in Self.kinds {
                    for id in Self.ids(in: bytes, suffix: kind) where seen.insert(id).inserted { pool.append(id) }
                }
            }
            onFrame(stream)
            let seconds = Double(environment["HELDOUT_SECONDS"] ?? "") ?? 205
            var n = 0, next = 0
            var dragging: (id: String, step: Int)?
            var byKind: [String: Int] = [:]
            while Date().timeIntervalSince(playStart) < seconds {
                nextTick()
                if renderRequested { animation.add(try timed { try frame() }) }
                n += 1
                guard n % 3 == 0 else { continue }
                if let d = dragging {
                    if d.step < 8 {
                        events.add(try timed { try send(d.id, "changed:\((d.step + 1) * 7),\((d.step + 1) * (n % 2 == 0 ? 3 : -3))") })
                        dragging = (d.id, d.step + 1)
                    } else {
                        release.add(try timed { try send(d.id, "ended:56,0") })
                        dragging = nil
                    }
                    continue
                }
                guard !pool.isEmpty else { continue }
                let id = pool[next % pool.count]
                next += 1
                let kind = Self.kinds.first { id.hasSuffix($0) } ?? ".tap"
                byKind[kind, default: 0] += 1
                switch kind {
                case ".drag": dragging = (id, 0)
                case ".text": events.add(try timed { try send(id, "typed \(n)") })
                case ".slider": events.add(try timed { try send(id, "0.\(n % 10)") })
                case ".host": events.add(try timed { try send(id, ["1", "0", "2", "1", "back"][next % 5]) })
                case ".longpress":
                    events.add(try timed { try send(id, "press:1") })
                    events.add(try timed { try send(id, "fire") })
                    events.add(try timed { try send(id, "press:0") })
                case ".ctx": events.add(try timed { try send(id, "0") })
                default: events.add(try timed { try send(id, "") })
                }
            }
            detail = "\(screensSeen) screens; events " + byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        let playSeconds = Date().timeIntervalSince(playStart)
        for _ in 0..<60 {
            nextTick()
            if renderRequested { try frame(); settle() }
        }

        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in lastFrame { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        var report = """
        [heldout] \(label) \(detail)
        [heldout] launch to first frame: \(String(format: "%.0f", firstFrameMs)) ms; played in \(String(format: "%.1f", playSeconds)) s; \(frames) frames
        [heldout] events → frame: \(events.summary)
        [heldout] release → frame: \(release.summary)
        [heldout] animation frames: \(animation.summary)
        [heldout] busy: \(String(format: "%.0f", (events.values + release.values + animation.values).reduce(0, +))) ms
        [heldout] last frame: \(lastFrame.count) bytes, hash \(String(hash, radix: 16))
        """
        let out = environment["TEST_UNDECLARED_OUTPUTS_DIR"]
        if let mixed, environment["ISO_MIXED_COUNT"] != nil {
            let c = mixed.takeCrossings()
            report += String(format: "\n[heldout] into the interpreter: runtime functions %d calls (%.0f ms, outermost), feature %d calls (%.0f ms), host %d",
                             c.runtimeCalls, Double(c.runtimeNanos) / 1e6, c.featureCalls, Double(c.featureNanos) / 1e6, c.hostCalls)
            let slots = c.runtimeSlots.sorted { $0.value > $1.value }
                .map { "\($0.value) slot \($0.key) \(c.runtimeSlotNanos[$0.key] ?? 0)" }.joined(separator: "\n")
            if let out { try slots.write(toFile: "\(out)/crossings_\(feature)_\(set).txt", atomically: true, encoding: .utf8) }
        }
        if let profile {
            let total = profile.selfNanos.reduce(0, +)
            report += String(format: "\n[heldout] profile: %d runtime functions called, %.0f ms in the runtime's own code, %.0f ms in other modules'",
                             profile.calls.filter { $0 > 0 }.count, Double(total) / 1e6, Double(profile.otherNanos) / 1e6)
            if let out { try profile.report().write(toFile: "\(out)/profile_\(feature).txt", atomically: true, encoding: .utf8) }
        }
        print(report)
        if let out { try report.write(toFile: "\(out)/report.txt", atomically: true, encoding: .utf8) }
    }

    /// The decimal number right after `marker` in a frame's bytes, if any.
    static func number(after marker: [UInt8], in bytes: [UInt8]) -> Int? {
        var i = 0
        while i + marker.count < bytes.count {
            if bytes[i] == marker[0], bytes[i..<(i + marker.count)].elementsEqual(marker) {
                var j = i + marker.count, value = 0, digits = 0
                while j < bytes.count, (48...57).contains(bytes[j]) {
                    value = value * 10 + Int(bytes[j] - 48)
                    j += 1
                    digits += 1
                }
                if digits > 0 { return value }
            }
            i += 1
        }
        return nil
    }

    /// Every distinct `<…><suffix>` id in a frame's bytes, in order.
    static func ids(in bytes: [UInt8], suffix: String) -> [String] {
        let s = Array(suffix.utf8)
        func ok(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || c == 46 || (c >= 97 && c <= 122) }
        var out: [String] = []
        var i = 0
        while i + s.count <= bytes.count {
            if bytes[i] == s[0], bytes[i..<(i + s.count)].elementsEqual(s), i + s.count == bytes.count || !ok(bytes[i + s.count]) {
                var start = i
                while start > 0 && ok(bytes[start - 1]) { start -= 1 }
                var id = String(decoding: bytes[start..<(i + s.count)], as: UTF8.self)
                while id.hasPrefix(".") { id.removeFirst() }
                if id.count > s.count, !out.contains(id) { out.append(id) }
            }
            i += 1
        }
        return out
    }
}
