// Mixed mode when it isn't the first engine in its process, on a phone.
// WasmKit reserves 4 GiB and more of address space per memory (guard pages);
// an iPhone grants a process only a few such reservations. A mixed runtime
// whose reservation is refused gets a memory that moves as it grows, which
// native code without bounds checks can't run on: MixedWasmKitRuntime then
// runs the guest interpreted (`isNative` false) instead of faulting.
//
// One phase a launch (`-phase <name>`; MixedWasmKitRuntime is once a process):
//   reserve  how many reservations the process gets (1-page memories kept)
//   after    two interpreted runtimes running 2048 kept alive, then mixed
//   full     every reservation taken (and kept), then mixed
//   release  every reservation taken and given back, then mixed
// Each mixed phase then drags 2048's board (10 drags of 20 events, a frame
// after each) and reports. RESULT lines go to the console and to
// Documents/probe-<phase>.txt.

import CoreFoundation
import Foundation
import IsomerMixedRuntime
import IsomerWasmKitRuntime
import IsomerWasmRuntime
import SwiftUI
@_spi(OnlyForCLI) import WasmKit

@main
struct ProbeApp: App {
    @State private var lines: [String] = ["running…"]
    var body: some Scene {
        WindowGroup {
            ScrollView { Text(lines.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).padding() }
                .onAppear {
                    // A run-loop block, not the main queue: the probe waits
                    // for the guest by running the loop, and the main queue
                    // (where the guest's calls into the host arrive) can't
                    // run from inside one of its own blocks.
                    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
                        MainActor.assumeIsolated { lines = Probe.run() }
                    }
                    CFRunLoopWakeUp(CFRunLoopGetMain())
                }
        }
    }
}

@MainActor
enum Probe {
    static var output: [String] = []
    static func result(_ line: String) {
        print("RESULT \(line)")
        output.append(line)
    }

    static func resource(_ name: String) -> [UInt8] {
        Array(try! Data(contentsOf: Bundle.main.url(forResource: name, withExtension: nil)!))
    }

    /// A module with a one-page memory, exported.
    static let tinyModule: [UInt8] = [
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01,
        0x07, 0x0A, 0x01, 0x06, 0x6D, 0x65, 0x6D, 0x6F, 0x72, 0x79, 0x02, 0x00,
    ]

    /// Memories reserved with guard pages, kept: until one is refused.
    static var granted = 0
    static func reserveAll(limit: Int = 256) -> [AnyObject] {
        var kept: [AnyObject] = []
        granted = 0
        let module = try! parseWasm(bytes: tinyModule)
        for _ in 0..<limit {
            let engine = Engine(configuration: EngineConfiguration(memoryBoundsChecking: .mprotect))
            let store = Store(engine: engine)
            guard let instance = try? module.instantiate(store: store),
                  let memory = instance.exports[memory: "memory"] else { break }
            kept.append(store)
            if !memory.unsafeBaseAddress.stable { break }
            granted += 1
        }
        return kept
    }

    static func run() -> [String] {
        let arguments = ProcessInfo.processInfo.arguments
        let phase = arguments.firstIndex(of: "-phase").map { arguments[$0 + 1] } ?? "reserve"
        result("phase \(phase), \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.physicalMemory >> 20) MB")
        var keep: [Any] = []
        switch phase {
        case "reserve":
            let kept = reserveAll()
            result("reservations granted: \(granted)\(granted < kept.count ? ", the next refused" : " (the limit tried)")")
        case "after":
            for k in 0..<2 {
                let r = WasmKitRuntime()
                do {
                    try r.launch(wasm: resource("heldout_runtime.wasm"), hostImports: imports())
                    try r.loadSideModule(wasm: resource("game2048_side.wasm"))
                    _ = try r.call("iso_hot_start", [.f64(420), .f64(912)])
                    _ = try r.call("iso_hot_render", [])
                    result("interpreted runtime \(k + 1) running")
                } catch {
                    result("interpreted runtime \(k + 1) failed: \(error)")
                }
                keep.append(r)
            }
            mixed()
        case "full":
            let kept = reserveAll()
            result("reservations taken and kept: \(granted)")
            keep.append(kept)
            mixed()
        case "release":
            var kept: [AnyObject]? = reserveAll()
            result("reservations taken: \(granted), then released")
            kept = nil
            _ = kept
            mixed()
        default:
            result("unknown phase")
        }
        _ = keep
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? output.joined(separator: "\n").write(to: docs.appendingPathComponent("probe-\(phase).txt"), atomically: true, encoding: .utf8)
        result("done")
        return output
    }

    static var stream: [UInt8] = []
    static func imports() -> WasmHostImports {
        WasmHostImports(onRenderTree: { stream += $0 }, onLog: { print("guest log: \($0)") },
                        epochMillis: { Date().timeIntervalSince1970 * 1000 }, onScheduleRender: {})
    }

    static func mixed() {
        stream = []
        let native = MixedNativePart(
            shim: resource("shim.wasm"),
            slots: String(decoding: resource("slots.txt"), as: UTF8.self),
            routed: Set(String(decoding: resource("storybook_routed.txt"), as: UTF8.self).split(separator: "\n").map(String.init)))
        let m = MixedWasmKitRuntime(native: native)
        var logs: [String] = []
        let hostImports = WasmHostImports(onRenderTree: { stream += $0 }, onLog: { logs.append($0); print("guest log: \($0)") },
                                          epochMillis: { Date().timeIntervalSince1970 * 1000 }, onScheduleRender: {})
        do {
            try m.launch(wasm: resource("heldout_runtime.wasm"), hostImports: hostImports)
            try m.loadSideModule(wasm: resource("game2048_side.wasm"))
        } catch {
            result("mixed launch failed: \(error)")
            return
        }
        func settle() {
            while true {
                let handled = CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource
                if !handled && m.isIdle { return }
            }
        }
        do {
            _ = try m.call("swift_ffi_isomer_register_HTTPHost", [])
            _ = try m.call("iso_hot_start", [.f64(420), .f64(912)])
            _ = try m.call("iso_hot_render", [])
            settle()
            result("mixed launched: native code \(m.isNative ? "on" : "OFF (interpreted)")")
            for line in logs where line.contains("[mixed]") { result(line) }
            guard let drag = ids(in: stream, suffix: ".drag").first else {
                result("no drag target in the first frame (\(stream.count) bytes)")
                return
            }
            func send(_ value: String) throws {
                let id = Array(drag.utf8), v = Array(value.utf8)
                let ip = try m.call("iso_hot_alloc", [.i32(Int32(id.count))])?.u32Value ?? 0
                let vp = try m.call("iso_hot_alloc", [.i32(Int32(v.count))])?.u32Value ?? 0
                m.writeBytes(ip, id)
                m.writeBytes(vp, v)
                _ = try m.call("iso_hot_event", [.i32(Int32(bitPattern: ip)), .i32(Int32(id.count)), .i32(Int32(bitPattern: vp)), .i32(Int32(v.count))])
                _ = try m.call("iso_hot_free", [.i32(Int32(bitPattern: ip))])
                _ = try m.call("iso_hot_free", [.i32(Int32(bitPattern: vp))])
                _ = try m.call("iso_hot_render", [])
            }
            var samples: [Double] = []
            let directions = [(3, 0), (-3, 0), (0, 3), (0, -3)]
            for d in 0..<10 {
                let (dx, dy) = directions[d % 4]
                for k in 1...20 {
                    let t = DispatchTime.now().uptimeNanoseconds
                    try send("changed:\(k * dx),\(k * dy)")
                    settle()
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
                }
                try send("ended:\(20 * dx),\(20 * dy)")
                settle()
                // The release's animation and the new tile.
                let until = Date(timeIntervalSinceNow: 0.4)
                while Date() < until { CFRunLoopRunInMode(.defaultMode, 0.005, true) }
                settle()
            }
            samples.sort()
            let mean = samples.reduce(0, +) / Double(samples.count)
            result(String(format: "drag events: %d, mean %.2f ms, median %.2f, p90 %.2f, max %.2f; %d bytes of frames",
                          samples.count, mean, samples[samples.count / 2], samples[samples.count * 9 / 10], samples.last!, stream.count))
        } catch {
            result("mixed run failed: \(error)")
        }
    }

    static func ids(in bytes: [UInt8], suffix: String) -> [String] {
        let s = Array(suffix.utf8)
        func ok(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || c == 46 || (c >= 97 && c <= 122) }
        var out: [String] = []
        var i = 0
        while i + s.count <= bytes.count {
            if bytes[i] == s[0], bytes[i..<(i + s.count)].elementsEqual(s) {
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
