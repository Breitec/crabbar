import Foundation
import AppKit
import ClawdCore

/// Looks the Mac over every half hour without network or tokens: low disk space, caches and other junk,
/// new login items, apps not opened for a long time, a pending update, uptime, memory and CPU hogs.
/// The macOS counterpart of the Windows advisor.
@MainActor
@Observable
final class Advisor {
  struct Tip: Identifiable, Equatable, Sendable {
    var sig: String
    var text: String
    var ctx: String
    var actionLabel: String
    var actionURL: String
    var snoozeDays: Double
    var id: String { sig }
  }

  struct Saved: Codable {
    var snoozed: [String: Date] = [:]
    var knownAgents: [String]?
    var cpuSeen: [String] = []
  }

  @ObservationIgnored weak var model: AppModel?
  var tips: [Tip] = []
  var scanning = false
  var checkedAt: Date?
  @ObservationIgnored var saved = Saved()
  @ObservationIgnored let started = Date()
  @ObservationIgnored var lastAgents: [String] = []

  init(model: AppModel) {
    self.model = model
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    if let d = try? Data(contentsOf: AppPaths.advisor), let s = try? dec.decode(Saved.self, from: d) { saved = s }
  }

  func persist() {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    if let d = try? enc.encode(saved) { try? d.write(to: AppPaths.advisor, options: .atomic) }
  }

  func update() {
    guard let model, model.config.showAdvisor, !scanning else { return }
    if checkedAt == nil {
      if Date().timeIntervalSince(started) >= 60 { scan() }
    } else if let at = checkedAt, Date().timeIntervalSince(at) >= model.config.advisorIntervalMinutes * 60 {
      scan()
    }
  }

  func dismiss(_ t: Tip) {
    // Dismissing "new login items" accepts them as the new baseline, as in the original.
    if t.sig.hasPrefix("startup:") { saved.knownAgents = lastAgents }
    else { saved.snoozed[t.sig] = Date().addingTimeInterval(t.snoozeDays * 86400) }
    persist()
    tips.removeAll { $0.sig == t.sig }
    writeTipsFile()
  }

  func perform(_ t: Tip) {
    if t.actionURL.hasPrefix("/") {
      NSWorkspace.shared.open(URL(fileURLWithPath: t.actionURL))
    } else if let u = URL(string: t.actionURL) {
      NSWorkspace.shared.open(u)
    }
  }

  func scan() {
    guard let model, !scanning else { return }
    scanning = true
    let c = model.config
    let known = saved.knownAgents
    let cpuSeen = saved.cpuSeen
    Task.detached(priority: .utility) {
      let r = await AdvisorScan.run(diskGB: c.advisorDiskGB, junkGB: c.advisorJunkGB, unusedDays: c.advisorUnusedDays,
                                    uptimeDays: c.advisorUptimeDays, memPercent: c.advisorMemPercent,
                                    knownAgents: known, cpuSeen: cpuSeen)
      await MainActor.run { self.finish(r) }
    }
  }

  func finish(_ r: AdvisorScan.Result) {
    scanning = false
    checkedAt = Date()
    lastAgents = r.agents
    if saved.knownAgents == nil { saved.knownAgents = r.agents }
    saved.cpuSeen = r.cpuNow
    let now = Date()
    saved.snoozed = saved.snoozed.filter { $0.value > now }
    persist()
    let fresh = r.tips.filter { saved.snoozed[$0.sig] == nil }
    let isNew = !Set(fresh.map(\.sig)).subtracting(tips.map(\.sig)).isEmpty
    tips = fresh
    writeTipsFile()
    if isNew, !fresh.isEmpty, let model, model.config.showMascot { model.mascot.wave() }
    model?.onChange?()
  }

  func writeTipsFile() {
    guard let home = model?.home else { return }
    var lines = ["# Tips from the CrabBar app", "",
                 "Written by the app after it looks the Mac over (every \(Int(model?.config.advisorIntervalMinutes ?? 30)) min). Do not edit.",
                 "Checked: \(checkedAt.map { Format.iso($0) } ?? "-")", ""]
    if tips.isEmpty { lines.append("Nothing to report.") }
    for t in tips {
      lines.append("- \(t.text)")
      if !t.ctx.isEmpty { lines.append("  details: \(t.ctx)") }
    }
    try? (lines.joined(separator: "\n") + "\n").write(to: home.url.appendingPathComponent("tips.md"), atomically: true, encoding: .utf8)
  }
}

enum AdvisorScan {
  struct Result: Sendable {
    var tips: [Advisor.Tip] = []
    var agents: [String] = []
    var cpuNow: [String] = []
  }

  static let gb = 1_073_741_824.0

  static func size(of u: URL, excluding: Set<String> = []) -> Double {
    guard let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                                                  options: [], errorHandler: { _, _ in true }) else { return 0 }
    var total = 0.0
    for case let f as URL in en {
      if excluding.contains(f.path) { en.skipDescendants(); continue }
      let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
      if v?.isRegularFile == true { total += Double(v?.totalFileAllocatedSize ?? 0) }
    }
    return total
  }

  static func fmt(_ bytes: Double) -> String { String(format: "%.1f", bytes / gb) }

  static func run(diskGB: Double, junkGB: Double, unusedDays: Int, uptimeDays: Int, memPercent: Double,
                  knownAgents: [String]?, cpuSeen: [String]) async -> Result {
    var r = Result()
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    func h(_ p: String) -> URL { home.appendingPathComponent(p) }

    // Junk: caches, logs, Trash, Downloads and developer caches.
    let caches = h("Library/Caches")
    let special: [(String, URL)] = [("adv.place.pip", h("Library/Caches/pip")), ("adv.place.yarn", h("Library/Caches/Yarn")),
                                    ("adv.place.brew", h("Library/Caches/Homebrew"))]
    var places: [(String, URL, Double)] = []
    places.append(("adv.place.caches", caches, size(of: caches, excluding: Set(special.map { $0.1.path }))))
    for (k, u) in special where fm.fileExists(atPath: u.path) { places.append((k, u, size(of: u))) }
    for (k, u) in [("adv.place.logs", h("Library/Logs")), ("adv.place.trash", h(".Trash")),
                   ("adv.place.downloads", h("Downloads")), ("adv.place.npm", h(".npm/_cacache")),
                   ("adv.place.xcode", h("Library/Developer/Xcode/DerivedData"))] where fm.fileExists(atPath: u.path) {
      places.append((k, u, size(of: u)))
    }
    places.sort { $0.2 > $1.2 }
    let junk = places.reduce(0) { $0 + $1.2 }
    let junkCtx = places.filter { $0.2 > 50_000_000 }.map { "\($0.1.path) \(fmt($0.2)) GB" }.joined(separator: "; ")

    // Disk space.
    // Fixed drives only, as the original: internal, writable, local; no USB sticks, DMGs or network shares.
    let keys: [URLResourceKey] = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
                                  .volumeNameKey, .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey, .volumeIsLocalKey]
    for v in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
      guard let rv = try? v.resourceValues(forKeys: Set(keys)), rv.volumeIsBrowsable == true,
            v.path == "/" || (rv.volumeIsInternal == true && rv.volumeIsLocal != false && rv.volumeIsReadOnly != true),
            let total = rv.volumeTotalCapacity, total > 0 else { continue }
      let important = rv.volumeAvailableCapacityForImportantUsage ?? 0
      let free = important > 0 ? important : Int64(rv.volumeAvailableCapacity ?? 0)
      let freeGB = Double(free) / gb
      let pct = Double(free) / Double(total) * 100
      if freeGB < diskGB || pct < 5 {
        let name = rv.volumeName ?? v.lastPathComponent
        r.tips.append(.init(sig: "disk:\(name)", text: T("adv.disk", name, String(format: "%.1f", freeGB), Int(pct)),
                            ctx: junkCtx, actionLabel: T("adv.act.storage"),
                            actionURL: "x-apple.systempreferences:com.apple.settings.Storage", snoozeDays: 1))
      }
    }
    if junk >= junkGB * gb {
      let what = places.filter { $0.2 >= 0.2 * gb }.prefix(4).map { "\(T($0.0)) \(fmt($0.2))" }.joined(separator: ", ")
      r.tips.append(.init(sig: "junk", text: T("adv.junk", fmt(junk), what), ctx: junkCtx,
                          actionLabel: T("adv.act.open", T("adv.place.caches")), actionURL: caches.path, snoozeDays: 3))
    }

    // Login items: new LaunchAgents compared to the first look.
    var agents: [String] = []
    for d in [h("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")] {
      for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasSuffix(".plist") { agents.append(f) }
    }
    agents.sort()
    r.agents = agents
    if let known = knownAgents {
      let added = agents.filter { !known.contains($0) }
      if !added.isEmpty {
        let names = added.map { $0.replacingOccurrences(of: ".plist", with: "") }
        r.tips.append(.init(sig: "startup:\(names.joined(separator: ","))", text: T("adv.startup", names.joined(separator: ", ")),
                            ctx: added.joined(separator: "; "), actionLabel: T("adv.act.startup"),
                            actionURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension", snoozeDays: 30))
      }
    }

    // Apps not opened for a long time (Spotlight's last-used date), at least 100 MB, not Apple's own.
    let cutoff = Date().addingTimeInterval(-Double(unusedDays) * 86400)
    let running = await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }) }
    var unused: [(String, Double, String)] = []
    for dir in [URL(fileURLWithPath: "/Applications"), h("Applications")] {
      for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "app" {
        if running.contains(f.path) { continue }
        if let b = Bundle(url: f)?.bundleIdentifier, b.hasPrefix("com.apple.") { continue }
        guard let item = MDItemCreateWithURL(nil, f as CFURL) else { continue }
        // Installed recently: not "unused", even if never opened yet.
        let added = (MDItemCopyAttribute(item, kMDItemDateAdded) as? Date)
          ?? (try? f.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
        if let added, added > cutoff { continue }
        let used = (MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date) ?? added
        guard let used, used < cutoff else { continue }
        let bytes = (MDItemCopyAttribute(item, "kMDItemPhysicalSize" as CFString) as? NSNumber)?.doubleValue
          ?? (MDItemCopyAttribute(item, kMDItemFSSize) as? NSNumber)?.doubleValue ?? 0
        if bytes >= 100_000_000 { unused.append((f.deletingPathExtension().lastPathComponent, bytes, f.path)) }
      }
    }
    unused.sort { $0.1 > $1.1 }
    if !unused.isEmpty {
      let names = unused.prefix(5).map { "\($0.0) (\(fmt($0.1)) GB)" }.joined(separator: ", ")
      r.tips.append(.init(sig: "apps:\(unused.map(\.0).joined(separator: ","))", text: T("adv.apps", unusedDays, names),
                          ctx: unused.map { "\($0.2) \(fmt($0.1)) GB" }.joined(separator: "; "),
                          actionLabel: T("adv.act.apps"), actionURL: "/Applications", snoozeDays: 30))
    }

    // macOS updates waiting to be installed.
    if let d = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.SoftwareUpdate.plist"),
       let rec = d["RecommendedUpdates"] as? [[String: Any]], !rec.isEmpty {
      let names = rec.compactMap { $0["Display Name"] as? String }.prefix(3).joined(separator: ", ")
      r.tips.append(.init(sig: "updates", text: T("adv.updates", names.isEmpty ? "macOS" : names), ctx: "", actionLabel: T("adv.act.update"),
                          actionURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension", snoozeDays: 1))
    }

    // Uptime.
    var bt = timeval()
    var size = MemoryLayout<timeval>.stride
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    if sysctl(&mib, 2, &bt, &size, nil, 0) == 0 {
      let days = Int(Date().timeIntervalSince1970 - Double(bt.tv_sec)) / 86400
      if days >= uptimeDays {
        r.tips.append(.init(sig: "uptime", text: T("adv.uptime", days), ctx: "", actionLabel: "", actionURL: "", snoozeDays: 2))
      }
    }

    // Memory and CPU hogs, grouped by command.
    let ram = Double(ProcessInfo.processInfo.physicalMemory)
    let ps = await Proc.run("/bin/ps", ["-axco", "rss=,%cpu=,comm="], timeout: 20)
    var mem: [String: Double] = [:], cpu: [String: Double] = [:]
    for line in ps.text.split(separator: "\n") {
      let p = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard p.count == 3, let rss = Double(p[0]), let c = Double(p[1].replacingOccurrences(of: ",", with: ".")) else { continue }
      let name = String(p[2]).trimmingCharacters(in: .whitespaces)
      mem[name, default: 0] += rss * 1024
      cpu[name, default: 0] += c
    }
    for (name, bytes) in mem where bytes / ram * 100 >= memPercent && name != "kernel_task" {
      r.tips.append(.init(sig: "mem:\(name)", text: T("adv.mem", name, fmt(bytes), Int(bytes / ram * 100)), ctx: "",
                          actionLabel: T("adv.act.activity"), actionURL: "/System/Applications/Utilities/Activity Monitor.app",
                          snoozeDays: 1))
    }
    let hot = cpu.filter { $0.value >= 80 && $0.key != "kernel_task" && $0.key != "WindowServer" }
    r.cpuNow = hot.keys.sorted()
    for (name, c) in hot where cpuSeen.contains(name) {
      r.tips.append(.init(sig: "cpu:\(name)", text: T("adv.cpu", name, Int(c)), ctx: "",
                          actionLabel: T("adv.act.activity"), actionURL: "/System/Applications/Utilities/Activity Monitor.app",
                          snoozeDays: 1))
    }
    return r
  }
}
