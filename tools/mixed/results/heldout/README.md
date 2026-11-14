# A native set chosen without the feature (2048 held out)

examples/tools/wasm_bench/heldout: 2048 as a side module over a runtime
module plays 60 swipes of replay/game.json as drag events paced to 120 Hz, on
a Mac, in mixed mode with each native set (wasm_mixed_native's rules), or
interpreted. "Busy" is the summed time from each event or frame to the
guest's thread being idle; best of three interleaved runs (reps3.txt; the
Mac was in use, so earlier rounds, reps.txt and reps2.txt, vary more).
Every run of every variant ended on the same board.

| Native set | Profile | Busy (best of 3) | Drag event mean / p99 | Native code |
| --- | --- | --- | --- | --- |
| interpreted | — | 15.2 s | 4.0 / 21.0 ms | — |
| Isomer's modules + their direct-call closure | none | 10.0 s | 2.4 / 10.3 ms | 7.8 MB |
| the Storybook's set (2048 held out) | Storybook | 6.1 s | 1.6 / 9.4 ms | 4.8 MB |
| 2048's own (Storybook's grown on 2048's play) | 2048 | 4.9 s | 1.6 / 8.6 ms | 5.0 MB |
| Storybook's + modules + functions ≤ 128 B | Storybook | 4.9 s | 1.4 / 7.5 ms | 15.1 MB |
| Storybook's + modules + closure | Storybook | **4.4 s** | 1.3 / 7.7 ms | 10.0 MB |

Rounds 1-2 (reps.txt, reps2.txt) also had: functions ≤ 128 B alone, and
modules + small (+ all C) without a profile: no faster than interpreted, as
every entry point runs through a specialized `MainActor.assumeIsolated`
that only a profile or the closure makes native (interpreted code never
calls native code).

What it found:

- Sets name functions, and 11,535 of the runtime's 104,052 functions share
  1,588 names (140 `.L__unnamed_6`); wasm-split tells copies apart by
  function index, which changes with every build. A set made on one build
  named the wrong copies in the next: 40 million calls from native code into
  interpreted helpers in this game. tools/wasm_mixed/Select.swift now takes a
  name as every copy.
- With that, a corpus profile of the runtime (the Storybook's taps) plus
  rules beats the feature's own set: no per-feature profile is needed.
- Without any profile, the rules reach 1.5x interpreted: what is left
  interpreted is reached indirectly (reabstraction thunks, the Swift
  runtime's value witnesses and casts, the standard library's deinits,
  String, SwiftProtobuf), which no direct-call closure finds.
