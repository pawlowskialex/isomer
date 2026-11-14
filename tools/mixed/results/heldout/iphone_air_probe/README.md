# Mixed mode when it isn't the first engine (iPhone Air, iOS 27.2.1)

examples/tools/wasm_bench/heldout/probe (`mixed_probe_ios_application`), one
phase a launch:

- `reserve`: the process is granted **one** guard-page reservation (WasmKit's
  4 GiB and more for a memory); the next is refused.
- `after`: two interpreted WasmKitRuntimes running 2048, then a
  MixedWasmKitRuntime: its reservation is refused, and it runs the guest
  interpreted (`isNative` false): 200 drag events, mean 5.29 ms, no fault.
  The prototype engine in 2048 Lab ran native code over such a memory (one
  that moves as it grows), which faults: the crash reported on the PR.
- `release`: the reservation taken and given back, then mixed: native code
  on, mean 1.19 ms.
