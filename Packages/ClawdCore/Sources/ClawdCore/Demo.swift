import Foundation

/// Made-up, fixed data for screenshots (`--demo`): nothing of the user's own usage, projects or account.
public enum Demo {
  public static func usage(now: Date = Date()) -> Usage {
    Usage(session: 37, week: 52, fable: 18,
          sessionReset: now.addingTimeInterval(2 * 3600 + 14 * 60),
          weekReset: now.addingTimeInterval(3 * 86400 + 5 * 3600),
          fableReset: now.addingTimeInterval(3 * 86400 + 5 * 3600),
          day: UsagePeriod(requests: 412, sessions: 7, lines: [
            "61% of your usage was at >150k context",
            "24% of your usage came from subagent-heavy sessions",
            "18% of your usage went to always-on context over 40k tokens",
            "Top skills: /code-review 6%, /deep-research 3%",
            "Top MCP servers: github 9%, browser 4%"
          ]),
          week7: UsagePeriod(requests: 2318, sessions: 23, lines: [
            "58% of your usage was at >150k context",
            "21% of your usage came from sessions active for 8+ hours",
            "19% of your usage came from subagent-heavy sessions",
            "Top skills: /code-review 5%, /deep-research 2%",
            "Top subagents: Explore 4%, general-purpose 2%",
            "Top MCP servers: github 8%, browser 5%, docs 2%"
          ]))
  }

  public static let sessions: [ClaudeSession] = [
    ClaudeSession(pid: 90001, name: "my-app", cwd: "~/Projects/my-app", busy: true, waiting: false, kind: "interactive"),
    ClaudeSession(pid: 90002, name: "website", cwd: "~/Projects/website", busy: false, waiting: false, kind: "interactive"),
    ClaudeSession(pid: 90003, name: "dotfiles", cwd: "~/dotfiles", busy: false, waiting: false, kind: "interactive")
  ]

  public static let account = Account(loggedIn: true, plan: "Max", email: "you@example.com")

  public static let projectShares: [(String, Double)] = [("my-app", 46), ("website", 31), ("notes", 15), ("dotfiles", 8)]

  public static let weather = Weather(code: 2, temp: 14, wind: 9, sunrise: 7 * 60 + 12, sunset: 18 * 60 + 31)

  /// Seven days of samples: busy days with 5-hour windows filling up and resetting, quiet nights, a week that climbs.
  public static func history(now: Date = Date()) -> UsageHistory {
    var h = UsageHistory()
    let t1 = UsageHistory.minute(now)
    let t0 = t1 - 7 * 1440
    var seed: UInt64 = 42
    func rnd() -> Double {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return Double(seed >> 33) / Double(UInt32.max >> 1)
    }
    var week = 4.0
    var windowStart = -1
    var peak = 50.0
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    var t = t0
    while t <= t1 {
      let d = Date(timeIntervalSince1970: Double(t) * 60)
      let hour = cal.component(.hour, from: d)
      if hour >= 8 && hour <= 23 {
        if windowStart < 0 || t - windowStart >= 300 {
          windowStart = t
          peak = 30 + rnd() * 55
        }
        let k = Double(t - windowStart) / 300
        let s = Int(peak * k)
        week = min(52, week + 0.06 + rnd() * 0.05)
        h.samples.append([t, s, Int(week)])
      } else {
        windowStart = -1
      }
      t += 15
    }
    if let last = h.samples.last { h.samples[h.samples.count - 1] = [last[0], 37, 52] }
    return h
  }

  /// The widget snapshot for screenshots of the Mac and iPhone widgets.
  public static func snapshot(now: Date = Date()) -> WidgetSnapshot {
    var s = WidgetSnapshot()
    s.usage = usage(now: now)
    s.usageAt = now
    s.mood = .work
    s.sessions = 3
    s.busy = 1
    s.statusLevel = .ok
    s.statusText = T("st.ok")
    s.plan = "Max"
    let cut = UsageHistory.minute(now) - 24 * 60
    s.history = history(now: now).samples.filter { $0[0] >= cut }
    s.weatherCode = weather.code
    s.temp = weather.temp
    s.sunrise = weather.sunrise ?? 420
    s.sunset = weather.sunset ?? 1140
    s.nextReminder = L10n.lang == .de ? "Kunden anrufen" : "Call the client"
    s.nextReminderAt = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))?
      .addingTimeInterval(10 * 3600)
    s.lists = [.init(name: T("lists.default"), open: 3)]
    s.language = L10n.setting
    s.staleAfter = 210
    return s
  }

  /// A short conversation for the panel screenshot, in the UI language.
  public static var chat: [(role: String, text: String)] {
    if L10n.lang == .de {
      return [("user", "Wie viel Platz belegen meine Caches?"),
              ("clawd", "Rund 6,2 GB: Caches 3,1 GB, Downloads 2,0 GB, Xcode DerivedData 1,1 GB. Soll ich die Homebrew-Downloads leeren? Das bringt etwa 1,4 GB."),
              ("user", "Ja, und erinner mich Montag um 10 an den Kundenanruf.")]
    }
    return [("user", "How much space do my caches take?"),
            ("clawd", "About 6.2 GB: Caches 3.1 GB, Downloads 2.0 GB, Xcode DerivedData 1.1 GB. Shall I clear the Homebrew downloads? That frees about 1.4 GB."),
            ("user", "Yes, and remind me on Monday at 10 to call the client.")]
  }

  public static let script = "rm -rf ~/Library/Caches/Homebrew/downloads/*\necho \"Homebrew downloads cleared\""

  public static var reply: String {
    L10n.lang == .de ? "Mach ich. Das Skript leert nur den Download-Ordner von Homebrew." : "Will do. The script only empties Homebrew's download folder."
  }

  public static var listItems: [(String, Bool)] {
    L10n.lang == .de ? [("Milch", true), ("Brot", false), ("Kaffee", false), ("Äpfel", false)]
      : [("Milk", true), ("Bread", false), ("Coffee", false), ("Apples", false)]
  }

  public static var reminders: [(Int, String)] {
    L10n.lang == .de ? [(1, "Kunden anrufen"), (21, "Steuern bezahlen")] : [(1, "Call the client"), (21, "Pay the taxes")]
  }
}
