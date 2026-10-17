import Foundation

/// The click animations from Claude Code, frame by frame (60 ms per frame).
public enum ClawdSequences {
  static let poses: [String: String] = [
    "default": "open/down/both",
    "arms-up": "open/up/both",
    "look-left": "left/down/both",
    "look-right": "right/down/both"
  ]

  static func F(_ pose: String, _ n: Int = 1, off: Int = 0, x: Int = 0, poof: String = "", shadow: String = "") -> [ClawdFrame] {
    var fr = ClawdFrame()
    fr.off = off
    fr.x = x
    fr.poof = poof
    fr.shadow = shadow
    if pose.hasPrefix("face:") {
      fr.facing = String(pose.dropFirst(5))
    } else {
      let p = (poses[pose] ?? pose).split(separator: "/").map(String.init)
      fr.eyes = p[0]
      fr.arms = p.count > 1 ? p[1] : "down"
      fr.feet = p.count > 2 ? p[2] : "both"
    }
    return Array(repeating: fr, count: n)
  }

  static func turn(_ list: [String], shadow: String = "") -> [ClawdFrame] {
    list.flatMap { F("face:\($0)", 1, shadow: shadow) }
  }

  public static let all: [(String, [ClawdFrame])] = {
    let cr = F("default", off: 1, poof: "dot") + F("default", off: 1, poof: "wave")
    let bo = F("default")
    let ts = F("closed/down/both") + bo
    let jumpSeq = cr + F("arms-up", 3) + bo + cr + F("arms-up", 3) + bo
    var waddle = F("look-right", x: -9)
    for u in -6...(-1) {
      waddle += F("right/down/\(u % 2 == 0 ? "left" : "right")", 2, x: u)
    }
    return [
      ("jump", jumpSeq),
      ("look", F("look-right", 5) + F("look-left", 5) + bo),
      ("celebrate", jumpSeq + F("default", 3, off: 1)),
      ("skip", F("default", off: 1, x: -9) + F("arms-up", 2, x: -6) + F("default", x: -6) +
        F("default", off: 1, x: -6) + F("arms-up", 2, x: -3) + F("default", x: -3) +
        F("default", off: 1, x: -3) + F("arms-up", 2) + cr + bo),
      ("spin", F("look-left", 2) + F("look-right", 2) + F("look-left", 2) + F("arms-up", 3) + bo),
      ("peekaboo", F("default", off: 3) + F("default", 3, off: 2) + F("look-right", 3, off: 2) +
        F("look-left", 3, off: 2) + F("default", 2, off: 2) + F("default", off: 1) +
        F("arms-up", 4) + F("default", 2) + ts),
      ("drop", F("arms-up", off: -3) + F("arms-up", 2, off: -2) + F("arms-up", 2, off: -1) +
        F("arms-up") + cr + F("default", 3) + ts),
      ("waddle", waddle + F("look-right", 2) + F("default", 2) + ts),
      ("peek", F("look-right", x: -9) + F("look-right", 5, x: -6) + F("look-right", 3, x: -9) +
        F("look-right", 4, x: -5) + F("arms-up", 2, x: -3) + F("arms-up", 2) + cr + bo),
      ("wink", F("wink/down/both", 5) + bo),
      ("boop", F("closed/down/both", off: 1, poof: "dot") + F("closed/down/both", 2, off: 1, poof: "wave") +
        F("look-left", 4) + F("default", 2) + ts),
      ("tap", F("open/down/left", 2) + F("open/down/right", 2) + F("open/down/left", 2) +
        F("open/down/right", 2) + F("open/down/left") + F("open/down/right") + F("arms-up", 3) + bo),
      ("sneeze", F("closed/up/both", 4) + F("closed/down/both", 2, off: 1, poof: "wave") +
        F("closed/down/both", 2) + F("default", 2) + ts),
      ("turn", turn(["right-12", "right-30", "right-55", "right-75", "edge"]) +
        turn(["back-105", "back-125", "back-150", "back", "back"]) +
        turn(["back-150", "back-125", "back-105", "edge"]) +
        turn(["left-75", "left-55", "left-30", "left-12"]) + bo),
      ("coin-hop", F("default", 2, off: 1) + F("arms-up", shadow: "wide") +
        turn(["right-55", "edge", "back-125", "back"], shadow: "narrow") +
        turn(["back-125", "edge", "left-55"], shadow: "narrow") +
        F("arms-up", shadow: "wide") + cr + bo)
    ]
  }()

  public static let byName: [String: [ClawdFrame]] = Dictionary(uniqueKeysWithValues: all)

  /// Custom acts drawn by the engine (not frame lists), with their length in 90 ms ticks.
  public static let custom: [(String, Int, Bool)] = [
    ("wave", 24, false), ("stretch", 22, false), ("yawn", 22, false), ("stumble", 20, false),
    ("soul", 66, false), ("burrow", 30, true), ("unburrow", 28, true), ("stir", 22, true)
  ]

  public static var actNames: [String] { all.map(\.0) + custom.map(\.0) }

  public static func length(_ act: String) -> Int {
    if let s = byName[act] { return s.count }
    return custom.first { $0.0 == act }?.1 ?? 1
  }

  /// On click: everything that starts in place (no slide-in), except celebrate.
  public static let clickActs: [String] = all.filter { $0.1.first?.x == 0 && $0.0 != "celebrate" }.map(\.0)
  /// On start: an entrance from any animation.
  public static let entranceActs: [String] = all.map(\.0).filter { $0 != "celebrate" }
  public static let demoActs: [String] = all.map(\.0) + custom.filter { !$0.2 }.map(\.0)
}
