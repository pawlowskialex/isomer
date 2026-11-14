# Features as side modules over one runtime, and mixed mode (proposal)

**Status: a proposal, measured.** It doesn't decide between running wasm on
WasmKit and running it in the platform's web view (TODO.md, "WebAssembly on
the platforms' own engines"); it measures one against the other on the same
game (below). The linker is engine-neutral, so side modules work on either.

## The problem

A downloaded feature today is a reactor carrying its own copy of the Swift
standard library, Foundation and Isomer's SwiftUI. Even dead-stripped, the
smallest (the tap counter) is 16.5 MB raw, 4.8 MB gzip; the Storybook's app
18.3 MB, 5.4 MB gzip. A second feature pays it again, in download and memory.

## Side modules

Swift's wasm objects, and the Swift SDK's standard library, are position-
independent, so a feature links as a wasm **side module** over a **runtime
module**: the libraries once, every public symbol exported.

    load("@isomer//tools/wasm:side_modules.bzl", "wasm_runtime_module", "wasm_side_module")

    wasm_runtime_module(name = "runtime", deps = [<the reactor's libraries but the feature>])
    wasm_side_module(name = "feature", deps = [<the feature's own libraries>])

A loader places the side module as a dynamic loader places a shared library
(the WebAssembly tool conventions' DynamicLinking.md): its memory from the
runtime's allocator, its table slots at the table's end, its imports from the
runtime's exports and the side modules loaded before it, then its data
relocations and constructors (Swift's `swiftrt.o` registers its metadata).

- **The linker is engine-neutral.** `IsomerWasmDylink`
  (//shared/wasm_host:wasm_dylink) reads `dylink.0` and the imports, decides
  placement and bindings and runs relocations, over a small engine protocol;
  WasmKit's adapter is `WasmDynamicLinker` (and
  `WasmKitRuntime.loadSideModule`). Browsers and web views use its twin,
  wasm/libraries/swift_ui/runtime/side_modules.js. tests/wasm_dylink holds
  both to the same modules, built byte by byte: malformed and truncated
  `dylink.0`, out-of-range values, placement, binding order, relocations,
  table and memory growth, refusals.
- **wasm-ld.** Swift 6.4.2's wasm-ld gives Swift's relative pointers
  (`R_WASM_MEMORY_ADDR_LOCREL_I32`) a runtime relocation in a side module
  that adds `__memory_base`, breaking every conformance record; upstream
  LLVM rejects the relocation instead. tools/patches/lld_wasm_pic_locrel.patch
  is the fix (lld's tests pass with it, and a new one), to propose upstream.
  Until a swift.org toolchain has it, `wasm_side_module` links with the
  toolchain's wasm-ld and corrects the output: tools/wasm/side_module_fixup
  finds each relative pointer's site from the inputs' relocations and the
  link map, and removes exactly those stores (every site must be accounted
  for, or it fails).
- **Checked by rendering.** examples' //tests/side_modules: the Storybook's
  app as a side module over its runtime module renders, under WasmKit, what
  its self-contained reactor renders, byte for byte (the first frame and a
  tap on every first-frame tap target: each story's page).

| (-c opt) | Self-contained reactor | Side module |
| --- | --- | --- |
| Tap counter | 16.5 MB / 4.8 MB gzip | 12.6 KB / 5 KB gzip |
| Storybook's app (98 stories + app) | 18.3 MB / 5.4 MB gzip | 721 KB / 233 KB gzip |
| Runtime, once | — | 23.9 MB / 6.7 MB gzip, stripped |

Open: a feature binds to the exact runtime build it was linked against (no
library evolution on wasm), so features are versioned per runtime build; the
runtime holds one root (`Runtime.shared`) and starts the feature through
`__main_argc_argv`, so one feature per runtime instance until there is a
per-feature entry and a root per feature.

## Mixed mode

Interpreting the runtime is slow, and compiling all of it to C (wasm2c) is
319 MB of C and 36 MB of native code. Mixed mode keeps the runtime one wasm
module WasmKit interprets and compiles **copies** of its hot functions into
the app, over the same memory, a mirrored table and the one mutable global,
`__stack_pointer`, synced at each crossing. Interpreted code never calls
native code (moving functions instead made 18 million crossings and ran 5×
slower than interpreting); the host enters native code at the runtime's entry
points, native code calls back into the interpreter for the rest and for the
feature, and features call a few heavy runtime functions natively ("routed").

    load("@isomer//tools/wasm:mixed.bzl", "wasm_mixed_native")

    wasm_mixed_native(
        name = "native",
        runtime = ":runtime.wasm",
        native_set = "native_set.txt",   # from profiling the app
        routed = "routed.txt",
    )

`:native` is a cc_library the app links; `MixedWasmKitRuntime`
(//shared/wasm_host:mixed_runtime) runs the runtime and its side modules with
it. tools/wasm_mixed generates the C (Binaryen's wasm-split on the set, WABT's
wasm2c, a bridge and a WasmKit shim); Binaryen and WABT are pinned
(MODULE.bazel).

**The guest on its own thread.** `MixedWasmKitRuntime` runs the guest only on
a thread of its own with a large stack (native code recurses on it), so the
main thread never waits for the guest's renders: calls that answer nothing are
queued in order, an allocation answers at once with a placeholder address
made real on the guest's thread, and the guest's calls into the host run on
the main thread while its thread keeps serving the queue (so the host's calls
back in can't deadlock). Measured below, this is what made mixed mode better
than the web view rather than worse.

Checked: examples' //tests/side_modules:mixed_render_test, the Storybook's
app in mixed mode, renders byte for byte what its reactor renders.

What it needs of WasmKit: public API to place modules in a table and memory
(`Table.grow`, `Table.function(at:)`, `Function.reference`,
`Memory.unsafeBaseAddress`, …) and cheaper host calls (`invokeUnchecked`,
no signal mask saved per entry, a return to the host that doesn't throw):
two branches of the side-modules author's WasmKit fork, each with its tests,
to propose to AttilaTheFun/WasmKit; isomer pins them until then.

Open: a trap in native code (or in interpreted code under it) ends the process
(native code can't unwind into Swift); native code without bounds checks needs
WasmKit's guard pages (launch fails without them; `bounds_checks = True`
builds the slower checked code: 7.4 MB against 3.9 MB for the Storybook's
runtime); the native set comes from profiling, and paths the profile didn't
cover run interpreted; no rule yet runs the profiling.

## Measurements

The harnesses (profiling, the drag benchmark, 2048 Lab, simulator replays)
aren't in this tree; they and their raw results are on the side-modules-perf
branch of the pull request's head repository.

**The Storybook's 99 taps, WasmKit, Mac:** interpreted 3.15 s; mixed 0.44 s,
byte-identical. Native code 3.9 MB for 4,990 functions.

**2048, played, iPhone Air** (2048 Lab: the same game, the same native
renderer, only the engine differs; event to frame, ms):

| | Mixed, main thread (first build) | Web view (JavaScriptCore) | Mixed, own thread |
| --- | --- | --- | --- |
| mean | 10.4 | 3.1 | **2.5** |
| median | 11.7 | 1.8 | **1.5** |
| p99 | 23.2 | 11.0 | **7.7** |
| events over 8.3 ms | 54% | 4.2% | **0.6%** |
| display frames dropped while playing | 13.1% | 2.9% | **1.2%** |
| main thread's longest stall | 29.6 ms | 0.9 ms | **0.1 ms** |
| app memory | 111 MB | 31 MB + the web process (250–280 MB on a Mac) | 109 MB |

**The same 150-swipe game replayed through a simulator's touch input**
(iPhone Air simulator, two runs each, every run ending on the same board):

| | Mixed, main thread | Web view | Mixed, own thread |
| --- | --- | --- | --- |
| mean (ms) | 2.0 | 1.3 | 1.5 |
| p99 (ms) | 6.6–7.0 | 4.3–4.7 | 5.4–5.6 |
| display frames dropped while playing | 0.6% | 0.2–0.4% | **0.1%** |
| first frame | 0.45 s | 1.3–1.4 s | 0.45 s |
| app CPU (s) | 26–27 | 39, + the web process | 37 |

The first mixed build ran the game's Swift jobs fully interpreted (their entry
point wasn't native) and was profiled on a benchmark that ran none; with both
fixed, and the guest off the main thread, mixed mode is on par with the web
view's JIT on latency, ahead on dropped frames and start, and keeps what an
engine in the app's process gives: synchronous calls into the host (0.11 µs
under WasmKit against 61 µs from a web view), one process (the web process
can be killed on its own, losing the guest's state), no second process's
memory, and every place the app's code runs (tvOS, watchOS, widgets and
background work have no web view).
