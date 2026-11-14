# 2048 Lab's results (docs/side_modules.md, "Measurements")

Each file is one game's stats as 2048 Lab saved them (PlayEngines.swift's
`PlayStats`): event-to-frame latency (every sample, and percentiles), the
display's dropped frames, the main thread's time in the engine, memory, CPU.

- `iphone_air_played/`: played by hand on an iPhone Air (iOS 27.2): the first
  mixed build on the main thread and the web view (02-53, 02-55), then mixed
  on its own thread and the web view again (04-12).
- `simulator_replay/`: replay/game.json (150 swipes) through an iPhone Air
  simulator's touch input (replay/replay.sh, simpool), renders paced to the
  display: the web view, mixed on the main thread and on its own thread
  (round 3's native set, data/storybook_2048_play_native_set.txt), two runs
  each; `unpaced-mixed-before-*` the first mixed build, unpaced. Every run
  ended on the same board.
