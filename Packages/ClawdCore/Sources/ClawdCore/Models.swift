import Foundation

public struct ClaudeSession: Codable, Equatable, Identifiable, Sendable {
  public var pid: Int32
  public var name: String
  public var cwd: String
  public var busy: Bool
  public var waiting: Bool
  public var waitingFor: String
  public var kind: String
  public var sessionId: String

  public var id: Int32 { pid }

  public init(pid: Int32, name: String, cwd: String, busy: Bool, waiting: Bool,
              waitingFor: String = "", kind: String = "", sessionId: String = "") {
    self.pid = pid
    self.name = name
    self.cwd = cwd
    self.busy = busy
    self.waiting = waiting
    self.waitingFor = waitingFor
    self.kind = kind
    self.sessionId = sessionId
  }

  public var mark: String { busy ? "▶" : (waiting ? "?" : "○") }
}

public struct ServiceStatus: Codable, Equatable, Sendable {
  public struct Broken: Codable, Equatable, Sendable {
    public var name: String
    public var state: String
    public init(name: String, state: String) {
      self.name = name
      self.state = state
    }
  }

  public var indicator: String
  public var incidents: [String]
  public var broken: [Broken]

  public init(indicator: String, incidents: [String], broken: [Broken]) {
    self.indicator = indicator
    self.incidents = incidents
    self.broken = broken
  }

  public var allGood: Bool { indicator == "none" && broken.isEmpty && incidents.isEmpty }

  public var level: Level {
    if allGood { return .ok }
    return ["major", "critical"].contains(indicator) ? .crit : .warn
  }

  /// Statuspage summary.json: overall indicator, non-operational components (groups skipped), incidents.
  public static func parse(_ data: Data) -> ServiceStatus? {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let ind = ((j["status"] as? [String: Any])?["indicator"] as? String) ?? "none"
    var broken: [Broken] = []
    for c in (j["components"] as? [[String: Any]]) ?? [] {
      if (c["group"] as? Bool) == true { continue }
      let st = (c["status"] as? String) ?? "operational"
      if st == "operational" { continue }
      var name = (c["name"] as? String) ?? ""
      if let r = name.range(of: #"\s*\(.*\)\s*$"#, options: .regularExpression) { name.removeSubrange(r) }
      broken.append(Broken(name: name, state: st))
    }
    let inc = ((j["incidents"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    return ServiceStatus(indicator: ind, incidents: inc, broken: broken)
  }
}

public struct Account: Codable, Equatable, Sendable {
  public var loggedIn: Bool
  public var plan: String
  public var email: String

  public init(loggedIn: Bool, plan: String, email: String) {
    self.loggedIn = loggedIn
    self.plan = plan
    self.email = email
  }

  /// `claude auth status` JSON.
  public static func parse(_ data: Data) -> Account? {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let names = ["max": "Max", "pro": "Pro", "team": "Team", "enterprise": "Enterprise", "free": "Free"]
    var plan = (j["subscriptionType"] as? String) ?? ""
    let method = (j["authMethod"] as? String) ?? ""
    if let n = names[plan] { plan = n } else if plan.isEmpty, !method.isEmpty, method != "claude.ai" { plan = "API" }
    return Account(loggedIn: (j["loggedIn"] as? Bool) ?? false, plan: plan, email: (j["email"] as? String) ?? "")
  }
}

public enum Mood: String, Codable, CaseIterable, Sendable {
  case sleep, doze, idle, work, wait, dead

  /// Checked top to bottom, as in the original.
  public static func from(sessionPct: Int?, sessions: [ClaudeSession]) -> Mood {
    if let p = sessionPct, p >= 100 { return .dead }
    if sessions.contains(where: \.waiting) { return .wait }
    if sessions.contains(where: \.busy) { return .work }
    if !sessions.isEmpty { return .idle }
    return .sleep
  }
}

public enum Hearts {
  /// Heart halves 0...6 left of the session limit; nil without data.
  public static func halves(_ pct: Int?) -> Int? {
    guard let pct else { return nil }
    let h = Int((Double(max(0, 100 - pct)) * 6.0 / 100.0).rounded(.up))
    return min(6, max(0, h))
  }
}

public struct HealthTier: Sendable {
  public var speed: Double
  public var hop: Int = 0
  public var yawn: Int = 0
  public var eyes: String? = nil
  public var sweat = false
  public var stagger = false
  public var stumble: Int = 0

  public static func of(_ halves: Int?) -> HealthTier {
    switch halves ?? 5 {
    case 6: return HealthTier(speed: 1.25, hop: 300)
    case 5: return HealthTier(speed: 1.0)
    case 4: return HealthTier(speed: 0.9, yawn: 350)
    case 3: return HealthTier(speed: 0.75, yawn: 200, eyes: "focus")
    case 2: return HealthTier(speed: 0.55, yawn: 160, eyes: "focus", sweat: true)
    case 1: return HealthTier(speed: 0.35, eyes: "blink", sweat: true, stagger: true, stumble: 220)
    default: return HealthTier(speed: 0)
    }
  }
}
