import Foundation

public enum Format {
  /// Time left until `end`: "2d 3h" from 24 h, "2h 05m" from 1 h, otherwise "42m". nil once passed.
  public static func span(until end: Date, now: Date = Date()) -> String? {
    let secs = end.timeIntervalSince(now)
    if secs <= 0 { return nil }
    let totalMinutes = Int(secs / 60)
    let days = totalMinutes / 1440
    let hours = (totalMinutes % 1440) / 60
    let minutes = totalMinutes % 60
    if secs >= 86400 { return T("span.d", days, hours) }
    if secs >= 3600 { return T("span.h", totalMinutes / 60, String(format: "%02d", minutes)) }
    return T("span.m", minutes)
  }

  /// Reset as a clock time: "03:20" today, "tmrw 01:00" tomorrow, "Sun 01:49" further off.
  public static func resetClock(_ at: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let hm = hhmm(at)
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: at)).day ?? 0
    if days <= 0 { return hm }
    if days == 1 { return T("clock.tmrw", hm) }
    let f = DateFormatter()
    f.locale = L10n.lang.locale
    f.dateFormat = "EEE"
    return f.string(from: at) + " " + hm
  }

  public static func hhmm(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f.string(from: d)
  }

  public static func hhmmss(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
  }

  public static func local(_ d: Date, _ pattern: String) -> String {
    let f = DateFormatter()
    f.locale = L10n.lang.locale
    f.setLocalizedDateFormatFromTemplate(pattern)
    return f.string(from: d)
  }

  /// Reminder time: "18:30" today, otherwise "Mon 19 Oct 18:30".
  public static func remindTime(_ at: Date, now: Date = Date()) -> String {
    if Calendar.current.isDate(at, inSameDayAs: now) { return hhmm(at) }
    let f = DateFormatter()
    f.locale = L10n.lang.locale
    f.dateFormat = L10n.lang == .de ? "EEE d. MMM HH:mm" : "EEE d MMM HH:mm"
    return f.string(from: at)
  }

  /// "yyyy-MM-dd HH:mm dddd" in invariant culture plus the UTC offset, as the context block wants.
  public static func contextNow(_ now: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm EEEE"
    return "\(f.string(from: now)) (\(utcOffset(now)))"
  }

  public static func utcOffset(_ now: Date = Date()) -> String {
    let secs = TimeZone.current.secondsFromGMT(for: now)
    let sign = secs >= 0 ? "+" : "-"
    let a = abs(secs)
    return String(format: "UTC%@%02d:%02d", sign, a / 3600, (a % 3600) / 60)
  }

  public static func iso(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return f.string(from: d)
  }

  /// Local "yyyy-MM-dd[THH:mm[:ss[.fff]]]" built from components (a time in the spring DST gap moves forward
  /// instead of failing), or a full ISO 8601 stamp with Z or an offset.
  public static func parseISO(_ s: String) -> Date? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?$"#
    if let re = try? NSRegularExpression(pattern: pattern),
       let m = re.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) {
      let ns = t as NSString
      func g(_ i: Int) -> Int? { m.range(at: i).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: i))) }
      var cal = Calendar(identifier: .gregorian)
      cal.timeZone = .current
      let c = DateComponents(year: g(1), month: g(2), day: g(3), hour: g(4) ?? 0, minute: g(5) ?? 0, second: g(6) ?? 0)
      guard let mo = c.month, (1...12).contains(mo), let d = c.day, (1...31).contains(d) else { return nil }
      return cal.date(from: c)
    }
    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: t) { return d }
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.date(from: t)
  }
}
