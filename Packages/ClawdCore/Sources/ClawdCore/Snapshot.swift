import Foundation

/// Limit history: one sample per /usage reply as [unixMinute, session%, week%] (-1 = none).
public struct UsageHistory: Codable, Equatable, Sendable {
  public static let keepDays = 8
  public static let stepMinutes = 5
  public static let gapMinutes = 20

  public var samples: [[Int]] = []

  public init(samples: [[Int]] = []) { self.samples = samples }

  public static func minute(_ d: Date) -> Int { Int(d.timeIntervalSince1970 / 60) }

  /// An unchanged value is kept at most every 5 minutes; older than 8 days is dropped.
  public mutating func add(_ u: Usage, at d: Date = Date()) {
    let t = Self.minute(d)
    let s = u.session ?? -1, w = u.week ?? -1
    samples.removeAll { $0[0] < t - Self.keepDays * 1440 }
    if let last = samples.last, last[1] == s, last[2] == w, t - last[0] < Self.stepMinutes { return }
    samples.append([t, s, w])
  }

  /// Runs without gaps over 20 minutes, for drawing lines.
  public func runs(from t0: Int, column: Int) -> [[(Int, Int)]] {
    var out: [[(Int, Int)]] = []
    var run: [(Int, Int)] = []
    var prev: Int?
    for s in samples where s[0] >= t0 {
      let v = s[column]
      if v < 0 || (prev != nil && s[0] - prev! > Self.gapMinutes) {
        if !run.isEmpty { out.append(run) }
        run = []
      }
      prev = s[0]
      if v >= 0 { run.append((s[0], v)) }
    }
    if !run.isEmpty { out.append(run) }
    return out
  }

  /// The sample at or before `t` if it is not older than the gap.
  public func sample(at t: Int) -> [Int]? {
    var lo = 0, hi = samples.count - 1
    var hit: [Int]?
    while lo <= hi {
      let mid = (lo + hi) / 2
      if samples[mid][0] <= t { hit = samples[mid]; lo = mid + 1 } else { hi = mid - 1 }
    }
    guard let h = hit, t - h[0] <= Self.gapMinutes else { return nil }
    return h
  }
}

/// Everything the widget shows, written by the app into the shared App Group container
/// and, for the iPhone, into the private CloudKit database (`CloudSnapshot`).
public struct WidgetSnapshot: Codable, Equatable, Sendable {
  public struct ListCount: Codable, Equatable, Sendable {
    public var name: String
    public var open: Int
    public init(name: String, open: Int) {
      self.name = name
      self.open = open
    }
  }

  public var usage: Usage?
  public var usageAt: Date?
  public var stale = false
  public var error: String?
  public var warnPercent = 60
  public var critPercent = 85
  public var mood: Mood = .sleep
  public var sessions = 0
  public var busy = 0
  public var waiting = 0
  public var statusLevel: Level = .dead
  public var statusText = ""
  public var plan = ""
  public var history: [[Int]] = []
  public var weatherCode: Int?
  public var temp: Double?
  public var city: String?
  public var sunrise: Double = 420
  public var sunset: Double = 1140
  public var lat: Double = 50
  public var nextReminder: String?
  public var nextReminderAt: Date?
  public var lists: [ListCount] = []
  public var tips = 0
  public var language = "system"
  public var writtenAt = Date()

  /// Seconds after `usageAt` when the numbers count as stale (3 × interval + 30 s).
  public var staleAfter: Double?

  public init() {}

  public var halves: Int? { Hearts.halves(usage?.session) }

  /// Stale at a given moment: the widget ages the data itself, the app may have stopped writing.
  public func isStale(at now: Date) -> Bool {
    if stale { return true }
    guard let at = usageAt else { return false }
    return now.timeIntervalSince(at) > (staleAfter ?? 210)
  }

  /// What the widget shows prominently; a change here is worth an early reload.
  public var displayKey: String {
    let u = usage
    func m(_ d: Date?) -> String { d.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "-" }
    return [u?.session.map(String.init) ?? "-", u?.week.map(String.init) ?? "-", u?.fable.map(String.init) ?? "-",
            m(u?.sessionReset), m(u?.weekReset), m(u?.fableReset), mood.rawValue, statusLevel.rawValue,
            nextReminder ?? "", language, error ?? ""].joined(separator: "|")
  }

  /// The JSON used for the App Group file and the CloudKit record.
  public func encoded() throws -> Data {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .secondsSince1970
    return try enc.encode(self)
  }

  public static func decoded(_ d: Data) throws -> WidgetSnapshot {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .secondsSince1970
    return try dec.decode(WidgetSnapshot.self, from: d)
  }

  /// Made-up numbers for placeholders and the widget gallery.
  public static func sample(now: Date = Date()) -> WidgetSnapshot {
    var s = WidgetSnapshot()
    s.usage = Usage(session: 42, week: 18, fable: 9, sessionReset: now.addingTimeInterval(7800),
                    weekReset: now.addingTimeInterval(3 * 86400))
    s.usageAt = now
    s.mood = .idle
    s.sessions = 2
    s.statusLevel = .ok
    s.statusText = T("st.ok")
    return s
  }
}

public enum SharedStore {
  /// From the target's Info.plist (key ClawdAppGroup, set from Config/Signing.xcconfig): team-prefixed on
  /// macOS, "group." on iOS. The fallback only matters for tests and previews.
  public static let appGroup: String = Bundle.main.object(forInfoDictionaryKey: "ClawdAppGroup") as? String
    ?? "group.com.example.crabbar"
  public static let refreshNotification = "app.crabbar.widget.refresh"

  public static var container: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }

  static var snapshotURL: URL? { container?.appendingPathComponent("snapshot.json") }

  public static func save(_ s: WidgetSnapshot) {
    guard let u = snapshotURL else { return }
    try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? s.encoded().write(to: u, options: .atomic)
  }

  public static func load() -> WidgetSnapshot? {
    guard let u = snapshotURL, let d = try? Data(contentsOf: u) else { return nil }
    return try? WidgetSnapshot.decoded(d)
  }

  /// When this device last stored a snapshot.
  public static var savedAt: Date? {
    guard let u = snapshotURL else { return nil }
    return (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
  }
}
