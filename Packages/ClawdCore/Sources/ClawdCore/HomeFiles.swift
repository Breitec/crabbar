import Foundation

#if os(macOS)

/// Clawd's home folder (default ~/Clawd): reminders, lists and tasks are plain markdown files,
/// so the panel chat, Clawd's own phone session or the user can make them.
public struct ClawdHome: Sendable {
  public var url: URL

  public init(url: URL) { self.url = url }

  public static var defaultURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Clawd") }

  public var reminders: URL { url.appendingPathComponent("reminders") }
  public var lists: URL { url.appendingPathComponent("lists") }
  public var tasks: URL { url.appendingPathComponent("tasks") }

  public func ensure() {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  public static func safeName(_ s: String) -> String {
    s.replacingOccurrences(of: #"[\\/:*?"<>|\r\n]"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }

  static func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }

  static func write(_ u: URL, _ s: String) {
    try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? s.data(using: .utf8)?.write(to: u, options: .atomic)
  }

  /// "---\nkey: value\n---\nbody" -> (front matter lines, body); nil when there is none.
  static func frontMatter(_ raw: String) -> (String, String)? {
    guard let re = try? NSRegularExpression(pattern: #"(?s)^\s*---\s*\r?\n(.*?)\r?\n---\s*\r?\n?(.*)$"#),
          let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
          let h = Range(m.range(at: 1), in: raw), let b = Range(m.range(at: 2), in: raw) else { return nil }
    return (String(raw[h]), String(raw[b]))
  }

  static func keyValues(_ head: String) -> [String: String] {
    var out: [String: String] = [:]
    for line in head.split(whereSeparator: \.isNewline) {
      guard let re = try? NSRegularExpression(pattern: #"^\s*(\w+)\s*:\s*(.*?)\s*$"#),
            let m = re.firstMatch(in: String(line), range: NSRange(line.startIndex..., in: line)),
            let k = Range(m.range(at: 1), in: line), let v = Range(m.range(at: 2), in: line) else { continue }
      out[line[k].lowercased()] = String(line[v])
    }
    return out
  }

  // MARK: - reminders

  public struct Reminder: Identifiable, Equatable, Sendable {
    public var path: URL
    public var rel: String
    public var at: Date
    public var text: String
    public var id: String { path.path }
  }

  static let nameDate = #"^(\d{4}-\d{2}-\d{2})[ T](\d{2})-(\d{2})\s*(.*)$"#

  static func dateFromName(_ base: String) -> (Date, String)? {
    guard let re = try? NSRegularExpression(pattern: nameDate),
          let m = re.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) else { return nil }
    let ns = base as NSString
    let s = "\(ns.substring(with: m.range(at: 1))) \(ns.substring(with: m.range(at: 2))):\(ns.substring(with: m.range(at: 3)))"
    guard let d = Format.parseISO(s) else { return nil }
    return (d, ns.substring(with: m.range(at: 4)))
  }

  /// Active reminders, soonest first (everything outside reminders/done).
  public func activeReminders() -> [Reminder] {
    guard let en = FileManager.default.enumerator(atPath: reminders.path) else { return [] }
    var out: [Reminder] = []
    for case let rel as String in en where rel.lowercased().hasSuffix(".md") {
      if rel.hasPrefix("done/") { continue }
      let u = reminders.appendingPathComponent(rel)
      guard let raw = Self.read(u) else { continue }
      var at: Date?
      var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if let (h, b) = Self.frontMatter(raw) {
        if let a = Self.keyValues(h)["at"] { at = Format.parseISO(a) }
        text = b.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let base = u.deletingPathExtension().lastPathComponent
      let fromName = Self.dateFromName(base)
      if at == nil { at = fromName?.0 }
      guard let at else { continue }
      if text.isEmpty { text = fromName?.1 ?? base }
      out.append(Reminder(path: u, rel: rel, at: at, text: text))
    }
    return out.sorted { $0.at < $1.at }
  }

  @discardableResult
  public func newReminder(at: Date, text: String) -> URL {
    let dir = reminders.appendingPathComponent(ym(at))
    var title = Self.safeName(text)
    if title.count > 50 { title = String(title.prefix(50)).trimmingCharacters(in: .whitespaces) }
    let base = "\(stamp(at)) \(title)"
    var u = dir.appendingPathComponent("\(base).md")
    var i = 2
    while FileManager.default.fileExists(atPath: u.path) {
      u = dir.appendingPathComponent("\(base) (\(i)).md")
      i += 1
    }
    Self.write(u, "---\nat: \(Format.iso(at))\n---\n\(text)\n")
    return u
  }

  func ym(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM"
    return f.string(from: d)
  }

  func stamp(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH-mm"
    return f.string(from: d)
  }

  /// By path relative to the reminders folder, or by file name with or without extension.
  public func removeReminder(_ name: String) -> Reminder? {
    let n = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      .replacingOccurrences(of: "\\", with: "/")
    for r in activeReminders() {
      if r.rel == n || r.path.lastPathComponent == n || r.path.deletingPathExtension().lastPathComponent == n {
        try? FileManager.default.removeItem(at: r.path)
        return r
      }
    }
    return nil
  }

  /// A fired reminder moves to reminders/done/yyyy-MM.
  @discardableResult
  public func markDone(_ r: Reminder) -> URL? {
    let dir = reminders.appendingPathComponent("done").appendingPathComponent(ym(r.at))
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let to = dir.appendingPathComponent(r.path.lastPathComponent)
    try? FileManager.default.removeItem(at: to)
    do { try FileManager.default.moveItem(at: r.path, to: to); return to } catch { return nil }
  }

  public func moveReminder(_ r: Reminder, to at: Date, text: String? = nil) -> URL {
    try? FileManager.default.removeItem(at: r.path)
    return newReminder(at: at, text: text ?? r.text)
  }

  /// Recently fired ones, newest first.
  public func doneReminders(count: Int = 5) -> [(at: Date, text: String, path: URL)] {
    let dir = reminders.appendingPathComponent("done")
    guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
    var files: [URL] = []
    for case let u as URL in en where u.pathExtension.lowercased() == "md" { files.append(u) }
    files.sort { $0.lastPathComponent > $1.lastPathComponent }
    var out: [(Date, String, URL)] = []
    for u in files.prefix(count) {
      guard let (at, name) = Self.dateFromName(u.deletingPathExtension().lastPathComponent) else { continue }
      var text = name
      if let raw = Self.read(u), let (_, b) = Self.frontMatter(raw), !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        text = b.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      out.append((at, text, u))
    }
    return out
  }

  // MARK: - lists

  public struct ListItem: Equatable, Identifiable, Sendable {
    public var idx: Int
    public var done: Bool
    public var text: String
    public var id: Int { idx }
  }

  public func listNames(defaultName: String) -> [String] {
    let fm = FileManager.default
    if !fm.fileExists(atPath: lists.path) {
      try? fm.createDirectory(at: lists, withIntermediateDirectories: true)
      _ = newList(defaultName)
    }
    let files = (try? fm.contentsOfDirectory(at: lists, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension.lowercased() == "md" }
      .map { $0.deletingPathExtension().lastPathComponent }
      .sorted { $0.localizedCompare($1) == .orderedAscending }
  }

  func listURL(_ name: String) -> URL { lists.appendingPathComponent("\(name).md") }

  public func readList(_ name: String) -> (lines: [String], items: [ListItem]) {
    var lines = (Self.read(listURL(name)) ?? "").components(separatedBy: "\n").map {
      $0.hasSuffix("\r") ? String($0.dropLast()) : $0
    }
    if lines.last == "" { lines.removeLast() }
    var items: [ListItem] = []
    let re = try? NSRegularExpression(pattern: #"^\s*[-*]\s+\[( |x|X)\]\s*(.*)$"#)
    for (i, l) in lines.enumerated() {
      guard let m = re?.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) else { continue }
      let ns = l as NSString
      items.append(ListItem(idx: i, done: ns.substring(with: m.range(at: 1)) != " ",
                            text: ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)))
    }
    return (lines, items)
  }

  func saveList(_ name: String, _ lines: [String]) {
    Self.write(listURL(name), lines.joined(separator: "\n") + "\n")
  }

  @discardableResult
  public func newList(_ name: String) -> String? {
    let n = Self.safeName(name)
    if n.isEmpty { return nil }
    if !FileManager.default.fileExists(atPath: listURL(n).path) { saveList(n, ["# \(n)", ""]) }
    return n
  }

  public func removeList(_ name: String) { try? FileManager.default.removeItem(at: listURL(name)) }

  /// Several at once: "milk, bread" or one per line.
  public func addListItems(_ name: String, _ text: String) {
    guard let n = newList(name) else { return }
    var lines = readList(n).lines
    for t in text.components(separatedBy: CharacterSet(charactersIn: ",;\r\n")) {
      let s = t.trimmingCharacters(in: .whitespaces)
      if !s.isEmpty { lines.append("- [ ] \(s)") }
    }
    saveList(n, lines)
  }

  func findItem(_ l: (lines: [String], items: [ListItem]), _ what: String) -> ListItem? {
    let w = what.trimmingCharacters(in: .whitespaces)
    return l.items.first { $0.text == w } ?? l.items.first { $0.text.lowercased() == w.lowercased() }
  }

  @discardableResult
  public func setListItem(_ name: String, text: String? = nil, idx: Int? = nil, done: Bool) -> Bool {
    let l = readList(name)
    guard let it = idx.flatMap({ i in l.items.first { $0.idx == i } }) ?? text.flatMap({ findItem(l, $0) }) else { return false }
    var lines = l.lines
    lines[it.idx] = "- [\(done ? "x" : " ")] \(it.text)"
    saveList(name, lines)
    return true
  }

  @discardableResult
  public func removeListItem(_ name: String, text: String? = nil, idx: Int? = nil) -> Bool {
    let l = readList(name)
    guard let it = idx.flatMap({ i in l.items.first { $0.idx == i } }) ?? text.flatMap({ findItem(l, $0) }) else { return false }
    var lines = l.lines
    lines.remove(at: it.idx)
    saveList(name, lines)
    return true
  }

  public func clearListDone(_ name: String) {
    let l = readList(name)
    let drop = Set(l.items.filter(\.done).map(\.idx))
    saveList(name, l.lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element))
  }

  // MARK: - tasks

  public struct TaskFile: Identifiable, Equatable, Sendable {
    public var name: String
    public var path: URL
    public var every: TimeInterval?
    public var everyText = ""
    public var tools: [String] = []
    public var model = ""
    public var hours: (Int, Int)?
    public var limit: Int?
    public var paused = false
    public var prompt = ""
    public var id: String { name }

    public static func == (a: TaskFile, b: TaskFile) -> Bool {
      a.name == b.name && a.path == b.path && a.everyText == b.everyText && a.tools == b.tools &&
        a.model == b.model && a.hours?.0 == b.hours?.0 && a.hours?.1 == b.hours?.1 &&
        a.limit == b.limit && a.paused == b.paused && a.prompt == b.prompt
    }

    /// Only between these hours; "22-7" spans midnight.
    public func inHours(_ now: Date = Date()) -> Bool {
      guard let (a, b) = hours else { return true }
      let h = Calendar.current.component(.hour, from: now)
      return a <= b ? (h >= a && h < b) : (h >= a || h < b)
    }
  }

  /// "10m", "2h", "1d", "30 min", "2 Std" -> seconds; at least two minutes.
  public static func parseEvery(_ s: String) -> TimeInterval? {
    let pattern = #"^(\d+)\s*(m|min|mins|minuten?|minutes?|h|std|stunden?|hours?|d|t|tage?|days?)$"#
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s.trimmingCharacters(in: .whitespaces).lowercased(),
                                range: NSRange(location: 0, length: (s.trimmingCharacters(in: .whitespaces) as NSString).length))
    else { return nil }
    let ns = s.trimmingCharacters(in: .whitespaces).lowercased() as NSString
    guard let n = Double(ns.substring(with: m.range(at: 1))) else { return nil }
    let u = ns.substring(with: m.range(at: 2))
    var secs: Double
    if u.hasPrefix("m") { secs = n * 60 }
    else if u.hasPrefix("h") || u.hasPrefix("s") { secs = n * 3600 }
    else { secs = n * 86400 }
    if secs < 120 { secs = 120 }
    return secs
  }

  public static func formatEvery(_ secs: TimeInterval) -> String {
    let d = secs / 86400, h = secs / 3600
    if d >= 1 && d == d.rounded(.down) { return T("task.everyD", Int(d)) }
    if h >= 1 && h == h.rounded(.down) { return T("task.everyH", Int(h)) }
    return T("task.everyM", Int(secs / 60))
  }

  /// "mcp__mail, Bash(gh issue list:*) WebFetch(domain:github.com)": spaces or commas, but a rule's
  /// parentheses may hold spaces of their own.
  /// A permission rule a task may ask for: an MCP server or tool, a command by its first words,
  /// a site, web search or the read tools. Bare `Bash`, write tools and anything starting with "-" are not.
  public static func isValidToolRule(_ s: String) -> Bool {
    let pattern = #"^(mcp__[A-Za-z0-9_.-]+(__[A-Za-z0-9_*.-]+)?|Bash\([^()\-][^()]*\)|WebFetch\(domain:[A-Za-z0-9.*-]+\)|WebFetch|WebSearch|Read|Glob|Grep)$"#
    return s.range(of: pattern, options: .regularExpression) != nil
  }

  public static func splitTools(_ v: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: #"[^\s,()]+(?:\([^)]*\))?"#) else { return [] }
    return re.matches(in: v, range: NSRange(v.startIndex..., in: v)).compactMap { Range($0.range, in: v).map { String(v[$0]) } }
  }

  public func taskFiles() -> [TaskFile] {
    let files = ((try? FileManager.default.contentsOfDirectory(at: tasks, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension.lowercased() == "md" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var out: [TaskFile] = []
    for u in files {
      guard let raw = Self.read(u) else { continue }
      var t = TaskFile(name: u.deletingPathExtension().lastPathComponent, path: u,
                       prompt: raw.trimmingCharacters(in: .whitespacesAndNewlines))
      if let (h, b) = Self.frontMatter(raw) {
        t.prompt = b.trimmingCharacters(in: .whitespacesAndNewlines)
        let kv = Self.keyValues(h)
        if let e = kv["every"] { t.everyText = e; t.every = Self.parseEvery(e) }
        if let tl = kv["tools"] { t.tools = Self.splitTools(tl).filter(Self.isValidToolRule) }
        if let m = kv["model"] { t.model = m }
        if let p = kv["paused"] { t.paused = ["yes", "true", "1", "ja"].contains(p.lowercased()) }
        if let l = kv["limit"], let re = try? NSRegularExpression(pattern: #"^(\d{1,3})\s*%?$"#),
           let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) {
          t.limit = Int((l as NSString).substring(with: m.range(at: 1)))
        }
        if let hv = kv["hours"], let re = try? NSRegularExpression(pattern: #"^(\d{1,2})(?::00)?\s*-\s*(\d{1,2})(?::00)?$"#),
           let m = re.firstMatch(in: hv, range: NSRange(hv.startIndex..., in: hv)) {
          let ns = hv as NSString
          t.hours = (Int(ns.substring(with: m.range(at: 1))) ?? 0, Int(ns.substring(with: m.range(at: 2))) ?? 0)
        }
      }
      out.append(t)
    }
    return out
  }

  public func task(named n: String) -> TaskFile? { taskFiles().first { $0.name == n } }

  @discardableResult
  public func newTask(name: String, head: [String: String], prompt: String) -> URL? {
    let file = Self.safeName(name)
    if file.isEmpty { return nil }
    var lines = ["---"]
    for k in ["every", "tools", "model", "hours", "limit", "paused"] {
      if let v = head[k], !v.isEmpty { lines.append("\(k): \(v)") }
    }
    lines += ["---", prompt.trimmingCharacters(in: .whitespacesAndNewlines), ""]
    let u = tasks.appendingPathComponent("\(file).md")
    Self.write(u, lines.joined(separator: "\n"))
    return u
  }

  public func removeTask(_ name: String) -> TaskFile? {
    guard let t = task(named: name.trimmingCharacters(in: .whitespaces)) else { return nil }
    do { try FileManager.default.removeItem(at: t.path) } catch { return nil }
    return t
  }

  public func setTaskPaused(_ t: TaskFile, _ paused: Bool) {
    guard var raw = Self.read(t.path) else { return }
    raw = raw.replacingOccurrences(of: #"(?m)^\s*paused\s*:.*\r?\n"#, with: "", options: .regularExpression)
    if paused {
      if raw.range(of: #"^\s*---\s*\r?\n"#, options: .regularExpression) != nil {
        raw = raw.replacingOccurrences(of: #"^(\s*---\s*\r?\n)"#, with: "$1paused: yes\n", options: .regularExpression)
      } else {
        raw = "---\npaused: yes\n---\n" + raw
      }
    }
    Self.write(t.path, raw)
  }

  /// Rewrites the task's `tools:` line with the granted rules added.
  public func grantTools(_ t: TaskFile, _ rules: [String]) -> Bool {
    guard var raw = Self.read(t.path) else { return false }
    let all = t.tools + rules.filter { !t.tools.contains($0) }
    let line = "tools: " + all.joined(separator: " ")
    let esc = NSRegularExpression.escapedTemplate(for: line)
    if raw.range(of: #"(?m)^\s*tools\s*:"#, options: .regularExpression) != nil {
      raw = raw.replacingOccurrences(of: #"(?m)^\s*tools\s*:.*$"#, with: esc, options: .regularExpression)
    } else if raw.range(of: #"^\s*---\s*\r?\n"#, options: .regularExpression) != nil {
      raw = raw.replacingOccurrences(of: #"^(\s*---\s*\r?\n)"#, with: "$1" + esc + "\n", options: .regularExpression)
    } else {
      raw = "---\n\(line)\n---\n" + raw
    }
    Self.write(t.path, raw)
    return true
  }
}
#endif
