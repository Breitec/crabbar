import Foundation

/// The newest published CrabBar release on GitHub (`/releases/latest` skips drafts and pre-releases).
public struct AppRelease: Equatable, Sendable {
  public static let repo = "Breitec/crabbar"
  public static var api: String { "https://api.github.com/repos/\(repo)/releases/latest" }
  /// Always our own repo, never a link out of the API response.
  public static var page: String { "https://github.com/\(repo)/releases/latest" }

  public var version: String
  public var notes: [String]

  public init(version: String, notes: [String] = []) {
    self.version = version
    self.notes = notes
  }

  public static func parse(_ data: Data) -> AppRelease? {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = j["tag_name"] as? String, tag.count < 40, let p = parts(tag) else { return nil }
    if (j["draft"] as? Bool) == true || (j["prerelease"] as? Bool) == true { return nil }
    let body = (j["body"] as? String) ?? ""
    let notes = body.components(separatedBy: .newlines).compactMap { line -> String? in
      guard let r = line.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) else { return nil }
      let s = line[r.upperBound...].replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
      return s.isEmpty ? nil : String(s.prefix(200))
    }
    return AppRelease(version: p.map(String.init).joined(separator: "."), notes: notes)
  }

  /// "v1.2", "1.2.0" and "CrabBar 1.2.0" all read as [1, 2, 0].
  public static func parts(_ s: String) -> [Int]? {
    guard let r = s.range(of: #"\d+(\.\d+){0,2}"#, options: .regularExpression) else { return nil }
    let n = s[r].split(separator: ".").compactMap { Int($0) }
    return n + Array(repeating: 0, count: 3 - n.count)
  }

  public static func newer(_ a: String, than b: String) -> Bool {
    guard let x = parts(a), let y = parts(b) else { return false }
    return y.lexicographicallyPrecedes(x)
  }
}
