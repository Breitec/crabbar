import Foundation

public struct UsagePeriod: Codable, Equatable, Sendable {
  public var requests: Int
  public var sessions: Int
  public var lines: [String]

  public init(requests: Int, sessions: Int, lines: [String]) {
    self.requests = requests
    self.sessions = sessions
    self.lines = lines
  }
}

public struct Usage: Codable, Equatable, Sendable {
  public var session: Int?
  public var week: Int?
  public var fable: Int?
  public var sessionReset: Date?
  public var weekReset: Date?
  public var fableReset: Date?
  public var day: UsagePeriod?
  public var week7: UsagePeriod?

  public init(session: Int? = nil, week: Int? = nil, fable: Int? = nil,
              sessionReset: Date? = nil, weekReset: Date? = nil, fableReset: Date? = nil,
              day: UsagePeriod? = nil, week7: UsagePeriod? = nil) {
    self.session = session
    self.week = week
    self.fable = fable
    self.sessionReset = sessionReset
    self.weekReset = weekReset
    self.fableReset = fableReset
    self.day = day
    self.week7 = week7
  }

  public var hasLimits: Bool { session != nil || week != nil }
}

public enum UsageParseError: Error, Equatable {
  case notAvailable
  case noLimits
}

public enum UsageParser {
  /// Parses `claude -p /usage --output-format text`. A percent without "resets" means 0%-window
  /// not started, not missing data; the Fable line may be absent.
  public static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> Usage {
    if text.contains("isn't available in this environment") { throw UsageParseError.notAvailable }
    var u = Usage()
    if let (p, r) = limit(text, label: #"Current session"#) {
      u.session = p
      u.sessionReset = r.flatMap { ResetStamp.parse($0, now: now, timeZone: timeZone) }
    }
    if let (p, r) = limit(text, label: #"Current week \(all models\)"#) {
      u.week = p
      u.weekReset = r.flatMap { ResetStamp.parse($0, now: now, timeZone: timeZone) }
    }
    if let (p, r) = limit(text, label: #"Current week \(Fable\)"#) {
      u.fable = p
      u.fableReset = r.flatMap { ResetStamp.parse($0, now: now, timeZone: timeZone) }
    }
    u.day = period(text, label: "Last 24h")
    u.week7 = period(text, label: "Last 7d")
    if !u.hasLimits { throw UsageParseError.noLimits }
    return u
  }

  static func limit(_ text: String, label: String) -> (Int, String?)? {
    let pattern = label + #":\s*(\d+)%(?:[^\r\n]*?resets\s*([^\r\n]+))?"#
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let pr = Range(m.range(at: 1), in: text), let pct = Int(text[pr]) else { return nil }
    var reset: String?
    if let rr = Range(m.range(at: 2), in: text) { reset = String(text[rr]) }
    return (pct, reset)
  }

  static func period(_ text: String, label: String) -> UsagePeriod? {
    let pattern = "(?m)^" + NSRegularExpression.escapedPattern(for: label) +
      #"[^\r\n]*?(\d+)\s+requests?\b[^\r\n]*?(\d+)\s+sessions?\b[^\r\n]*\r?\n((?:[ \t]+[^\r\n]*\r?\n?)*)"#
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text),
          let req = Int(text[r1]), let ses = Int(text[r2]) else { return nil }
    var lines: [String] = []
    if let r3 = Range(m.range(at: 3), in: text) {
      lines = text[r3].split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }
    return UsagePeriod(requests: req, sessions: ses, lines: lines)
  }
}

public enum ResetStamp {
  /// "Oct 17, 5:19am (Europe/Moscow)", "Oct 17 at 2:29pm (Europe/Berlin)", "Sep 21, 6am", "2:29pm".
  /// No year in the stamp: assume the current one, more than 30 days in the past means next year.
  public static func parse(_ s: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
    var tz = timeZone
    if let zm = s.range(of: #"\(([A-Za-z_]+/[A-Za-z_/+-]+|UTC|GMT)\)"#, options: .regularExpression) {
      let id = s[zm].dropFirst().dropLast()
      if let z = TimeZone(identifier: String(id)) { tz = z }
    }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let full = #"([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s*(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)"#
    let timeOnly = #"^\s*(\d{1,2})(?::(\d{2}))?\s*([ap]m)"#
    let ns = s as NSString
    if let re = try? NSRegularExpression(pattern: full, options: [.caseInsensitive]),
       let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
      let mon = ns.substring(with: m.range(at: 1)).lowercased()
      let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
      guard let mi = months.firstIndex(of: mon), let day = Int(ns.substring(with: m.range(at: 2))),
            var hour = Int(ns.substring(with: m.range(at: 3))) else { return nil }
      let minute = m.range(at: 4).location != NSNotFound ? Int(ns.substring(with: m.range(at: 4))) ?? 0 : 0
      let ampm = ns.substring(with: m.range(at: 5)).lowercased()
      hour = to24(hour, ampm)
      let year = cal.component(.year, from: now)
      guard var d = cal.date(from: DateComponents(year: year, month: mi + 1, day: day, hour: hour, minute: minute))
      else { return nil }
      if d < now.addingTimeInterval(-30 * 86400) { d = cal.date(byAdding: .year, value: 1, to: d) ?? d }
      return d
    }
    if let re = try? NSRegularExpression(pattern: timeOnly, options: [.caseInsensitive]),
       let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
      guard var hour = Int(ns.substring(with: m.range(at: 1))) else { return nil }
      let minute = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) ?? 0 : 0
      hour = to24(hour, ns.substring(with: m.range(at: 3)).lowercased())
      var c = cal.dateComponents([.year, .month, .day], from: now)
      c.hour = hour
      c.minute = minute
      guard var d = cal.date(from: c) else { return nil }
      if d < now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
      return d
    }
    return nil
  }

  static func to24(_ h: Int, _ ampm: String) -> Int {
    if ampm == "am" { return h == 12 ? 0 : h }
    return h == 12 ? 12 : h + 12
  }
}

public enum StatLine {
  static let rules: [(String, String)] = [
    (#"^(\d+)% of your usage was at >(\S+) context"#, "stat.bigCtx"),
    (#"^(\d+)% of your usage went to always-on context over (\S+)"#, "stat.alwaysOn"),
    (#"^(\d+)% of your usage came from subagent-heavy"#, "stat.subagents"),
    (#"^(\d+)% of your usage came from sessions active for (\d+)\+? hours"#, "stat.long"),
    (#"^(\d+)% of your usage came from workflows"#, "stat.workflows"),
    (#"^Top MCP servers:\s*(.+)$"#, "stat.mcp"),
    (#"^Top skills:\s*(.+)$"#, "stat.skills"),
    (#"^Top subagents:\s*(.+)$"#, "stat.agents"),
    (#"^Top plugins:\s*(.+)$"#, "stat.plugins")
  ]

  /// Known lines are shortened and translated; unknown ones are kept as is.
  public static func format(_ line: String) -> String {
    let ns = line as NSString
    for (pattern, key) in rules {
      guard let re = try? NSRegularExpression(pattern: pattern),
            let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
      var s = L10n.string(key)
      for i in 1..<m.numberOfRanges {
        s = s.replacingOccurrences(of: "{\(i - 1)}", with: ns.substring(with: m.range(at: i)))
      }
      return s
    }
    return line
  }
}
