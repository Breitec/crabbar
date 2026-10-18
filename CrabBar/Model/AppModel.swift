import Foundation
import SwiftUI
import WidgetKit
import ClawdCore

/// Central state: probes /usage, account, sessions, status, versions and weather on their own schedules,
/// drives Clawd and the sky, and feeds the widget. The main tick runs every `refreshSeconds`.
@MainActor
@Observable
final class AppModel {
  let cfgStore = ConfigStore()
  var config: Config

  var claude: ClaudeCLI.Binary?
  var claudeError: String?

  var usage: Usage?
  var usageAt: Date?
  @ObservationIgnored var usageTry = Date.distantPast
  @ObservationIgnored var usageRunning = false
  var account: Account?
  @ObservationIgnored var accountTry = Date.distantPast
  var sessions: [ClaudeSession] = []
  var status: ServiceStatus?
  var statusAt: Date?
  @ObservationIgnored var statusTry = Date.distantPast

  var verLocal: String?
  var verLatest: String?
  @ObservationIgnored var verAt = Date.distantPast
  var changes: (forVersion: String, from: String, items: [String])?
  @ObservationIgnored var changesTry = Date.distantPast
  var updating = false
  var appRelease: AppRelease?
  @ObservationIgnored var releaseAt = Date.distantPast

  var weather: Weather?
  var place: Place?
  @ObservationIgnored var wxTry = Date.distantPast
  @ObservationIgnored var wxAlt = false
  @ObservationIgnored var geoTry = Date.distantPast
  @ObservationIgnored var wxPlaceKey = ""
  @ObservationIgnored let location = LocationProvider()

  var history = UsageHistory()
  var projects: ProjectScanner.Result?
  @ObservationIgnored var projTry = Date.distantPast
  @ObservationIgnored var projRunning = false
  /// PATH and CLAUDE_CONFIG_DIR from the login shell are in: until then the projects folder is not known.
  @ObservationIgnored var loginEnvLoaded = false
  @ObservationIgnored var scanner: ProjectScanner?

  var now = Date()

  // Clawd and the sky
  @ObservationIgnored let mascot = MascotEngine()
  @ObservationIgnored let sky = SkyEngine()
  var mascotRender = MascotRender()
  var skyRender = SkyRender()
  @ObservationIgnored var areaSize = CGSize(width: 150, height: 40)
  @ObservationIgnored var skySize = CGSize(width: 238, height: 43)
  @ObservationIgnored var hovering = false
  @ObservationIgnored var mouseX: CGFloat?
  @ObservationIgnored var areaOriginX: CGFloat = 0
  @ObservationIgnored var demo = false
  @ObservationIgnored var animSources = Set<String>()
  @ObservationIgnored var animTask: Task<Void, Never>?
  @ObservationIgnored var locating = false
  @ObservationIgnored var updateMarker: URL?
  @ObservationIgnored var reloadPending = false
  @ObservationIgnored var importantPending = false

  // Clawd's helpers
  @ObservationIgnored var home: ClawdHome
  @ObservationIgnored var chat: ChatController!
  @ObservationIgnored var tasks: TaskRunner!
  @ObservationIgnored var reminders: ReminderCenter!
  @ObservationIgnored var advisor: Advisor!
  @ObservationIgnored var clawdSession: ClawdSessionKeeper!
  var panelOpen = false

  @ObservationIgnored var tickTask: Task<Void, Never>?
  @ObservationIgnored var lastSnapshot: WidgetSnapshot?
  @ObservationIgnored var lastReload = Date.distantPast
  @ObservationIgnored let cloud = CloudUpload()
  @ObservationIgnored var sessionsWatcher: DispatchSourceFileSystemObject?

  /// Hooks for the AppKit side.
  @ObservationIgnored var onChange: (() -> Void)?
  @ObservationIgnored var openPanel: ((String?) -> Void)?

  init() {
    config = cfgStore.config
    L10n.setting = cfgStore.config.language
    home = ClawdHome(url: cfgStore.config.homeURL)
    home.ensure()
    if let d = try? Data(contentsOf: AppPaths.history), let h = try? JSONDecoder().decode(UsageHistory.self, from: d) {
      history = h
    }
    Prompts.install()
    chat = ChatController(model: self)
    tasks = TaskRunner(model: self)
    reminders = ReminderCenter(model: self)
    advisor = Advisor(model: self)
    clawdSession = ClawdSessionKeeper(model: self)
  }

  func start() {
    if Self.demoRequested {
      startDemo()
      tickTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(10))
          self?.tick()
        }
      }
      return
    }
    Task {
      // CLAUDE_CONFIG_DIR comes with the login shell's PATH: watch the sessions folder only after that.
      await Proc.loadLoginEnv()
      loginEnvLoaded = true
      watchSessions()
      await locateClaude()
      tick()
    }
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        let secs = max(2, self?.config.refreshSeconds ?? 10)
        try? await Task.sleep(for: .seconds(secs))
        self?.tick()
      }
    }
  }

  func locateClaude() async {
    guard !locating else { return }
    locating = true
    defer { locating = false }
    let found = await ClaudeCLI.locate(override: config.claudePath)
    if found != claude { claude = found }
    verLocal = claude?.version
    if claude == nil { claudeError = T("err.noClaude") } else if claudeError == T("err.noClaude") { claudeError = nil }
  }

  // MARK: - main tick

  func tick() {
    now = Date()
    if demo { onChange?(); return }
    if cfgStore.sync() { applyConfig(cfgStore.config) }
    let c = config
    // The desktop app keeps only one version of its bundled claude and deletes the old one on update.
    if let b = claude, !FileManager.default.isExecutableFile(atPath: b.path) {
      claude = nil
      Task { await locateClaude() }
    }
    if let m = updateMarker, FileManager.default.fileExists(atPath: m.path) {
      try? FileManager.default.removeItem(at: m)
      updateMarker = nil
      updating = false
      verAt = .distantPast
      Task { await locateClaude() }
    }

    if claude != nil, !usageRunning, now.timeIntervalSince(usageTry) >= c.usageIntervalSeconds { probeUsage() }
    if c.showStatus, now.timeIntervalSince(statusTry) >= c.statusIntervalSeconds { probeStatus() }
    if c.showAccount, claude != nil, now.timeIntervalSince(accountTry) >= c.accountIntervalSeconds { probeAccount() }
    if now.timeIntervalSince(verAt) >= c.versionIntervalSeconds { probeVersion() }
    probeChangelogIfNeeded()
    if c.updateCheck, now.timeIntervalSince(releaseAt) >= 3600 { probeRelease() }
    let pk = "\(c.weatherLat.map { "\($0)" } ?? "")|\(c.weatherLon.map { "\($0)" } ?? "")|\(c.weatherUseLocation)|\(c.weatherIPLookup)"
    if pk != wxPlaceKey { wxPlaceKey = pk; wxTry = .distantPast; place = nil }
    if c.showMascot, c.showSky, now.timeIntervalSince(wxTry) >= c.weatherIntervalSeconds { probeWeather() }
    if c.showHistory, c.expanded, !projRunning, now.timeIntervalSince(projTry) >= 15 * 60 { scanProjects() }

    refreshSessions()
    reminders.update()
    tasks.update()
    advisor.update()
    clawdSession.update(allSessions: rawSessions)
    chat.updateRemoteFeed()
    writeSnapshot()
    onChange?()
  }

  func applyConfig(_ c: Config) {
    let langChanged = c.language != config.language
    let homeChanged = c.homeURL != config.homeURL
    config = c
    L10n.setting = c.language
    if homeChanged {
      home = ClawdHome(url: c.homeURL)
      home.ensure()
    }
    if langChanged { lastSnapshot = nil }
    onChange?()
  }

  func updateConfig(_ f: (inout Config) -> Void) {
    cfgStore.update(f)
    applyConfig(cfgStore.config)
  }

  func refreshNow() {
    usageTry = .distantPast
    statusTry = .distantPast
    accountTry = .distantPast
    tick()
  }

  // MARK: - sessions

  @ObservationIgnored var rawSessions: [ClaudeSession] = []

  func refreshSessions() {
    if demo { return }
    rawSessions = SessionsReader.read()
    // Clawd's own idle session is not "something running", or he would never fall asleep.
    let mine = Set(clawdSession.mine(rawSessions).map(\.pid))
    let list = rawSessions.filter { !(mine.contains($0.pid) && !$0.busy && !$0.waiting) }
    if list != sessions { sessions = list }
    if config.showMascot { mascot.update(sessions: sessions, usage: usage, warn: config.warnPercent, critPct: config.critPercent) }
  }

  func watchSessions() {
    let path = SessionsReader.dir.path
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
    src.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        self?.refreshSessions()
        self?.writeSnapshot()
      }
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    sessionsWatcher = src
  }

  // MARK: - probes

  func probeUsage() {
    guard let bin = claude else { return }
    usageTry = Date()
    usageRunning = true
    Task {
      let o = await Proc.run(bin.path, ["-p", "/usage", "--output-format", "text", "--no-session-persistence"],
                             cwd: NSTemporaryDirectory(), timeout: 90)
      usageRunning = false
      do {
        let u = try UsageParser.parse(o.text)
        usage = u
        usageAt = Date()
        claudeError = nil
        history.add(u)
        if let d = try? JSONEncoder().encode(history) { try? d.write(to: AppPaths.history, options: .atomic) }
      } catch UsageParseError.notAvailable {
        claudeError = T("err.oldClaude")
      } catch {
        if o.code != 0 || o.timedOut { logError("usage: exit \(o.code) \(o.errText.prefix(300))") }
      }
      refreshSessions()
      writeSnapshot()
      onChange?()
    }
  }

  func probeAccount() {
    guard let bin = claude else { return }
    accountTry = Date()
    Task {
      let o = await Proc.run(bin.path, ["auth", "status"], cwd: NSTemporaryDirectory(), timeout: 30)
      if let a = Account.parse(o.out) { account = a }
    }
  }

  func probeStatus() {
    statusTry = Date()
    Task {
      if let s = await Net.status() { status = s; statusAt = Date() }
    }
  }

  func probeVersion() {
    verAt = Date()
    Task {
      await locateClaude()
      if let v = await Net.latestVersion(channel: ClaudeCLI.updateChannel) { verLatest = v }
    }
  }

  var hasUpdate: Bool {
    guard let l = verLocal, let n = verLatest else { return false }
    return ClaudeCLI.newer(n, than: l)
  }

  nonisolated static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
  }

  /// Hourly look at the newest GitHub release; only a hint, nothing is downloaded.
  func probeRelease() {
    releaseAt = Date()
    Task {
      if let r = await Net.latestRelease() { appRelease = r }
    }
  }

  /// A newer CrabBar than the one running, if the check is on.
  var appUpdate: AppRelease? {
    guard config.updateCheck, let r = appRelease, AppRelease.newer(r.version, than: Self.appVersion) else { return nil }
    return r
  }

  func openReleasePage() {
    if let u = URL(string: AppRelease.page) { NSWorkspace.shared.open(u) }
  }

  func probeChangelogIfNeeded() {
    guard hasUpdate, let l = verLocal, let n = verLatest else { return }
    if let c = changes, c.forVersion == n, c.from == l { return }
    if now.timeIntervalSince(changesTry) < 600 { return }
    changesTry = Date()
    Task {
      if let items = await Net.changelog(from: l, to: n) { changes = (n, l, items) }
    }
  }

  /// `claude update` in a visible Terminal window.
  func runClaudeUpdate() {
    guard !updating, let bin = claude else { return }
    updating = true
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-update-\(UUID().uuidString.prefix(8)).done")
    updateMarker = marker
    let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    Terminal.run(command: "\(q(bin.path)) update; touch \(q(marker.path)); echo; read -k 1 -s '?Enter…'", title: "claude update")
  }

  var effectivePlace: Place? {
    if let la = config.weatherLat, let lo = config.weatherLon { return Place(lat: la, lon: lo) }
    return place
  }

  func probeWeather() {
    if let p = effectivePlace {
      wxTry = Date()
      Task {
        if let w = await Net.weather(p, metNo: wxAlt) {
          weather = w
        } else if !wxAlt {
          wxAlt = true
          wxTry = .distantPast
        }
      }
      return
    }
    guard now.timeIntervalSince(geoTry) >= 600 else { return }
    geoTry = Date()
    Task {
      var p: Place?
      if config.weatherUseLocation { p = await location.current() }
      if p == nil, config.weatherIPLookup { p = await Net.ipPlace(lang: L10n.lang.rawValue) }
      if let p {
        place = p
        wxTry = .distantPast
        probeWeather()
      }
    }
  }

  var freshWeather: Weather? {
    guard let w = weather, Date().timeIntervalSince(w.at) < 3 * 3600 else { return nil }
    return w
  }

  var sunTimes: (sr: Double, ss: Double) {
    if let w = weather, let sr = w.sunrise, let ss = w.sunset { return (sr, ss) }
    if let p = effectivePlace { return SunCalc.times(lat: p.lat, lon: p.lon) }
    return (420, 1140)
  }

  func scanProjects() {
    // A scan of the wrong folder would also drop the token cache of the right one; the tick catches up.
    guard loginEnvLoaded else { return }
    projTry = Date()
    projRunning = true
    let root = ClaudeConfig.projects
    if scanner?.root != root { scanner = ProjectScanner(root: root, cacheURL: AppPaths.tokens) }
    let s = scanner!
    Task.detached(priority: .utility) {
      let r = s.scan()
      await MainActor.run {
        self.projects = r
        self.projRunning = false
      }
    }
  }

  // MARK: - derived

  var isStale: Bool {
    guard let at = usageAt else { return false }
    return Date().timeIntervalSince(at) > 3 * config.usageIntervalSeconds + 30
  }

  var sessionLevel: Level { Level.of(usage?.session, warn: config.warnPercent, crit: config.critPercent) }

  var statusStale: Bool {
    guard let at = statusAt else { return true }
    return Date().timeIntervalSince(at) > 3 * config.statusIntervalSeconds + 30
  }

  var statusText: String {
    guard let st = status, !statusStale else { return status == nil ? T("st.loading") : T("st.offline") }
    if st.allGood { return T("st.ok") }
    if !st.incidents.isEmpty { return st.incidents.joined(separator: "  ·  ") }
    if st.indicator == "maintenance" { return T("st.maint") }
    return T("st.issues")
  }

  var statusExtra: String {
    guard let st = status, !statusStale, !st.allGood else { return "" }
    return st.broken.map { b in
      let k = "comp.\(b.state)"
      let t = L10n.string(k)
      return "\(b.name): \(t == k ? b.state : t)"
    }.joined(separator: "  ·  ")
  }

  var statusLevel: Level {
    guard let st = status, !statusStale else { return .dead }
    return st.level
  }

  var sessionsLine: String {
    if sessions.isEmpty { return T("sess.none") }
    let busy = sessions.filter(\.busy).count, wait = sessions.filter(\.waiting).count
    var line = plural(sessions.count, "session")
    if busy > 0 || wait == 0 { line += "  ·  " + T("sess.busy", busy) }
    if wait > 0 { line += "  ·  " + T("sess.wait", wait) }
    return line
  }

  var sessionsTip: String {
    sessions.map { s in
      let what = s.waiting && !s.waitingFor.isEmpty ? " [\(s.waitingFor)]" : ""
      return "\(s.mark) \(s.name)\(what) — \(s.cwd)"
    }.joined(separator: "\n")
  }

  /// Tooltip of the menu bar icon, like the original tray text.
  var trayTip: String {
    guard let u = usage, let pct = u.session else { return T("tray.noData") }
    if config.trayResetClock {
      var rows: [String] = []
      for (k, v, r) in [("tray.clock.session", u.session, u.sessionReset), ("tray.clock.week", u.week, u.weekReset),
                        ("tray.clock.fable", u.fable, u.fableReset)] {
        guard let v else { continue }
        var row = T(k, v)
        if let r { row += T("tray.clock.resets", Format.resetClock(r)) }
        rows.append(row)
      }
      return rows.joined(separator: "\n")
    }
    var tip = T("tray.session", pct)
    if let r = u.sessionReset, let s = Format.span(until: r) { tip += " · \(s)" }
    var t2: [String] = []
    if let w = u.week { t2.append(T("tray.week", w)) }
    if let f = u.fable { t2.append("Fable \(f)%") }
    if !t2.isEmpty { tip += "\n" + t2.joined(separator: " · ") }
    return tip
  }

  // MARK: - animation

  /// Clawd and the sky animate only while the popover or the floating window is on screen.
  func setAnimating(_ source: String, _ on: Bool) {
    if on { animSources.insert(source) } else { animSources.remove(source) }
    if animSources.isEmpty {
      animTask?.cancel()
      animTask = nil
    } else {
      startAnimating()
    }
  }

  func startAnimating() {
    guard animTask == nil else { return }
    animTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let r = self.mascot.step(areaWidth: self.areaSize.width, areaHeight: self.areaSize.height,
                                 hovering: self.hovering, mouseX: self.mouseX)
        self.mascotRender = r
        if self.config.showSky {
          self.skyRender = self.sky.step(width: self.skySize.width, height: self.skySize.height, now: Date(),
                                         sun: self.sunTimes, weather: self.freshWeather, place: self.effectivePlace)
        }
        try? await Task.sleep(for: .milliseconds(r.intervalMs))
      }
    }
  }


  // MARK: - widget

  func writeSnapshot() {
    if demo { return }
    var s = WidgetSnapshot()
    s.usage = usage
    s.usageAt = usageAt
    s.stale = isStale
    s.error = claudeError
    s.warnPercent = config.warnPercent
    s.critPercent = config.critPercent
    s.mood = Mood.from(sessionPct: usage?.session, sessions: sessions)
    s.sessions = sessions.count
    s.busy = sessions.filter(\.busy).count
    s.waiting = sessions.filter(\.waiting).count
    s.statusLevel = config.showStatus ? statusLevel : .dead
    s.statusText = config.showStatus ? statusText : ""
    s.staleAfter = 3 * config.usageIntervalSeconds + 30
    s.plan = account?.plan ?? ""
    let cut = UsageHistory.minute(Date()) - 24 * 60
    s.history = history.samples.filter { $0[0] >= cut }
    s.weatherCode = freshWeather?.code
    s.temp = freshWeather?.temp
    s.city = place?.city
    s.sunrise = sunTimes.sr
    s.sunset = sunTimes.ss
    s.lat = effectivePlace?.lat ?? 50
    if let r = home.activeReminders().first {
      s.nextReminder = r.text
      s.nextReminderAt = r.at
    }
    s.lists = home.listNames(defaultName: T("lists.default")).map { n in
      .init(name: n, open: home.readList(n).items.filter { !$0.done }.count)
    }
    s.tips = advisor.tips.count
    s.language = config.language
    var cmp = s
    cmp.writtenAt = lastSnapshot?.writtenAt ?? s.writtenAt
    if cmp != lastSnapshot {
      SharedStore.save(s)
      // What the widget shows prominently reloads soon; everything else waits for the next batch.
      if lastSnapshot == nil || lastSnapshot?.displayKey != s.displayKey { importantPending = true }
      lastSnapshot = s
      reloadPending = true
    }
    let since = Date().timeIntervalSince(lastReload)
    if (importantPending && since > 60) || (reloadPending && since > 300) { reload() }
    if config.iCloudSync { cloud.offer(s) }
  }

  /// WidgetKit allows only a few dozen reloads a day; keep well inside that.
  func reload() {
    reloadPending = false
    importantPending = false
    lastReload = Date()
    WidgetCenter.shared.reloadAllTimelines()
  }
}

enum Terminal {
  /// Runs a command in a new Terminal window through a .command file (no Automation permission needed).
  static func run(command: String, title: String, cwd: String? = nil) {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-\(UUID().uuidString.prefix(8)).command")
    var script = "#!/bin/zsh -l\nprintf '\\e]0;%s\\a' '\(title)'\n"
    if let cwd { script += "cd '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))'\n" }
    script += command + "\n"
    try? script.write(to: u, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)
    NSWorkspace.shared.open(u)
  }
}
