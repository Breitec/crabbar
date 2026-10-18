import Foundation
import ClawdCore

/// Finds the `claude` binary. Several installs can live side by side (native installer, Homebrew, npm,
/// the one bundled with the Claude desktop app); the newest version wins unless config names one.
enum ClaudeCLI {
  struct Binary: Equatable {
    var path: String
    var version: String
  }

  static func semver(_ s: String) -> [Int]? {
    guard let r = s.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
    return s[r].split(separator: ".").compactMap { Int($0) }
  }

  static func newer(_ a: String, than b: String) -> Bool {
    guard let x = semver(a) else { return false }
    guard let y = semver(b) else { return true }
    return y.lexicographicallyPrecedes(x)
  }

  static func candidates() -> [String] {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    var out = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
               "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
    if let d = ClaudeConfig.custom { out.append(d.appendingPathComponent("local/claude").path) }
    let versions = "\(home)/.local/share/claude/versions"
    for v in (try? fm.contentsOfDirectory(atPath: versions)) ?? [] { out.append("\(versions)/\(v)") }
    let bundled = "\(home)/Library/Application Support/Claude/claude-code"
    for v in (try? fm.contentsOfDirectory(atPath: bundled)) ?? [] {
      for h in (try? fm.contentsOfDirectory(atPath: "\(bundled)/\(v)")) ?? [] {
        out.append("\(bundled)/\(v)/\(h)/claude.app/Contents/MacOS/claude")
      }
    }
    return out.filter { fm.isExecutableFile(atPath: $0) }
  }

  /// Version from the path where installers put it, otherwise from `--version`.
  static func version(of path: String) async -> String? {
    let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)).map { dest -> String in
      dest.hasPrefix("/") ? dest : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest)
    } ?? path
    if let r = real.range(of: #"/(\d+\.\d+\.\d+)(/|$)"#, options: .regularExpression) {
      return String(real[r]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    let o = await Proc.run(path, ["--version"], timeout: 15)
    guard o.code == 0, let v = semver(o.text) else { return nil }
    return v.map(String.init).joined(separator: ".")
  }

  static func locate(override: String?) async -> Binary? {
    if let o = override, !o.isEmpty {
      let p = (o as NSString).expandingTildeInPath
      if FileManager.default.isExecutableFile(atPath: p) {
        return Binary(path: p, version: await version(of: p) ?? "")
      }
    }
    var best: Binary?
    var seen = Set<String>()
    for c in candidates() {
      let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: c)) ?? c
      if !seen.insert(real).inserted { continue }
      guard let v = await version(of: c) else { continue }
      if best == nil || newer(v, than: best!.version) { best = Binary(path: c, version: v) }
    }
    return best
  }

  /// `autoUpdatesChannel` from settings.json in Claude Code's folder: latest or stable.
  static var updateChannel: String {
    if let d = try? Data(contentsOf: ClaudeConfig.settings), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let c = j["autoUpdatesChannel"] as? String, ["latest", "stable"].contains(c) { return c }
    return "latest"
  }
}
