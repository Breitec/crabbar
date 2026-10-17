import Foundation
import CoreLocation
import ClawdCore

/// Plain HTTP with no keys: status page, latest Claude Code version, changelog, CrabBar releases, weather.
enum Net {
  static let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 20
    c.httpAdditionalHeaders = ["User-Agent": "CrabBar/\(AppModel.appVersion) (+https://github.com/\(AppRelease.repo))"]
    return URLSession(configuration: c)
  }()

  static func get(_ url: String) async -> Data? {
    guard let u = URL(string: url) else { return nil }
    guard let (d, r) = try? await session.data(from: u), (r as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { return nil }
    return d
  }

  static func status() async -> ServiceStatus? {
    guard let d = await get("https://status.claude.com/api/v2/summary.json") else { return nil }
    return ServiceStatus.parse(d)
  }

  static func latestVersion(channel: String) async -> String? {
    guard let d = await get("https://downloads.claude.ai/claude-code-releases/\(channel)") else { return nil }
    let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return ClaudeCLI.semver(s) != nil && s.count < 40 ? s : nil
  }

  /// Bullet points of CHANGELOG.md for versions in (from, to].
  static func changelog(from: String, to: String) async -> [String]? {
    guard let d = await get("https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md") else { return nil }
    let text = String(decoding: d, as: UTF8.self)
    guard let f = ClaudeCLI.semver(from), let t = ClaudeCLI.semver(to) else { return [] }
    var items: [String] = []
    for chunk in text.components(separatedBy: "\n## ") {
      guard let v = ClaudeCLI.semver(String(chunk.prefix(20))) else { continue }
      if !f.lexicographicallyPrecedes(v) || t.lexicographicallyPrecedes(v) { continue }
      for line in chunk.components(separatedBy: "\n") {
        if let r = line.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) {
          items.append(String(line[r.upperBound...]).replacingOccurrences(of: "`", with: ""))
        }
      }
    }
    return items
  }

  /// 404 while the repo has no published release yet.
  static func latestRelease() async -> AppRelease? {
    guard let u = URL(string: AppRelease.api) else { return nil }
    var req = URLRequest(url: u)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    guard let (d, r) = try? await session.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return AppRelease.parse(d)
  }

  static func weather(_ p: Place, metNo: Bool) async -> Weather? {
    let lat = String(format: "%.2f", p.lat), lon = String(format: "%.2f", p.lon)
    if metNo {
      guard let d = await get("https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=\(lat)&lon=\(lon)") else { return nil }
      return Weather.parseMetNo(d)
    }
    let url = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)" +
      "&current=weather_code,temperature_2m,wind_speed_10m&daily=sunrise,sunset&timezone=auto&forecast_days=1"
    guard let d = await get(url) else { return nil }
    return Weather.parseOpenMeteo(d)
  }

  /// Location by IP (ipwho.is) - only when the user turned it on in the settings.
  static func ipPlace(lang: String) async -> Place? {
    guard let d = await get("https://ipwho.is/?lang=\(lang)"),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          (j["success"] as? Bool) != false,
          let la = (j["latitude"] as? NSNumber)?.doubleValue, let lo = (j["longitude"] as? NSNumber)?.doubleValue else { return nil }
    return Place(lat: la, lon: lo, city: j["city"] as? String)
  }
}

/// One-shot location for the sky, asked once; stays on this Mac.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var cont: CheckedContinuation<Place?, Never>?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyKilometer
  }

  func current() async -> Place? {
    if cont != nil { return nil }
    let st = manager.authorizationStatus
    if st == .denied || st == .restricted { return nil }
    return await withCheckedContinuation { c in
      cont = c
      if st == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestLocation() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finish(nil) }
    }
  }

  private func finish(_ p: Place?) {
    cont?.resume(returning: p)
    cont = nil
  }

  nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
    let st = m.authorizationStatus
    Task { @MainActor in
      if st == .authorizedAlways || st == .authorized { self.manager.requestLocation() }
      else if st == .denied || st == .restricted { self.finish(nil) }
    }
  }

  nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
    guard let l = locs.last else { return }
    Task { @MainActor in
      var p = Place(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
      if let pm = try? await CLGeocoder().reverseGeocodeLocation(l).first { p.city = pm.locality }
      self.finish(p)
    }
  }

  nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor in self.finish(nil) }
  }
}
