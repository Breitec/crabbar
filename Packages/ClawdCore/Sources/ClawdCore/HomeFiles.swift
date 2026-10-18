import Foundation
import CryptoKit

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

  /// Task files keep their creation date when rewritten: an `at` task counts its times from when it first appeared.
  static func rewrite(_ u: URL, _ s: String) {
    let made = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.creationDate] as? Date
    write(u, s)
    if let made { try? FileManager.default.setAttributes([.creationDate: made], ofItemAtPath: u.path) }
  }

  /// "---\nkey: value\n---\nbody" -> (front matter lines, body); nil when there is none.
  /// Only spaces or tabs after the opening "---": `\s*` there made many blank lines without a closing "---"
  /// take quadratic time.
  static func frontMatter(_ raw: String) -> (String, String)? {
    guard let re = try? NSRegularExpression(pattern: #"(?s)^\s*---[ \t]*\r?\n(.*?)\r?\n---\s*\r?\n?(.*)$"#),
          let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
          let h = Range(m.range(at: 1), in: raw), let b = Range(m.range(at: 2), in: raw) else { return nil }
    return (String(raw[h]), String(raw[b]))
  }

  /// "key: value" lines; without regex, as a value with many spaces inside would take quadratic time.
  static func keyValues(_ head: String) -> [String: String] {
    var out: [String: String] = [:]
    for line in head.split(whereSeparator: \.isNewline) {
      guard let k = headerKey(line), let c = line.firstIndex(of: ":") else { continue }
      out[k] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
    }
    return out
  }

  /// "  Tools : x" -> "tools"; nil for a line that is not "key: value".
  static func headerKey(_ line: Substring) -> String? {
    guard let c = line.firstIndex(of: ":") else { return nil }
    let k = line[..<c].trimmingCharacters(in: .whitespaces)
    guard !k.isEmpty, k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
    return k.lowercased()
  }

  // MARK: - reminders

  public struct Reminder: Identifiable, Equatable, Sendable {
    public var path: URL
    public var rel: String
    public var at: Date
    public var text: String
    public var repeats: RemindRepeat?
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
      var repeats: RemindRepeat?
      var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if let (h, b) = Self.frontMatter(raw) {
        let kv = Self.keyValues(h)
        if let a = kv["at"] { at = Format.parseISO(a) }
        repeats = kv["repeat"].flatMap(RemindRepeat.word)
        text = b.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let base = u.deletingPathExtension().lastPathComponent
      let fromName = Self.dateFromName(base)
      if at == nil { at = fromName?.0 }
      guard let at else { continue }
      if text.isEmpty { text = fromName?.1 ?? base }
      out.append(Reminder(path: u, rel: rel, at: at, text: text, repeats: repeats))
    }
    return out.sorted { $0.at < $1.at }
  }

  @discardableResult
  public func newReminder(at: Date, text: String, repeats: RemindRepeat? = nil) -> URL {
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
    let rep = repeats.map { "repeat: \($0.rawValue)\n" } ?? ""
    Self.write(u, "---\nat: \(Format.iso(at))\n\(rep)---\n\(text)\n")
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

  /// Fires a due reminder: its file goes to done, and a repeating one leaves a file for its next time after
  /// `now` (the Mac may have been off for a few of them).
  @discardableResult
  public func fire(_ r: Reminder, now: Date = Date()) -> (done: URL?, next: URL?) {
    let done = markDone(r)
    guard let rep = r.repeats, let at = rep.next(after: now, from: r.at) else { return (done, nil) }
    return (done, newReminder(at: at, text: r.text, repeats: rep))
  }

  /// Moving one is a new file for the new time (the time is in the file name too); a repeating one keeps
  /// repeating, from the new time.
  @discardableResult
  public func moveReminder(_ r: Reminder, to at: Date, text: String? = nil) -> URL {
    try? FileManager.default.removeItem(at: r.path)
    return newReminder(at: at, text: text ?? r.text, repeats: r.repeats)
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
    /// `at: 09:00, 18:00` instead of `every`: minutes after midnight, sorted.
    public var at: [Int]?
    public var atText = ""
    public var tools: [String] = []
    public var model = ""
    public var hours: (Int, Int)?
    public var limit: Int?
    public var paused = false
    public var prompt = ""
    public var id: String { name }
    public var created: Date? { (try? FileManager.default.attributesOfItem(atPath: path.path))?[.creationDate] as? Date }

    public static func == (a: TaskFile, b: TaskFile) -> Bool {
      a.name == b.name && a.path == b.path && a.everyText == b.everyText && a.atText == b.atText && a.tools == b.tools &&
        a.model == b.model && a.hours?.0 == b.hours?.0 && a.hours?.1 == b.hours?.1 &&
        a.limit == b.limit && a.paused == b.paused && a.prompt == b.prompt
    }

    /// Only between these hours; "22-7" spans midnight.
    public func inHours(_ now: Date = Date()) -> Bool {
      guard let (a, b) = hours else { return true }
      let h = Calendar.current.component(.hour, from: now)
      return a <= b ? (h >= a && h < b) : (h >= a || h < b)
    }

    /// The latest of the `at` times that has come: today's, or yesterday's last one.
    public func slot(_ now: Date = Date()) -> Date? {
      guard let at, let last = at.last else { return nil }
      let cal = RemindWhen.calendar
      let today = cal.startOfDay(for: now)
      func time(_ day: Date, _ m: Int) -> Date? { cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day) }
      if let d = at.compactMap({ time(today, $0) }).filter({ $0 <= now }).max() { return d }
      return cal.date(byAdding: .day, value: -1, to: today).flatMap { time($0, last) }
    }

    /// An `at` task runs once per time of day; a time missed while the Mac was asleep or off, once when it is
    /// on again. A new task waits for its next time instead of going off for one already past.
    public func dueAt(lastRun: Date?, created: Date?, now: Date = Date()) -> Bool {
      guard let s = slot(now) else { return false }
      return s > max(lastRun ?? .distantPast, created ?? .distantPast)
    }

    public var whenText: String { ClawdHome.whenText(every: every, at: at) }

    /// SHA-256 over what a run does: the prompt, the tools, the model and when it runs. An approval holds for
    /// this content only, so a rewritten task file asks again. `paused` and `limit` don't count, nor does
    /// spelling (line endings, trailing spaces, tool order, "10m" or "10 min").
    public var fingerprint: String {
      // No regex here: a line of many spaces would make one take quadratic time, on every tick.
      let text = prompt.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
          var end = line.endIndex
          while end > line.startIndex, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
          return line[..<end]
        }
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      let when: String = at.map { $0.map(String.init).joined(separator: ",") } ?? ""
      let span: String = hours.map { "\($0.0)-\($0.1)" } ?? ""
      let parts: [String] = [
        "task-v1",
        text,
        Set(tools).sorted().joined(separator: "\n"),
        model.trimmingCharacters(in: .whitespaces),
        every.map { String(format: "%.0f", $0) } ?? "",
        when,
        span,
      ]
      // Length before each part: no prompt can pass for a different split into fields.
      let joined = parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "\n")
      return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The tools still to approve: all of them unless `approved` was given for this content, and also when
    /// the task was seen paused but runs again without the panel's Resume (`pauseSeen`; a file edited from
    /// outside, Claude's phone session).
    public func unapproved(approved: [String]?, approvedFor: String?, pauseSeen: Bool) -> [String] {
      guard approvedFor == fingerprint, paused || !pauseSeen else { return tools }
      let ok = Set(approved ?? [])
      return tools.filter { !ok.contains($0) }
    }
  }

  /// A task's text for its approval card: characters that don't show (zero-width spaces, bidi overrides,
  /// tag characters, variation selectors, control characters) appear as [U+XXXX], so nothing hides in it.
  public static func visibleText(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    let lines = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    for u in lines.unicodeScalars {
      let p = u.properties
      var hidden = p.isDefaultIgnorableCodePoint
      switch p.generalCategory {
      case .format, .lineSeparator, .paragraphSeparator: hidden = true
      case .control: hidden = u != "\n" && u != "\t"
      default: break
      }
      if hidden { out.append(contentsOf: String(format: "[U+%04X]", u.value).unicodeScalars) } else { out.append(u) }
    }
    return String(out)
  }

  /// How often, for the panel and the chat: "at 09:00, 18:00" or "every 10 min"; `at` wins over `every`.
  public static func whenText(every: TimeInterval?, at: [Int]?) -> String {
    if let at { return T("task.at", at.map(formatAt).joined(separator: ", ")) }
    if let every { return formatEvery(every) }
    return T("task.badEvery")
  }

  /// "09:00, 18:00", "9", "9h30" -> minutes after midnight, sorted; nil if any of them is not a time of day.
  /// As with `every`, runs are at least two minutes apart: a time closer to the one before is dropped, also
  /// across midnight.
  public static func parseAt(_ s: String) -> [Int]? {
    guard let re = try? NSRegularExpression(pattern: #"^(\d{1,2})(?:[:.h](\d{2})|h)?$"#) else { return nil }
    var out = Set<Int>()
    for w in s.lowercased().split(whereSeparator: { ",; \t".contains($0) }) {
      let ns = String(w) as NSString
      guard let m = re.firstMatch(in: String(w), range: NSRange(location: 0, length: ns.length)),
            let h = Int(ns.substring(with: m.range(at: 1))), h <= 23 else { return nil }
      let mi = m.range(at: 2).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: 2))) ?? 0
      if mi > 59 { return nil }
      out.insert(h * 60 + mi)
    }
    var kept: [Int] = []
    for m in out.sorted() where kept.last.map({ m - $0 >= 2 }) ?? true { kept.append(m) }
    if kept.count > 1, let first = kept.first, let last = kept.last, first + 1440 - last < 2 { kept.removeLast() }
    return kept.isEmpty ? nil : kept
  }

  public static func formatAt(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }

  /// "10m", "2h", "1d", "30 min", "2 Std" -> seconds; at least two minutes, nil above a year.
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
    return secs <= 366 * 86400 ? secs : nil
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
        if let a = kv["at"] { t.atText = a; t.at = Self.parseAt(a) }
        if let tl = kv["tools"] { t.tools = Self.splitTools(tl).filter(Self.isValidToolRule) }
        if let m = kv["model"] { t.model = m }
        if let p = kv["paused"] { t.paused = Self.isYes(p) }
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

  /// By name; ignoring case as the Mac's file system does, so "mail" is the task in Mail.md.
  public func task(named n: String) -> TaskFile? {
    let all = taskFiles()
    return all.first { $0.name == n } ?? all.first { $0.name.compare(n, options: .caseInsensitive) == .orderedSame }
  }

  /// A `task` block over the task it replaces: what it leaves out of `paused` and `limit` stays as it was.
  /// `resumes` - it unpauses a paused task, which then needs approval again (`paused` is not in the fingerprint).
  public static func mergedHead(_ head: [String: String], over old: TaskFile?) -> (head: [String: String], resumes: Bool) {
    guard let old else { return (head, false) }
    var h = head
    if (h["limit"] ?? "").isEmpty, let l = old.limit { h["limit"] = "\(l)" }
    if (h["paused"] ?? "").isEmpty {
      if old.paused { h["paused"] = "yes" }
      return (h, false)
    }
    return (h, old.paused && !isYes(h["paused"] ?? ""))
  }

  /// "paused: yes" and the like.
  public static func isYes(_ v: String) -> Bool { ["yes", "true", "1", "ja"].contains(v.trimmingCharacters(in: .whitespaces).lowercased()) }

  @discardableResult
  public func newTask(name: String, head: [String: String], prompt: String) -> URL? {
    let file = Self.safeName(name)
    if file.isEmpty { return nil }
    var lines = ["---"]
    for k in ["every", "at", "tools", "model", "hours", "limit", "paused"] {
      if let v = head[k], !v.isEmpty { lines.append("\(k): \(v)") }
    }
    lines += ["---", prompt.trimmingCharacters(in: .whitespacesAndNewlines), ""]
    let u = tasks.appendingPathComponent("\(file).md")
    Self.rewrite(u, lines.joined(separator: "\n"))
    return u
  }

  public func removeTask(_ name: String) -> TaskFile? {
    guard let t = task(named: name.trimmingCharacters(in: .whitespaces)) else { return nil }
    do { try FileManager.default.removeItem(at: t.path) } catch { return nil }
    return t
  }

  public func setTaskPaused(_ t: TaskFile, _ paused: Bool) {
    guard let raw = Self.read(t.path) else { return }
    Self.rewrite(t.path, Self.settingHeader(raw, "paused", paused ? "yes" : nil))
  }

  /// Rewrites the task's `tools:` line with the granted rules added.
  public func grantTools(_ t: TaskFile, _ rules: [String]) -> Bool {
    guard let raw = Self.read(t.path) else { return false }
    let all = t.tools + rules.filter { !t.tools.contains($0) }
    Self.rewrite(t.path, Self.settingHeader(raw, "tools", all.joined(separator: " ")))
    return true
  }

  /// The file with one front-matter key set, or removed with nil. Only the header changes: the text below
  /// stays as it is (a "tools:" line in it too), so the task's fingerprint changes only by that key.
  /// Line endings become "\n", which also makes a CRLF file work.
  static func settingHeader(_ raw: String, _ key: String, _ value: String?) -> String {
    let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
    var head: [String] = []
    var body = text
    if let (h, b) = frontMatter(text) {
      head = h.isEmpty ? [] : h.components(separatedBy: "\n")
      body = b
    } else if value == nil {
      return text
    }
    var out: [String] = []
    var set = value == nil
    for line in head {
      if headerKey(line[...]) == key {
        if !set, let value { out.append("\(key): \(value)"); set = true }
        continue
      }
      out.append(line)
    }
    if !set, let value { out.insert("\(key): \(value)", at: 0) }
    // An empty header still needs its blank line, or "---\n---" would not count as one.
    return "---\n" + out.joined(separator: "\n") + "\n---\n" + body
  }
}
#endif
