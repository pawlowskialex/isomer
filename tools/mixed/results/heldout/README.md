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

## A corpus instead of an app (reps4-6.txt)

The native set from a corpus no app is in: tools/wasm_mixed_corpus writes an
app of 80 screens made methodically from a catalog of SwiftUI's pieces (43),
modifiers (30), containers (11) and screen patterns (8), each screen's root a
NavigationStack, a NavigationSplitView or a TabView in turn, every screen's
state changed by its timer; the bench's driver operates whatever each
screen's frames show (taps, drags, text, sliders, toggles and pickers, long
presses, context menus). WasmKitFunctionProfile profiles it under the
interpreter (bench_profile, HELDOUT_FEATURE=corpus; profile_corpus3.txt), and
`wasm_mixed profile-set` makes the set: every runtime function that ran
(4,896 of 104,052). 2048 and the Storybook are both held out. The bench now
registers a swift_ffi dependency, as hosts do, which installs the guest's
executor: 2048's tiles spawn (in the runs above, they didn't, in every
variant alike).

Busy time, median of 3 (2048: 60 swipes; Storybook: 99 taps, their frames,
drags on what the pages show):

| Native set | Profile | 2048 | Storybook | Native code |
| --- | --- | --- | --- | --- |
| interpreted | — | 19.7 s | 26.1 s | — |
| corpus, round 1 | corpus | 9.1 s | 20.5 s | 3.8 MB |
| corpus, round 3 | corpus | 6.6 s | 5.1 s | 4.1 MB |
| corpus + modules + closure, round 3 | corpus | 6.1 s | 4.3 s | 9.8 MB |
| 2048's own | 2048 | 7.1 s | 4.6 s | 5.0 MB |
| the Storybook's own | Storybook | 10.2 s | 4.8 s | 4.8 MB |
| Storybook's + modules + closure | Storybook | 6.2 s | 3.7 s | 10.0 MB |

(rounds 2-3 of reps5.txt for the apps' own sets; reps6.txt for round 3.)

Round 1's corpus missed one function the Storybook depends on:
`NavigationSplitView`'s node, the Storybook's root, so everything beneath it
ran interpreted (96% of the time). Round 2 added root navigation structures
and text runs (concatenated, markdown, AttributedString), long text and
lists; round 3 `ForEach` over Identifiable data, `List(selection:)` with
tags and sections, `accessibilityIdentifier`, `background` with a view: each
a kind of API a held-out app showed missing (ISO_MIXED_COUNT=1's
crossings), added to the catalog, not the app.

Round 3's corpus (80 screens of 8 items) met every piece and modifier, but
only 226 of the 473 piece × container pairs, 965 of 1,290 piece × modifier
and 80 of 88 container × pattern: the catalog had outgrown the screens'
arithmetic (fixed after these measurements).

Round 4 (reps7.txt, profile_corpus4.txt): the screens' arithmetic fixed,
88 screens of 8 items meet every piece × container (473), piece × modifier
(1,290) and container × pattern (88) pair. 4,949 runtime functions ran
(round 3: 4,896). Busy time, median of 3: 2048 7.0 s with the corpus set,
6.7 s with the rules; the Storybook 5.1 s and 4.4 s. The same as round 3
within the runs' spread: these two apps were already covered.
