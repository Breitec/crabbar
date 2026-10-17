import Foundation

/// All settings, kept in ~/Library/Application Support/CrabBar/config.json. Edits to the file are
/// picked up on the fly; keys this version doesn't know are kept on save.
struct Config: Codable, Equatable {
  var refreshSeconds = 10.0
  var usageIntervalSeconds = 60.0
  var versionIntervalSeconds = 3600.0
  var updateCheck = true
  var expanded = false
  var scale = 1.3
  var warnPercent = 60
  var critPercent = 85
  var opacity = 1.0
  var topmost = true
  var floating = false
  var left: Double?
  var top: Double?
  var trayResetClock = false
  var menuBarPercent = true
  var showStats = true
  var showHistory = true
  var showStatus = true
  var statusIntervalSeconds = 120.0
  var showSessions = true
  var showAccount = true
  var accountIntervalSeconds = 600.0
  var showMascot = true
  var showSky = true
  var weatherIntervalSeconds = 900.0
  var weatherLat: Double?
  var weatherLon: Double?
  var weatherUseLocation = true
  var weatherIPLookup = false
  var showAdvisor = true
  var advisorIntervalMinutes = 30.0
  var advisorDiskGB = 10.0
  var advisorJunkGB = 5.0
  var advisorUnusedDays = 90
  var advisorUptimeDays = 7
  var advisorMemPercent = 40.0
  var showChat = true
  var chatModel = "sonnet"
  var chatTimeoutSeconds = 300.0
  var chatAutoRun = false
  var quickModel = "haiku"
  var showTasks = true
  var tasksMaxPercent = 80
  var language = "system"
  var clawdHome: String?
  var clawdSession = false
  var clawdSessionName = "crabbar"
  var claudePath: String?
  var iCloudSync = true

  init() {}

  init(from decoder: Decoder) throws {
    let d = Config()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil ?? def }
    refreshSeconds = v(.refreshSeconds, d.refreshSeconds)
    usageIntervalSeconds = v(.usageIntervalSeconds, d.usageIntervalSeconds)
    versionIntervalSeconds = v(.versionIntervalSeconds, d.versionIntervalSeconds)
    updateCheck = v(.updateCheck, d.updateCheck)
    expanded = v(.expanded, d.expanded)
    scale = v(.scale, d.scale)
    warnPercent = v(.warnPercent, d.warnPercent)
    critPercent = v(.critPercent, d.critPercent)
    opacity = v(.opacity, d.opacity)
    topmost = v(.topmost, d.topmost)
    floating = v(.floating, d.floating)
    left = try? c.decodeIfPresent(Double.self, forKey: .left)
    top = try? c.decodeIfPresent(Double.self, forKey: .top)
    trayResetClock = v(.trayResetClock, d.trayResetClock)
    menuBarPercent = v(.menuBarPercent, d.menuBarPercent)
    showStats = v(.showStats, d.showStats)
    showHistory = v(.showHistory, d.showHistory)
    showStatus = v(.showStatus, d.showStatus)
    statusIntervalSeconds = v(.statusIntervalSeconds, d.statusIntervalSeconds)
    showSessions = v(.showSessions, d.showSessions)
    showAccount = v(.showAccount, d.showAccount)
    accountIntervalSeconds = v(.accountIntervalSeconds, d.accountIntervalSeconds)
    showMascot = v(.showMascot, d.showMascot)
    showSky = v(.showSky, d.showSky)
    weatherIntervalSeconds = v(.weatherIntervalSeconds, d.weatherIntervalSeconds)
    weatherLat = try? c.decodeIfPresent(Double.self, forKey: .weatherLat)
    weatherLon = try? c.decodeIfPresent(Double.self, forKey: .weatherLon)
    weatherUseLocation = v(.weatherUseLocation, d.weatherUseLocation)
    weatherIPLookup = v(.weatherIPLookup, d.weatherIPLookup)
    showAdvisor = v(.showAdvisor, d.showAdvisor)
    advisorIntervalMinutes = v(.advisorIntervalMinutes, d.advisorIntervalMinutes)
    advisorDiskGB = v(.advisorDiskGB, d.advisorDiskGB)
    advisorJunkGB = v(.advisorJunkGB, d.advisorJunkGB)
    advisorUnusedDays = v(.advisorUnusedDays, d.advisorUnusedDays)
    advisorUptimeDays = v(.advisorUptimeDays, d.advisorUptimeDays)
    advisorMemPercent = v(.advisorMemPercent, d.advisorMemPercent)
    showChat = v(.showChat, d.showChat)
    chatModel = v(.chatModel, d.chatModel)
    chatTimeoutSeconds = v(.chatTimeoutSeconds, d.chatTimeoutSeconds)
    chatAutoRun = v(.chatAutoRun, d.chatAutoRun)
    quickModel = v(.quickModel, d.quickModel)
    showTasks = v(.showTasks, d.showTasks)
    tasksMaxPercent = v(.tasksMaxPercent, d.tasksMaxPercent)
    language = v(.language, d.language)
    clawdHome = try? c.decodeIfPresent(String.self, forKey: .clawdHome)
    clawdSession = v(.clawdSession, d.clawdSession)
    clawdSessionName = v(.clawdSessionName, d.clawdSessionName)
    claudePath = try? c.decodeIfPresent(String.self, forKey: .claudePath)
    iCloudSync = v(.iCloudSync, d.iCloudSync)
  }

  var homeURL: URL {
    if let h = clawdHome, !h.isEmpty { return URL(fileURLWithPath: (h as NSString).expandingTildeInPath) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Clawd")
  }
}

enum AppPaths {
  static var support: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let u = base.appendingPathComponent("CrabBar")
    // The app was called "Clawd Usage" before: carry settings, history and chat over once.
    let old = base.appendingPathComponent("ClawdUsage")
    if !FileManager.default.fileExists(atPath: u.path) && FileManager.default.fileExists(atPath: old.path) {
      try? FileManager.default.moveItem(at: old, to: u)
    }
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
  }
  static var config: URL { support.appendingPathComponent("config.json") }
  static var history: URL { support.appendingPathComponent("usage-history.json") }
  static var chat: URL { support.appendingPathComponent("chat-state.json") }
  static var tasks: URL { support.appendingPathComponent("tasks-state.json") }
  static var advisor: URL { support.appendingPathComponent("advisor-state.json") }
  static var clawd: URL { support.appendingPathComponent("clawd-state.json") }
  static var tokens: URL { support.appendingPathComponent("tokens-cache.json") }
  static var errorLog: URL { support.appendingPathComponent("widget-error.log") }
  static var prompts: URL {
    let u = support.appendingPathComponent("prompts")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
  }
}

final class ConfigStore {
  private(set) var config = Config()
  private var stamp: Date?

  init() {
    load()
    if !FileManager.default.fileExists(atPath: AppPaths.config.path) { save(config) }
  }

  func load() {
    guard let d = try? Data(contentsOf: AppPaths.config) else { return }
    if let c = try? JSONDecoder().decode(Config.self, from: d) { config = c }
    stamp = mtime()
  }

  private func mtime() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: AppPaths.config.path))?[.modificationDate] as? Date
  }

  /// Re-reads the file when it changed on disk. Returns true if something changed.
  func sync() -> Bool {
    let m = mtime()
    guard m != stamp else { return false }
    let old = config
    load()
    return old != config
  }

  /// Saves, keeping keys of the file this version doesn't know.
  func save(_ c: Config) {
    config = c
    var dict: [String: Any] = [:]
    if let d = try? Data(contentsOf: AppPaths.config), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
      dict = j
    }
    if let d = try? JSONEncoder().encode(c), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
      for k in Mirror(reflecting: c).children.compactMap(\.label) where j[k] == nil { dict.removeValue(forKey: k) }
      for (k, v) in j { dict[k] = v }
    }
    if let out = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
      try? out.write(to: AppPaths.config, options: .atomic)
    }
    stamp = mtime()
  }

  func update(_ f: (inout Config) -> Void) {
    var c = config
    f(&c)
    if c != config { save(c) }
  }
}

func logError(_ s: String) {
  let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(s)\n"
  if let h = try? FileHandle(forWritingTo: AppPaths.errorLog) {
    h.seekToEndOfFile()
    h.write(line.data(using: .utf8)!)
    try? h.close()
  } else {
    try? line.data(using: .utf8)?.write(to: AppPaths.errorLog)
  }
}
