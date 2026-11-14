// A game of 2048 as simpool input actions: swipes on the board with a
// person's pace, the same every time (a seeded generator), so every engine
// plays the identical game (2048 here is deterministic: the same moves give
// the same board).
//
//   swift make_game.swift [swipes] [seed] > game.json
//
// The board's centre and size are the iPhone Air simulator's, in points
// (420 x 912): the board spans about x 16-403, y 217-604.
import Foundation

var state: UInt64 = 0
func next() -> Double {
    // SplitMix64.
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
}

let arguments = CommandLine.arguments
let swipes = arguments.count > 1 ? Int(arguments[1])! : 150
state = arguments.count > 2 ? UInt64(arguments[2])! : 2048
let (cx, cy) = (210.0, 410.0)
var actions: [[String: Any]] = []
for _ in 0..<swipes {
    // Mostly down and sideways, as people play it.
    let r = next()
    let (dx, dy): (Double, Double) = r < 0.35 ? (0, 1) : r < 0.6 ? (-1, 0) : r < 0.85 ? (1, 0) : (0, -1)
    let length = 90 + 50 * next()
    let x = cx + (next() - 0.5) * 120 - dx * length / 2
    let y = cy + (next() - 0.5) * 120 - dy * length / 2
    let round2 = { (v: Double) in (v * 100).rounded() / 100 }
    actions.append(["type": "swipe", "x": round2(x), "y": round2(y),
                    "to_x": round2(x + dx * length), "to_y": round2(y + dy * length),
                    "duration": round2(0.12 + 0.1 * next())])
    actions.append(["type": "wait", "seconds": round2(0.3 + 0.35 * next())])
}
let data = try JSONSerialization.data(withJSONObject: actions, options: [.prettyPrinted])
FileHandle.standardOutput.write(data)
