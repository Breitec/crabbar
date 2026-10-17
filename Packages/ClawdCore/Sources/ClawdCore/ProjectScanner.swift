import Foundation

#if os(macOS)

/// Tokens of every assistant reply in ~/.claude/projects over the last week, weighted by model price,
/// by project and hour. Reads only what was appended since the last scan.
public final class ProjectScanner {
  public struct Result: Sendable {
    public var total: [String: Double] = [:]
    public var hours: [Int: [String: Double]] = [:]
    public var paths: [String: String] = [:]
    public var empty: Bool { total.values.reduce(0, +) <= 0 }

    public init() {}
  }

  struct FileState: Codable {
    var pos: UInt64 = 0
    var ids: Set<String> = []
    var dir: String
    var cwd: String?
    var w: [Int: Double] = [:]
  }

  static let prices: [(String, Double)] = [("fable", 10), ("mythos", 10), ("opus-5-5", 4), ("opus", 5),
                                           ("sonnet-5", 2), ("sonnet", 3), ("haiku-5", 0.1), ("haiku", 1)]
  static let kinds: [(String, Double)] = [("input_tokens", 1), ("cache_creation_input_tokens", 1.25),
                                          ("cache_read_input_tokens", 0.1), ("output_tokens", 5)]

  var cache: [String: FileState] = [:]
  let root: URL
  let cacheURL: URL?

  public init(root: URL, cacheURL: URL?) {
    self.root = root
    self.cacheURL = cacheURL
    if let u = cacheURL, let d = try? Data(contentsOf: u),
       let c = try? JSONDecoder().decode([String: FileState].self, from: d) { cache = c }
  }

  static func match(_ line: String, _ pattern: String) -> String? {
    guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
    let s = String(line[r])
    guard let q = s.firstIndex(of: ":") else { return nil }
    return String(s[s.index(after: q)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  }

  public func scan(now: Date = Date()) -> Result {
    let since = now.addingTimeInterval(-7 * 86400)
    let first = Int(since.timeIntervalSince1970 / 3600)
    let fm = FileManager.default
    var seen = Set<String>()
    let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    for pd in dirs {
      guard let en = fm.enumerator(at: pd, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
      for case let f as URL in en where f.pathExtension == "jsonl" {
        let rv = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let mod = rv?.contentModificationDate, mod >= since else { continue }
        let size = UInt64(rv?.fileSize ?? 0)
        let key = f.path
        seen.insert(key)
        var c = cache[key] ?? FileState(dir: pd.lastPathComponent)
        if size < c.pos { c = FileState(dir: pd.lastPathComponent) }
        if size == c.pos { cache[key] = c; continue }
        guard let h = try? FileHandle(forReadingFrom: f) else { continue }
        try? h.seek(toOffset: c.pos)
        let data = h.readDataToEndOfFile()
        try? h.close()
        guard let nl = data.lastIndex(of: 10) else { cache[key] = c; continue }
        let chunk = data[data.startIndex...nl]
        c.pos += UInt64(chunk.count)
        let text = String(decoding: chunk, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
          let l = String(line)
          if c.cwd == nil, let cwd = Self.match(l, #""cwd":"((?:[^"\\]|\\.)*)""#) {
            c.cwd = cwd.replacingOccurrences(of: "\\\\", with: "\\")
          }
          guard l.contains("\"usage\":{\"input_tokens\"") else { continue }
          if let id = Self.match(l, #""id":"(msg_[^"]+)""#) {
            if c.ids.contains(id) { continue }
            c.ids.insert(id)
          }
          let model = Self.match(l, #""model":"([^"]+)""#) ?? ""
          if model == "<synthetic>" { continue }
          guard let ts = Self.match(l, #""timestamp":"([^"]+)""#),
                let at = ISO8601DateFormatter.full.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) else { continue }
          let hour = Int(at.timeIntervalSince1970 / 3600)
          if hour < first { continue }
          let price = Self.prices.first { model.contains($0.0) }?.1 ?? 3
          var tok = 0.0
          for (k, m) in Self.kinds {
            if let v = Self.match(l, "\"\(k)\":(\\d+)"), let n = Double(v) { tok += m * n }
          }
          c.w[hour, default: 0] += price * tok
        }
        cache[key] = c
      }
    }
    for k in Array(cache.keys) where !seen.contains(k) { cache.removeValue(forKey: k) }
    for k in Array(cache.keys) {
      if let w = cache[k]?.w { cache[k]?.w = w.filter { $0.key >= first } }
    }
    if let u = cacheURL, let d = try? JSONEncoder().encode(cache) { try? d.write(to: u, options: .atomic) }

    var cwds: [String: String] = [:]
    for c in cache.values { if let cwd = c.cwd, cwds[c.dir] == nil { cwds[c.dir] = cwd } }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var r = Result()
    for c in cache.values {
      let cwd = cwds[c.dir] ?? c.dir
      let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
      var name = trimmed == home ? "~" : (trimmed as NSString).lastPathComponent
      if name.isEmpty { name = cwd }
      r.paths[name] = cwd
      for (h, w) in c.w where h >= first {
        r.total[name, default: 0] += w
        r.hours[h, default: [:]][name, default: 0] += w
      }
    }
    return r
  }
}

extension ISO8601DateFormatter {
  nonisolated(unsafe) static let full: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
}
#endif
