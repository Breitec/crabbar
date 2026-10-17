import Foundation
import CoreGraphics

/// What to draw for one mascot tick. Positions are in the mascot area: x from the left, `bottom` from the ground.
public struct MascotRender: Sendable {
  public struct Z: Sendable { public var left, bottom, size, opacity: CGFloat }
  public struct Bubble: Sendable { public var text: String; public var colorHex: String; public var left, bottom: CGFloat }
  public struct Sweat: Sendable { public var left, top, opacity: CGFloat }
  public struct Dot: Sendable { public var left, bottom, width, opacity: CGFloat; public var colorHex: String }
  public struct Love: Sendable { public var left, bottom, opacity: CGFloat }
  public struct Soul: Sendable { public var rects: [CGRect]; public var left, topFromBottom, opacity: CGFloat }

  public var frame = ClawdFrame()
  public var x: CGFloat = 0
  public var bottom: CGFloat = -ClawdSprite.sink
  public var z: Z?
  public var bubble: Bubble?
  public var sweat: Sweat?
  public var dust: [Dot] = []
  public var confetti: [Dot] = []
  public var love: Love?
  public var soul: Soul?
  public var tag = ""
  public var halves: Int?
  public var heartBeat: CGFloat = 1
  public var heartsTip = ""
  public var intervalMs = 90

  public init() {}
}

/// The mascot's behaviour, ported tick for tick from mascot.ps1 / mascot-step.ps1 / hearts.ps1.
public final class MascotEngine {
  public enum DemoStep { case mood(Mood), crit(Mood), drain, act(String) }

  public private(set) var mood: Mood = .idle
  public var force: Mood?
  public var forceCrit = false
  public var forceHearts: Int?
  public var sweatEnabled = true
  public private(set) var demo = -1

  var x: CGFloat = -1
  var dir: CGFloat = 1
  var target: CGFloat?
  var look = 0
  var tick = 0
  var blinkAt = 30
  var crit = false
  var idleSince = Date()
  public private(set) var act: String?
  var actT = 0
  var demoT = 0
  var pct: Int?
  var halvesShown: Int?
  var lostT = -1
  var lostFrom = 0
  var drainT = -1
  var loveT = -1
  var noteT = -1
  var confT = -1
  var busy = -1
  var waiting = 0
  var lastReset: Date?
  var lastPct: Int?
  public private(set) var buried = false
  var cur: Mood = .idle

  struct Confetto { var x: CGFloat = 0, y: CGFloat = 0, v: CGFloat = 0, d: CGFloat = 0 }
  var confetti = Array(repeating: Confetto(), count: 12)
  static let confettiColors = ["#F87171", "#FBBF24", "#4ADE80", "#60A5FA", "#A78BFA", "#D77757"]

  static let drainStep = 22
  static let drainLen = 6 * drainStep + 35

  public static let demoList: [DemoStep] = [
    .mood(.sleep), .mood(.doze), .mood(.idle), .mood(.work), .crit(.work), .mood(.wait), .drain
  ] + ClawdSequences.demoActs.map { .act($0) }

  public init(entrance: Bool = true) {
    if entrance, let a = ClawdSequences.entranceActs.randomElement() { start(a) }
  }

  public var isDev: Bool { demo >= 0 || force != nil || forceCrit || forceHearts != nil }

  // MARK: - data in

  /// New sessions and limits: mood, plus one-shot jump on a finished reply and confetti on a reset.
  public func update(sessions: [ClaudeSession], usage: Usage?, warn: Int, critPct: Int) {
    let b = sessions.filter(\.busy).count
    let w = sessions.filter(\.waiting).count
    let p = usage?.session
    let newMood = Mood.from(sessionPct: p, sessions: sessions)
    if newMood != mood { idleSince = Date() }
    mood = newMood
    if busy > 0 && b < busy && w <= waiting && act == nil { start("jump") }
    busy = b
    waiting = w
    crit = p != nil && Level.of(p, warn: warn, crit: critPct) == .crit
    pct = p
    if let r = usage?.sessionReset {
      if let lr = lastReset, r > lr, let lp = lastPct, let p, p < lp { start("celebrate") }
      lastReset = r
      lastPct = p
    }
  }

  public func start(_ name: String) {
    act = name
    actT = 0
    if name == "celebrate" { startConfetti() }
  }

  /// Click: a random Claude Code animation plus a heart; lying dead, the soul leaves instead.
  public func click() {
    if mood == .dead || cur == .dead {
      if act == nil { start("soul") }
      return
    }
    loveT = 0
    if buried && cur == .sleep {
      if act == nil { start("stir") }
      return
    }
    if act != nil { return }
    if let a = ClawdSequences.clickActs.randomElement() { start(a) }
  }

  public func wave() {
    if act == nil && !buried && mood != .dead { start("wave") }
  }

  public func jumpIfFree() {
    if !buried && mood != .dead { start("jump") }
  }

  /// Stop-MascotDemo of the original: ends the demo, forced mood and sweat, the act, and a running drain.
  public func stopDemo() {
    demo = -1
    demoT = 0
    force = nil
    forceCrit = false
    act = nil
    if drainT >= 0 { drainT = -1; forceHearts = nil }
  }

  /// Hearts set by hand end a running drain first, as in the original menu.
  public func stopDrain() {
    if drainT >= 0 { stopDemo() }
  }

  public func startDemo() {
    stopDemo()
    demo = 0
  }

  public func startDrain() {
    stopDemo()
    drainT = 0
  }

  func startConfetti() {
    for i in confetti.indices {
      confetti[i].x = x - 12 + CGFloat.random(in: 0..<1) * (ClawdSprite.width + 24)
      confetti[i].y = 34 + CGFloat.random(in: 0..<1) * 12
      confetti[i].v = 0.9 + CGFloat.random(in: 0..<1) * 1.2
      confetti[i].d = (CGFloat.random(in: 0..<1) - 0.5) * 0.8
    }
    confT = 0
  }

  func stepDemo() {
    let s = Self.demoList[demo]
    if demoT == 0 {
      forceCrit = false
      switch s {
      case .mood(let m): force = m; act = nil
      case .crit(let m): force = m; act = nil; forceCrit = true
      case .act(let a): force = .idle; target = nil; start(a)
      case .drain: force = .work; act = nil; drainT = 0
      }
    }
    demoT += 1
    let len: Int
    switch s {
    case .act(let a): len = ClawdSequences.length(a) + 12
    case .drain: len = Self.drainLen + 10
    default: len = 55
    }
    if demoT >= len {
      demoT = 0
      demo += 1
      if demo >= Self.demoList.count { stopDemo() }
    }
  }

  /// Heart halves to show (0...6) or nil without data.
  public func currentHalves() -> Int? {
    var h: Int?
    if let f = forceHearts { h = f }
    else if force == .dead { h = 0 }
    else { h = Hearts.halves(pct) }
    guard let h else { return nil }
    return min(6, max(0, h))
  }

  // MARK: - tick

  /// One tick. `mouseX` is the cursor in mascot-area coordinates while it is over the window.
  public func step(areaWidth: CGFloat, areaHeight: CGFloat, hovering: Bool, mouseX: CGFloat?) -> MascotRender {
    tick += 1
    let W = ClawdSprite.width
    let span = max(0, areaWidth - W)
    if x < 0 { x = span / 2 }
    if x > span { x = span }

    if demo >= 0 { stepDemo() }
    if drainT >= 0 {
      forceHearts = max(0, 6 - drainT / Self.drainStep)
      drainT += 1
      if drainT >= Self.drainLen { drainT = -1; forceHearts = nil }
    }
    var mood = force ?? self.mood
    if let fh = forceHearts, fh == 0 { mood = .dead }
    let halves = currentHalves()
    let tierN = halves ?? 5
    let tier = HealthTier.of(tierN)
    let perky = tier.speed >= 0.9
    let now = Date()
    if hovering { idleSince = now }
    if mood == .idle && force == nil && now.timeIntervalSince(idleSince) >= 600 { mood = .doze }

    func mouseLook() -> Int? {
      guard hovering, let mx = mouseX else { return nil }
      let cx = x + W / 2
      if mx > cx + 10 { return 1 }
      if mx < cx - 10 { return -1 }
      return 0
    }

    if mood == .sleep {
      if !buried && act == nil { buried = true; start("burrow") }
    } else if buried {
      buried = false
      start("unburrow")
    }

    var f = ClawdFrame()
    f.look = look
    cur = mood
    var bubble = ""
    var zzz = false
    var canBlink = true
    var dust = false

    if act != nil {
      bubble = stepAct(&f)
      canBlink = false
    } else {
      switch mood {
      case .sleep:
        f.dig = ClawdSprite.burrowDig; f.eyes = "closed"; f.look = 0; zzz = true
      case .doze:
        f.look = 0
        let p = tick % 70
        if p < 6 {
          f.eyes = "wide"
          if p < 2 { f.lift = 1.5 }
        } else {
          f.eyes = "blink"; zzz = true
        }
      case .dead:
        f.flip = true; f.eyes = "x"; f.look = 0
        let p = tick % 50
        if p < 6 { f.feet = p % 2 == 1 ? "left" : "right" }
      case .wait:
        bubble = "?"
        f.eyes = "wide"
        f.look = mouseLook() ?? 0
        let p = tick % 40
        if p < 8 {
          let k = CGFloat(p) / 7.0
          f.lift = 12 * k * (1 - k)
          f.arms = "right"
        }
      case .idle, .work:
        let speed: CGFloat
        if mood == .work {
          speed = 1.6 * tier.speed
          if target == nil { target = dir > 0 ? span : 0 }
        } else {
          speed = 0.6 * tier.speed
          if target == nil {
            if Int.random(in: 0..<70) == 0 { target = CGFloat.random(in: 0..<1) * span }
            else if Int.random(in: 0..<45) == 0 { look = Int.random(in: -1...1) }
            else if Int.random(in: 0..<400) == 0 { start(["wave", "stretch", "look"].randomElement()!) }
          }
        }
        var walking = false
        if let t = target {
          let d = t - x
          if abs(d) <= speed {
            x = t
            target = nil
            if mood == .work { dir = -dir }
          } else {
            dir = d > 0 ? 1 : -1
            x += speed * dir
            look = Int(dir)
            walking = true
          }
        }
        if walking {
          var step = mood == .work ? 2 : 3
          if tier.speed < 0.8 { step += 1 }
          if tier.speed < 0.5 { step += 1 }
          f.feet = (tick / step) % 2 == 1 ? "left" : "right"
          if mood == .work {
            if f.feet == "left" && perky { f.lift = 1 }
            dust = true
            if perky && Int.random(in: 0..<150) == 0 { start("jump") }
          } else if perky && noteT < 0 && Int.random(in: 0..<80) == 0 {
            noteT = 0
          }
          if tier.stumble > 0 && Int.random(in: 0..<tier.stumble) == 0 { start("stumble") }
        } else if crit || forceCrit {
          look = (tick / 5) % 2 == 1 ? -1 : 1
        } else if let ml = mouseLook() {
          look = ml
        }
        f.look = look
        if mood == .work { f.eyes = "focus" }
        if act == nil {
          if tier.hop > 0 && Int.random(in: 0..<tier.hop) == 0 { start("jump") }
          if tier.yawn > 0 && Int.random(in: 0..<tier.yawn) == 0 { start("yawn") }
        }
      }
    }

    if let te = tier.eyes, act == nil, f.eyes == "open" || f.eyes == "focus" { f.eyes = te }
    if loveT >= 0 && act == nil && f.eyes == "open" { f.eyes = "happy" }
    if noteT >= 0 {
      if bubble.isEmpty && mood == .idle { bubble = "\u{266A}" }
      noteT += 1
      if noteT >= 30 { noteT = -1 }
    }
    if canBlink && f.eyes == "open" && tick >= blinkAt {
      f.eyes = "blink"
      if tick >= blinkAt + 1 { blinkAt = tick + Int.random(in: 25..<70) }
    }

    var r = MascotRender()
    r.frame = f
    r.intervalMs = (act.map { ClawdSequences.byName[$0] != nil } ?? false) ? ClawdSprite.frameMs : 90
    var rx = x
    if tier.stagger && mood != .sleep && mood != .dead { rx += 1.5 * CGFloat(sin(Double(tick) / 3.0)) }
    r.x = rx.rounded()
    r.bottom = f.lift - ClawdSprite.sink

    if zzz {
      let p = CGFloat(tick % 30) / 30.0
      let zb: CGFloat = f.dig > 0 ? 9 : (f.off > 0 ? 12 : 19)
      r.z = .init(left: x + 28 + 3 * CGFloat(sin(Double(p) * 2 * .pi)), bottom: zb + 14 * p, size: 7 + 4 * p, opacity: 1 - p)
    }
    if !bubble.isEmpty {
      let color = bubble == "?" ? "#FBBF24" : (bubble == "!" ? "#4ADE80" : "#93C5FD")
      r.bubble = .init(text: bubble, colorHex: color, left: x + W / 2 - 6,
                       bottom: 22 + f.lift + 1.5 * CGFloat(sin(Double(tick) / 3.0)))
    }
    if (crit || forceCrit || tier.sweat) && sweatEnabled && mood != .sleep && mood != .dead {
      let p = CGFloat(tick % 20) / 20.0
      r.sweat = .init(left: f.look < 0 ? 31 : 2, top: -2 + 6 * p - f.lift, opacity: 1 - p)
    }

    // Hearts: a lost half blinks for a moment, the last bit of health beats.
    if let h = halves {
      if let prev = halvesShown, h < prev { lostT = 0; lostFrom = prev }
      halvesShown = h
      var show = h
      if lostT >= 0 {
        if lostT % 4 < 2 { show = lostFrom }
        lostT += 1
        if lostT >= 16 { lostT = -1 }
      }
      r.halves = show
      var beat: CGFloat = 1
      if h > 0 && h <= 2 {
        let p = tick % 12
        if p == 0 { beat = 1.3 } else if p == 1 { beat = 1.15 }
      }
      r.heartBeat = beat
      var tip = T("health.\(h)")
      if let pct, forceHearts == nil { tip = T("hearts.left", tip, 100 - pct) }
      r.heartsTip = tip
    } else {
      halvesShown = nil
    }

    if dust {
      for i in 0..<3 {
        let p = CGFloat((tick + i * 3) % 9) / 9.0
        let dx = dir > 0 ? 4 - 8 * p - 2 * CGFloat(i) : W - 6 + 8 * p + 2 * CGFloat(i)
        r.dust.append(.init(left: x + dx, bottom: 4 * p, width: 2, opacity: 0.7 * (1 - p), colorHex: "#8B8B94"))
      }
    }
    if confT >= 0 {
      for i in confetti.indices {
        confetti[i].y -= confetti[i].v
        confetti[i].x += confetti[i].d
        if confetti[i].y > 0 {
          r.confetti.append(.init(left: confetti[i].x, bottom: confetti[i].y,
                                  width: ((tick + i) / 2) % 2 == 1 ? 2.5 : 1.2, opacity: 1,
                                  colorHex: Self.confettiColors[i % Self.confettiColors.count]))
        }
      }
      confT += 1
      if confT >= 45 { confT = -1 }
    }
    if loveT >= 0 {
      let k = CGFloat(loveT) / 20.0
      r.love = .init(left: x + W / 2 - 5 + 2 * CGFloat(sin(Double(k) * 6)), bottom: 23 + f.lift + 14 * k, opacity: 1 - k)
      loveT += 1
      if loveT >= 20 { loveT = -1 }
    }
    if f.soul > 0.5 {
      r.soul = .init(rects: ClawdSprite.soul(height: f.soul, t: f.soulT), left: x + 9.5 * ClawdSprite.px,
                     topFromBottom: f.lift + 6 * ClawdSprite.py,
                     opacity: 0.7 + 0.15 * CGFloat(sin(Double(f.soulT) / 1.7)))
    }

    if isDev {
      var tag: String
      if drainT >= 0 { tag = mood == .dead ? T("mood.dead") : T("health.\(tierN)") }
      else if let a = act { tag = T("act.\(a)") }
      else if forceCrit { tag = T("tag.sweat") }
      else { tag = T("mood.\(mood.rawValue)") }
      if forceHearts != nil && drainT < 0 && mood != .dead { tag += " · " + T("health.\(tierN)") }
      tag = demo >= 0 ? T("tag.demo", demo + 1, Self.demoList.count, tag) : "dev · " + tag
      r.tag = tag
    }
    return r
  }

  /// One frame of a one-shot animation; returns the bubble text above the head.
  func stepAct(_ f: inout ClawdFrame) -> String {
    guard let a = act else { return "" }
    let t = actT
    var bubble = ""
    if let seq = ClawdSequences.byName[a] {
      let fr = seq[min(t, seq.count - 1)]
      f.eyes = fr.eyes; f.arms = fr.arms; f.feet = fr.feet
      f.off = fr.off; f.x = fr.x; f.facing = fr.facing; f.poof = fr.poof; f.shadow = fr.shadow
      f.look = 0
      if a == "celebrate" { bubble = "!" }
    } else {
      let dig = ClawdSprite.burrowDig
      switch a {
      case "wave":
        f.look = 0; f.eyes = "happy"
        f.arms = (t / 4) % 2 == 1 ? "down" : "right"
      case "stretch":
        if t >= 4 && t < 18 { f.arms = "up"; f.eyes = "closed"; f.lift = 1.5 }
      case "yawn":
        f.look = 0
        f.eyes = (t >= 3 && t < 17) ? "yawn" : "closed"
      case "stumble":
        if t < 12 { f.off = 1; f.eyes = "closed" } else { f.eyes = "wide" }
        f.look = 0
      case "soul":
        f.flip = true; f.look = 0
        let up = ClawdSprite.soulUp, back = ClawdSprite.soulBack, top = ClawdSprite.soulTop
        if t < 6 {
          f.eyes = "x"
          f.feet = t % 2 == 1 ? "left" : "right"
        } else if t < back + 6 {
          f.eyes = "gasp"
          f.soulT = t
          if t < up {
            let k = CGFloat(t - 6) / CGFloat(up - 6)
            f.soul = top * (1 - (1 - k) * (1 - k))
          } else if t < back {
            f.soul = top + 1.5 * CGFloat(sin(Double(t - up) / 2.5))
          } else {
            let k = CGFloat(t - back) / 6.0
            f.soul = top * (1 - k * k)
          }
        } else if t < back + 9 {
          f.eyes = "wide"; f.lift = 2.5
        } else {
          f.eyes = "x"
        }
      case "burrow":
        if t < 4 {
          f.look = t < 2 ? -1 : 1
        } else if t < 24 {
          f.look = 0; f.eyes = "focus"
          f.dig = min(dig, Int(floor(Double(t - 4) / 3.5)))
          f.feet = (t / 2) % 2 == 1 ? "left" : "right"
          f.arms = (t / 2) % 2 == 1 ? "up" : "down"
          f.spray = (t % 3) + 1
        } else {
          f.look = 0; f.dig = dig
          f.eyes = t < 27 ? "blink" : "closed"
        }
      case "unburrow":
        f.look = 0
        if t < 3 {
          f.dig = dig; f.eyes = "wide"
        } else if t < 9 {
          f.dig = max(0, dig - (t - 3)); f.eyes = "wide"
          f.arms = "up"; f.spray = (t % 3) + 1
          if t == 8 { f.lift = 2 }
        } else if t < 21 {
          f.eyes = "closed"
          f.look = (t / 2) % 2 == 1 ? -1 : 1
          f.feet = (t / 2) % 2 == 1 ? "left" : "right"
          if t < 15 { f.spray = (t % 3) + 1 }
        } else if t < 23 {
          f.eyes = "blink"
        }
      case "stir":
        f.dig = t < 15 ? dig - 1 : dig
        if t < 3 { f.eyes = "wide"; f.look = 0 }
        else if t < 13 { f.look = t < 8 ? -1 : 1 }
        else if t < 17 { f.eyes = "blink"; f.look = 0 }
        else { f.eyes = "closed"; f.look = 0 }
      default: break
      }
    }
    actT += 1
    if actT >= ClawdSequences.length(a) { act = nil }
    return bubble
  }

  /// A still pose for a mood, used by the widget.
  public static func stillFrame(for mood: Mood, halves: Int?) -> (ClawdFrame, String?) {
    var f = ClawdFrame()
    var bubble: String?
    switch mood {
    case .sleep: f.dig = ClawdSprite.burrowDig; f.eyes = "closed"
    case .doze: f.eyes = "blink"
    case .dead: f.flip = true; f.eyes = "x"
    case .wait: f.eyes = "wide"; f.arms = "right"; bubble = "?"
    case .work: f.eyes = "focus"; f.feet = "left"
    case .idle: f.eyes = "open"
    }
    if let te = HealthTier.of(halves).eyes, f.eyes == "open" || f.eyes == "focus" { f.eyes = te }
    return (f, bubble)
  }
}
