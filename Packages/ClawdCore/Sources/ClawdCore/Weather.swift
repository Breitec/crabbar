import Foundation

public struct Weather: Codable, Equatable, Sendable {
  public var code: Int
  public var temp: Double
  public var wind: Double          // km/h
  public var sunrise: Double?      // minutes from local midnight
  public var sunset: Double?
  public var at: Date

  public init(code: Int, temp: Double, wind: Double, sunrise: Double? = nil, sunset: Double? = nil, at: Date = Date()) {
    self.code = code
    self.temp = temp
    self.wind = wind
    self.sunrise = sunrise
    self.sunset = sunset
    self.at = at
  }

  /// Open-Meteo forecast with current weather and daily sunrise/sunset (timezone=auto).
  public static func parseOpenMeteo(_ data: Data) -> Weather? {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let c = j["current"] as? [String: Any],
          let code = (c["weather_code"] as? NSNumber)?.intValue else { return nil }
    var w = Weather(code: code, temp: (c["temperature_2m"] as? NSNumber)?.doubleValue ?? 0,
                    wind: (c["wind_speed_10m"] as? NSNumber)?.doubleValue ?? 0)
    if let d = j["daily"] as? [String: Any] {
      w.sunrise = minutes((d["sunrise"] as? [String])?.first)
      w.sunset = minutes((d["sunset"] as? [String])?.first)
    }
    return w
  }

  static func minutes(_ s: String?) -> Double? {
    guard let s, let t = s.split(separator: "T").last else { return nil }
    let p = t.split(separator: ":").compactMap { Double($0) }
    guard p.count >= 2 else { return nil }
    return p[0] * 60 + p[1]
  }

  /// met.no describes weather with a word: "lightrainshowers_day" -> WMO code.
  public static func parseMetNo(_ data: Data) -> Weather? {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let props = j["properties"] as? [String: Any],
          let ts = props["timeseries"] as? [[String: Any]], let first = ts.first,
          let d = first["data"] as? [String: Any] else { return nil }
    let sym0 = (((d["next_1_hours"] as? [String: Any])?["summary"] as? [String: Any])?["symbol_code"] as? String) ?? ""
    let sym = sym0.replacingOccurrences(of: #"_(day|night|polartwilight)$"#, with: "", options: .regularExpression)
    let lvl = sym.hasPrefix("light") ? 0 : (sym.hasPrefix("heavy") ? 2 : 1)
    let shw = sym.contains("showers")
    let code: Int
    if sym.contains("thunder") { code = 95 }
    else if sym.contains("snow") { code = shw ? [85, 85, 86][lvl] : [71, 73, 75][lvl] }
    else if sym.contains("sleet") { code = lvl == 2 ? 67 : 66 }
    else if sym.contains("rain") { code = shw ? [80, 81, 82][lvl] : [61, 63, 65][lvl] }
    else if sym.hasPrefix("fog") { code = 45 }
    else if sym.hasPrefix("cloudy") { code = 3 }
    else if sym.hasPrefix("partlycloudy") { code = 2 }
    else if sym.hasPrefix("fair") { code = 1 }
    else if sym.hasPrefix("clearsky") { code = 0 }
    else { code = 3 }
    let det = ((d["instant"] as? [String: Any])?["details"] as? [String: Any]) ?? [:]
    return Weather(code: code, temp: (det["air_temperature"] as? NSNumber)?.doubleValue ?? 0,
                   wind: 3.6 * ((det["wind_speed"] as? NSNumber)?.doubleValue ?? 0))
  }
}

public struct WeatherKind: Sendable {
  public var id: String
  public var cover: Double
  public var fog = false
  public var storm = false
  public var rain = 0
  public var snow = 0

  public var name: String { id.hasPrefix("code:") ? T("wx.code", id.dropFirst(5)) : T("wx.\(id)") }

  static let table: [([Int], String, Double, Bool, Bool, Int, Int)] = [
    ([0], "clear", 0.0, false, false, 0, 0),
    ([1], "mostlyClear", 0.2, false, false, 0, 0),
    ([2], "partly", 0.5, false, false, 0, 0),
    ([3], "overcast", 0.85, false, false, 0, 0),
    ([45, 48], "fog", 0.7, true, false, 0, 0),
    ([51, 53, 55], "drizzle", 0.8, false, false, 6, 0),
    ([56, 57], "iceDrizzle", 0.8, false, false, 6, 0),
    ([61, 63, 65], "rain", 0.9, false, false, 12, 0),
    ([66, 67], "iceRain", 0.9, false, false, 12, 0),
    ([71, 73, 75], "snow", 0.85, false, false, 0, 10),
    ([77], "grains", 0.85, false, false, 0, 8),
    ([80, 81, 82], "showers", 0.85, false, false, 16, 0),
    ([85, 86], "snowShowers", 0.9, false, false, 0, 14),
    ([95, 96, 99], "storm", 1.0, false, true, 16, 0)
  ]

  /// WMO weather codes; with three codes in a group they are light, moderate and heavy.
  public static func of(_ code: Int) -> WeatherKind {
    for row in table {
      guard let i = row.0.firstIndex(of: code) else { continue }
      let mul = row.0.count == 3 ? [0.6, 1.0, 1.35][i] : 1.0
      return WeatherKind(id: row.1, cover: row.2, fog: row.3, storm: row.4,
                         rain: Int((Double(row.5) * mul).rounded()), snow: Int((Double(row.6) * mul).rounded()))
    }
    return WeatherKind(id: "code:\(code)", cover: 0.5)
  }
}

public enum SunCalc {
  /// Sunrise and sunset (NOAA formulas) in minutes from midnight in `timeZone`. The day of the year is Gregorian,
  /// as the formulas expect, whatever the system calendar is.
  public static func times(lat: Double, lon: Double, date: Date = Date(), timeZone: TimeZone = .current) -> (sr: Double, ss: Double) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let doy = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
    let gm = 2 * Double.pi / 365 * (doy - 0.5)
    let eq = 229.18 * (0.000075 + 0.001868 * cos(gm) - 0.032077 * sin(gm) - 0.014615 * cos(2 * gm) - 0.040849 * sin(2 * gm))
    let dec = 0.006918 - 0.399912 * cos(gm) + 0.070257 * sin(gm) - 0.006758 * cos(2 * gm) +
      0.000907 * sin(2 * gm) - 0.002697 * cos(3 * gm) + 0.00148 * sin(3 * gm)
    let la = lat * .pi / 180
    var c = cos(90.833 * .pi / 180) / (cos(la) * cos(dec)) - tan(la) * tan(dec)
    c = max(-0.999, min(0.999, c))
    let ha = acos(c) * 180 / .pi
    let tz = Double(timeZone.secondsFromGMT(for: date)) / 60
    func wrap(_ v: Double) -> Double { (v.truncatingRemainder(dividingBy: 1440) + 1440).truncatingRemainder(dividingBy: 1440) }
    return (wrap(720 - 4 * (lon + ha) - eq + tz), wrap(720 - 4 * (lon - ha) - eq + tz))
  }
}

public struct Place: Codable, Equatable, Sendable {
  public var lat: Double
  public var lon: Double
  public var city: String?
  public init(lat: Double, lon: Double, city: String? = nil) {
    self.lat = lat
    self.lon = lon
    self.city = city
  }
}
