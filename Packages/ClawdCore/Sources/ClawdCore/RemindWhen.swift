import Foundation

/// "When" as people write it, German and English: 18:30, morgen 10, tomorrow 10:00, +20m, in 2 Stunden,
/// mo 9, in einer Woche 15:00, 19.10 14:00, 19.10.2026, 2026-10-19 14:00. A day without a time is 10:00;
/// a time already gone today is tomorrow. nil means not understood (the panel then asks Claude).
public enum RemindWhen {
  enum Unit { case half, min, hour, day, week, month }

  static func offset(_ s: String) -> (Int, Unit)? {
    if ["halbe stunde", "eine halbe stunde", "in einer halben stunde", "half an hour", "in half an hour"].contains(s) {
      return (1, .half)
    }
    let pattern = #"^(\+|in )?\s*(\d+|an?|one|eine[mnr]?|einen|1)?\s*(m|min|mins|minuten?|minutes?|h|std|stunden?|hours?|d|t|tagen?|tage?|days?|w|wochen?|weeks?|mo|monaten?|monate?|months?)$"#
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
    let ns = s as NSString
    let prefix = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces) : ""
    let num = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
    let n: Int
    if let v = Int(num) { n = v }
    else if !num.isEmpty || prefix == "in" { n = 1 }
    else { return nil }
    let u = ns.substring(with: m.range(at: 3))
    let unit: Unit
    if u.hasPrefix("mo") { unit = .month }
    else if u.hasPrefix("w") { unit = .week }
    else if u.hasPrefix("m") { unit = .min }
    else if u.hasPrefix("h") || u.hasPrefix("s") { unit = .hour }
    else { unit = .day }
    return (n, unit)
  }

  /// Whole words only (weekday numbers as in Calendar: 1 = Sunday). A prefix match would read "sauna" as Saturday.
  static let days: [String: Int] = [
    "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3, "wed": 4, "wednesday": 4, "thu": 5, "thur": 5,
    "thurs": 5, "thursday": 5, "fri": 6, "friday": 6, "sat": 7, "saturday": 7, "sun": 1, "sunday": 1,
    "mo": 2, "montag": 2, "di": 3, "dienstag": 3, "mi": 4, "mittwoch": 4, "do": 5, "donnerstag": 5,
    "fr": 6, "freitag": 6, "sa": 7, "samstag": 7, "so": 1, "sonntag": 1
  ]

  /// Gregorian whatever the system calendar is: files and ISO stamps are always Gregorian.
  static func calendar(_ timeZone: TimeZone = .current) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = timeZone
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
  }

  /// A date from components that must exist (31.2. is no date, not 3 March).
  static func validDate(_ cal: Calendar, year: Int?, month: Int?, day: Int?) -> Date? {
    guard let year, let month, let day, let d = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
    let c = cal.dateComponents([.year, .month, .day], from: d)
    return c.year == year && c.month == month && c.day == day ? d : nil
  }

  public static func parse(_ input: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
    var s = input.trimmingCharacters(in: .whitespaces).lowercased()
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\s*uhr$"#, with: "", options: .regularExpression)
    if s.isEmpty { return nil }
    let cal = calendar(timeZone)
    let today = cal.startOfDay(for: now)

    if let (n, u) = offset(s) {
      switch u {
      case .half: return now.addingTimeInterval(Double(30 * n) * 60)
      case .min: return now.addingTimeInterval(Double(n) * 60)
      case .hour: return now.addingTimeInterval(Double(n) * 3600)
      default: break
      }
    }
    // Optional time at the end: "... 9", "... 9:30", "... 9.30", "... 9h", "... um 9".
    var hm: (Int, Int)?
    var hasMinutes = false
    var rest = s
    if let re = try? NSRegularExpression(pattern: #"(?:^|\s)(?:um |at |gegen )?(\d{1,2})(?:[:.h](\d{2})|h)?$"#),
       let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
      let ns = s as NSString
      let h = Int(ns.substring(with: m.range(at: 1))) ?? 99
      if h < 24 {
        var mi = 0
        if m.range(at: 2).location != NSNotFound { mi = Int(ns.substring(with: m.range(at: 2))) ?? 0; hasMinutes = true }
        hm = (h, mi)
        rest = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
      }
    }
    func at(_ day: Date, _ t: (Int, Int)) -> Date {
      cal.date(bySettingHour: t.0, minute: t.1, second: 0, of: day) ?? day
    }
    if rest.isEmpty {
      guard let t = hm, hasMinutes || s.contains("um ") || s.contains("at ") || input.lowercased().contains("uhr") else { return nil }
      var d = at(today, t)
      if d <= now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
      return d
    }
    let t = hm ?? (10, 0)
    if let (n, u) = offset(rest) {
      switch u {
      case .day: return at(cal.date(byAdding: .day, value: n, to: today)!, t)
      case .week: return at(cal.date(byAdding: .day, value: 7 * n, to: today)!, t)
      case .month: return at(cal.date(byAdding: .month, value: n, to: today)!, t)
      default: break
      }
    }
    if ["heute", "today"].contains(rest) { return at(today, t) }
    if ["morgen", "tomorrow"].contains(rest) { return at(cal.date(byAdding: .day, value: 1, to: today)!, t) }
    if ["übermorgen", "uebermorgen", "day after tomorrow"].contains(rest) {
      return at(cal.date(byAdding: .day, value: 2, to: today)!, t)
    }
    var w = rest.replacingOccurrences(of: #"^(am|on|next|nächsten|nächster|naechsten|kommenden) "#, with: "", options: .regularExpression)
    if w.hasSuffix(".") { w.removeLast() }
    if let wd = days[w] {
      let cur = cal.component(.weekday, from: now)
      let d = (wd - cur + 7) % 7
      var r = at(cal.date(byAdding: .day, value: d, to: today)!, t)
      if r <= now { r = cal.date(byAdding: .day, value: 7, to: r)! }
      return r
    }
    if let re = try? NSRegularExpression(pattern: #"^(\d{1,2})\.(\d{1,2})\.?(?:(\d{2}|\d{4}))?$"#),
       let m = re.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
      let ns = rest as NSString
      let hasYear = m.range(at: 3).location != NSNotFound
      var y = hasYear ? Int(ns.substring(with: m.range(at: 3))) ?? 0 : cal.component(.year, from: now)
      if y < 100 { y += 2000 }
      guard let day = validDate(cal, year: y, month: Int(ns.substring(with: m.range(at: 2))),
                                day: Int(ns.substring(with: m.range(at: 1)))) else { return nil }
      var r = at(day, t)
      if !hasYear && r <= now { r = cal.date(byAdding: .year, value: 1, to: r)! }
      return r
    }
    if let re = try? NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})$"#),
       let m = re.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
      let ns = rest as NSString
      guard let day = validDate(cal, year: Int(ns.substring(with: m.range(at: 1))), month: Int(ns.substring(with: m.range(at: 2))),
                                day: Int(ns.substring(with: m.range(at: 3)))) else { return nil }
      return at(day, t)
    }
    return nil
  }

  /// Words that mean it repeats: the panel hands that to the chat, which makes a repeating reminder (or a
  /// recurring task when something has to be done each time).
  public static func isRepeat(_ s: String) -> Bool {
    s.lowercased().range(of: #"^(every|each|daily|weekly|hourly|jede[nmrs]?|alle|täglich|wöchentlich|stündlich|immer)\b"#,
                         options: .regularExpression) != nil
  }
}

/// How a reminder repeats: a `repeat:` line in its file. When it fires, the app writes the file for the next time.
public enum RemindRepeat: String, CaseIterable, Sendable {
  case daily, weekly, monthly, yearly

  /// The first word of a `repeat:` value, in any case; nil for anything else.
  public static func word(_ s: String) -> RemindRepeat? {
    let w = s.trimmingCharacters(in: .whitespaces).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
    return RemindRepeat(rawValue: w.lowercased())
  }

  /// The first time after `after`, stepping from `at` so the time of day stays (the Mac may have been off for
  /// a few). A monthly one on the 29th-31st goes on from the shorter month's last day.
  public func next(after: Date, from at: Date, timeZone: TimeZone = .current) -> Date? {
    let cal = RemindWhen.calendar(timeZone)
    for k in 1..<100_000 {
      let d: Date?
      switch self {
      case .daily: d = cal.date(byAdding: .day, value: k, to: at)
      case .weekly: d = cal.date(byAdding: .day, value: 7 * k, to: at)
      case .monthly: d = cal.date(byAdding: .month, value: k, to: at)
      case .yearly: d = cal.date(byAdding: .year, value: k, to: at)
      }
      if let d, d > after { return d }
    }
    return nil
  }

  /// "every month" for the Reminders tab and the chat's notes.
  public var label: String { T("rem.\(rawValue)") }
}
