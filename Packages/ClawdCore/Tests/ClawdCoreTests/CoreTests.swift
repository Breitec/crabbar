import Foundation
import Testing
@testable import ClawdCore

func fixture(_ name: String) throws -> String {
  let u = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
  return try String(contentsOf: u, encoding: .utf8)
}

func date(_ s: String, _ tz: String = "Europe/Berlin") -> Date {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.timeZone = TimeZone(identifier: tz)
  f.dateFormat = "yyyy-MM-dd HH:mm"
  return f.date(from: s)!
}

@Suite struct UsageParserTests {
  let berlin = TimeZone(identifier: "Europe/Berlin")!

  @Test func currentFormat() throws {
    let now = date("2026-10-17 11:00")
    let u = try UsageParser.parse(try fixture("usage-2.1.299"), now: now, timeZone: berlin)
    #expect(u.session == 6)
    #expect(u.week == 10)
    #expect(u.fable == 4)
    #expect(u.sessionReset == date("2026-10-17 14:29"))
    #expect(u.weekReset == date("2026-10-21 21:59"))
    #expect(u.day?.requests == 320)
    #expect(u.day?.sessions == 6)
    #expect(u.week7?.requests == 622)
    #expect(u.day?.lines.first == "88% of your usage was at >150k context")
  }

  @Test func quietDaySingular() throws {
    let text = "Current session: 2% used · resets Oct 17 at 2:29pm\n\nLast 24h · 1 request · 1 session\n  Top skills: /usage 1%\n"
    let u = try UsageParser.parse(text, now: date("2026-10-17 11:00"), timeZone: berlin)
    #expect(u.day?.requests == 1)
    #expect(u.day?.sessions == 1)
    #expect(u.day?.lines == ["Top skills: /usage 1%"])
  }

  @Test func legacyCommaFormatWithZone() throws {
    let now = date("2026-10-16 12:00")
    let u = try UsageParser.parse(try fixture("usage-legacy"), now: now, timeZone: berlin)
    #expect(u.session == 10)
    #expect(u.fable == nil)
    // 5:19am Moscow = 4:19am Berlin (CEST)
    #expect(u.sessionReset == date("2026-10-17 04:19"))
    #expect(u.week7 == nil)
    #expect(u.day?.lines.count == 2)
  }

  @Test func noResetsMeansZeroNotMissing() throws {
    let u = try UsageParser.parse("Current session: 0% used\nCurrent week (all models): 3% used · resets Oct 21 at 9pm")
    #expect(u.session == 0)
    #expect(u.sessionReset == nil)
    #expect(u.week == 3)
  }

  @Test func notAvailable() {
    #expect(throws: UsageParseError.notAvailable) { try UsageParser.parse("/usage isn't available in this environment.") }
    #expect(throws: UsageParseError.noLimits) { try UsageParser.parse("hello") }
  }

  @Test func resetStampVariants() {
    let now = date("2026-12-30 10:00")
    #expect(ResetStamp.parse("Jan 2 at 6am", now: now, timeZone: berlin) == date("2027-01-02 06:00"))
    #expect(ResetStamp.parse("Dec 31, 12pm", now: now, timeZone: berlin) == date("2026-12-31 12:00"))
    #expect(ResetStamp.parse("Dec 31, 12:30am", now: now, timeZone: berlin) == date("2026-12-31 00:30"))
    #expect(ResetStamp.parse("3:15pm (Europe/Berlin)", now: now, timeZone: berlin) == date("2026-12-30 15:15"))
    #expect(ResetStamp.parse("garbage", now: now, timeZone: berlin) == nil)
  }

  @Test func statLines() {
    L10n.setting = "en"
    #expect(StatLine.format("88% of your usage was at >150k context") == "88% at >150k context")
    #expect(StatLine.format("Top skills: /a 9%") == "skills: /a 9%")
    #expect(StatLine.format("Something new") == "Something new")
  }
}

@Suite struct RulesTests {
  @Test func span() {
    L10n.setting = "en"
    let now = date("2026-10-17 10:00")
    #expect(Format.span(until: date("2026-10-17 12:05"), now: now) == "2h 05m")
    #expect(Format.span(until: date("2026-10-19 13:00"), now: now) == "2d 3h")
    #expect(Format.span(until: date("2026-10-17 10:42"), now: now) == "42m")
    #expect(Format.span(until: date("2026-10-17 09:00"), now: now) == nil)
  }

  @Test func hearts() {
    #expect(Hearts.halves(nil) == nil)
    #expect(Hearts.halves(0) == 6)
    #expect(Hearts.halves(17) == 5)
    #expect(Hearts.halves(99) == 1)
    #expect(Hearts.halves(100) == 0)
    #expect(Hearts.halves(130) == 0)
  }

  @Test func levels() {
    #expect(Level.of(59) == .ok)
    #expect(Level.of(60) == .warn)
    #expect(Level.of(85) == .crit)
    #expect(Level.of(nil) == .dead)
  }

  @Test func mood() {
    let idle = ClaudeSession(pid: 1, name: "a", cwd: "/", busy: false, waiting: false)
    let busy = ClaudeSession(pid: 2, name: "b", cwd: "/", busy: true, waiting: false)
    let wait = ClaudeSession(pid: 3, name: "c", cwd: "/", busy: false, waiting: true)
    #expect(Mood.from(sessionPct: 100, sessions: [wait]) == .dead)
    #expect(Mood.from(sessionPct: 50, sessions: [busy, wait]) == .wait)
    #expect(Mood.from(sessionPct: 50, sessions: [idle, busy]) == .work)
    #expect(Mood.from(sessionPct: nil, sessions: [idle]) == .idle)
    #expect(Mood.from(sessionPct: 10, sessions: []) == .sleep)
  }

  @Test func history() {
    var h = UsageHistory()
    let t = date("2026-10-17 10:00")
    h.add(Usage(session: 5, week: 10), at: t)
    h.add(Usage(session: 5, week: 10), at: t.addingTimeInterval(120))
    #expect(h.samples.count == 1)
    h.add(Usage(session: 5, week: 10), at: t.addingTimeInterval(360))
    h.add(Usage(session: 6, week: 10), at: t.addingTimeInterval(420))
    #expect(h.samples.count == 3)
    h.add(Usage(session: 7, week: 10), at: t.addingTimeInterval(3600))
    #expect(h.runs(from: 0, column: 1).count == 2)
    h.add(Usage(session: 1, week: 1), at: t.addingTimeInterval(9 * 86400))
    #expect(h.samples.count == 1)
  }

  @Test func sprite() {
    let g = ClawdSprite.geometry(ClawdFrame())
    #expect(!g.body.isEmpty)
    #expect(!g.eyes.isEmpty)
    let flipped = ClawdFrame(eyes: "x")
    #expect(!ClawdSprite.geometry(flipped).eyes.isEmpty)
    #expect(ClawdSequences.clickActs.contains("jump"))
    #expect(!ClawdSequences.clickActs.contains("skip"))
    #expect(ClawdSequences.length("soul") == 66)
    let e = MascotEngine(entrance: false)
    for _ in 0..<500 { _ = e.step(areaWidth: 150, areaHeight: 40, hovering: false, mouseX: nil) }
  }

  @Test func weather() {
    #expect(WeatherKind.of(61).rain == 7)
    #expect(WeatherKind.of(65).rain == 16)
    #expect(WeatherKind.of(95).storm)
    let st = SunCalc.times(lat: 50, lon: 10, date: date("2026-06-21 12:00"))
    #expect(st.sr > 4 * 60 && st.sr < 6 * 60)
    #expect(st.ss > 20 * 60 && st.ss < 22 * 60)
  }
}

@Suite struct HomeFilesTests {
  func tmpHome() -> ClawdHome {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-test-\(UUID().uuidString)")
    let h = ClawdHome(url: u)
    h.ensure()
    return h
  }

  @Test func remindWhen() {
    let now = date("2026-10-17 11:00")
    #expect(RemindWhen.parse("+20m", now: now) == date("2026-10-17 11:20"))
    #expect(RemindWhen.parse("in 2 stunden", now: now) == date("2026-10-17 13:00"))
    #expect(RemindWhen.parse("18:30", now: now) == date("2026-10-17 18:30"))
    #expect(RemindWhen.parse("09:30", now: now) == date("2026-10-18 09:30"))
    #expect(RemindWhen.parse("morgen 10", now: now) == date("2026-10-18 10:00"))
    #expect(RemindWhen.parse("tomorrow", now: now) == date("2026-10-18 10:00"))
    #expect(RemindWhen.parse("mo 9", now: now) == date("2026-10-19 09:00"))
    #expect(RemindWhen.parse("mon 9:00", now: now) == date("2026-10-19 09:00"))
    #expect(RemindWhen.parse("in einer woche", now: now) == date("2026-10-24 10:00"))
    #expect(RemindWhen.parse("19.10 14:00", now: now) == date("2026-10-19 14:00"))
    #expect(RemindWhen.parse("1.1.27", now: now) == date("2027-01-01 10:00"))
    #expect(RemindWhen.parse("2026-11-16 10:00", now: now) == date("2026-11-16 10:00"))
    #expect(RemindWhen.parse("um 9", now: now) == date("2026-10-18 09:00"))
    #expect(RemindWhen.parse("10", now: now) == nil)
    #expect(RemindWhen.parse("Steuern zahlen", now: now) == nil)
    #expect(RemindWhen.isRepeat("jeden Montag"))
  }

  @Test func replyBlocks() {
    let reply = """
    Mach ich.

    ```remind
    2026-10-19T10:00 | Kunden anrufen
    ```

    ```list-add
    Einkauf | Milch
    ```

    ```run
    du -sh ~/Library/Caches
    ```

    ```task
    name: Mail
    every: 10m
    tools: mcp__mail
    ---
    Check the inbox.
    ```
    """
    let p = ReplyBlocks.parse(reply)
    #expect(p.text == "Mach ich.")
    #expect(p.run == "du -sh ~/Library/Caches")
    #expect(p.actions.count == 3)
    #expect(p.actions[0] == .remind(date("2026-10-19 10:00", TimeZone.current.identifier), "Kunden anrufen"))
    if case .task(let name, let head, let prompt) = p.actions[2] {
      #expect(name == "Mail")
      #expect(head["tools"] == "mcp__mail")
      #expect(prompt == "Check the inbox.")
    } else {
      Issue.record("no task")
    }
  }

  @Test func reminders() {
    let h = tmpHome()
    let at = Date().addingTimeInterval(3600)
    h.newReminder(at: at, text: "Test: eins/zwei")
    let r = h.activeReminders()
    #expect(r.count == 1)
    #expect(r[0].text == "Test: eins/zwei")
    #expect(h.markDone(r[0]) != nil)
    #expect(h.activeReminders().isEmpty)
    #expect(h.doneReminders().count == 1)
  }

  @Test func lists() {
    let h = tmpHome()
    #expect(h.listNames(defaultName: "Einkauf") == ["Einkauf"])
    h.addListItems("Einkauf", "Milch, Brot")
    #expect(h.readList("Einkauf").items.count == 2)
    #expect(h.setListItem("Einkauf", text: "milch", done: true))
    h.clearListDone("Einkauf")
    #expect(h.readList("Einkauf").items.map(\.text) == ["Brot"])
    #expect(h.readList("Einkauf").lines.first == "# Einkauf")
  }

  @Test func tasks() {
    let h = tmpHome()
    h.newTask(name: "Mail", head: ["every": "10m", "tools": "mcp__mail Bash(gh pr list:*)", "hours": "22-7"], prompt: "Do it")
    let t = h.taskFiles()
    #expect(t.count == 1)
    #expect(t[0].every == 600)
    #expect(t[0].tools == ["mcp__mail", "Bash(gh pr list:*)"])
    #expect(t[0].hours?.0 == 22)
    h.setTaskPaused(t[0], true)
    #expect(h.taskFiles()[0].paused)
    #expect(h.grantTools(h.taskFiles()[0], ["WebFetch(domain:x.com)"]))
    #expect(h.taskFiles()[0].tools.last == "WebFetch(domain:x.com)")
    #expect(ClawdHome.parseEvery("1m") == 120)
    #expect(ClawdHome.parseEvery("2 Std") == 7200)
  }
}

@Suite struct ReviewRegressionTests {
  @Test func weekdaysAreWholeWords() {
    let now = date("2026-10-17 11:00")
    #expect(RemindWhen.parse("sauna 18", now: now) == nil)
    #expect(RemindWhen.parse("monatsende", now: now) == nil)
    #expect(RemindWhen.parse("dose holen 9:30", now: now) == nil)
    #expect(RemindWhen.parse("freitag 9", now: now) == date("2026-10-23 09:00"))
    #expect(RemindWhen.parse("am montag 10:30", now: now) == date("2026-10-19 10:30"))
    #expect(RemindWhen.parse("sat", now: now) == date("2026-10-24 10:00"))
  }

  @Test func invalidDatesFail() {
    let now = date("2026-10-17 11:00")
    #expect(RemindWhen.parse("31.2.", now: now) == nil)
    #expect(RemindWhen.parse("2026-02-30", now: now) == nil)
  }

  @Test func isoParsing() {
    #expect(Format.parseISO("2026-11-16T10:00") == date("2026-11-16 10:00", TimeZone.current.identifier))
    #expect(Format.parseISO("2026-11-16T10:00:00.000") != nil)
    #expect(Format.parseISO("2026-11-16T09:00:00Z") != nil)
    #expect(Format.parseISO("2026-11-16T10:00:00+01:00") != nil)
    // A local time in the spring DST gap moves forward instead of disappearing.
    #expect(Format.parseISO("2027-03-28T02:30") != nil)
    #expect(Format.parseISO("2026-13-01") == nil)
  }

  @Test func toolRules() {
    #expect(ClawdHome.isValidToolRule("mcp__mail"))
    #expect(ClawdHome.isValidToolRule("mcp__mail__list_messages"))
    #expect(ClawdHome.isValidToolRule("Bash(gh pr list:*)"))
    #expect(ClawdHome.isValidToolRule("WebFetch(domain:github.com)"))
    #expect(!ClawdHome.isValidToolRule("Bash"))
    #expect(!ClawdHome.isValidToolRule("Write"))
    #expect(!ClawdHome.isValidToolRule("--dangerously-skip-permissions"))
    #expect(!ClawdHome.isValidToolRule("Bash(-rf:*)"))
  }

  @Test func stillSkyShowsClouds() {
    let r = SkyEngine().still(width: 140, height: 40, now: date("2026-10-17 12:00"), sun: (420, 1140),
                              weather: Weather(code: 3, temp: 10, wind: 8), place: nil)
    #expect(!r.clouds.isEmpty)
    #expect(r.clouds.allSatisfy { $0.opacity > 0.6 })
    #expect(r.flash == 0)
  }

  @Test func widgetStalenessAndReloadKey() {
    var s = WidgetSnapshot()
    s.usageAt = date("2026-10-17 10:00")
    s.staleAfter = 210
    #expect(!s.isStale(at: date("2026-10-17 10:03")))
    #expect(s.isStale(at: date("2026-10-17 10:04")))
    s.usage = Usage(session: 5, week: 9, day: UsagePeriod(requests: 1, sessions: 1, lines: []))
    let k1 = s.displayKey
    s.usage?.day = UsagePeriod(requests: 99, sessions: 2, lines: ["x"])
    #expect(s.displayKey == k1)
    s.usage?.session = 6
    #expect(s.displayKey != k1)
  }

  @Test func devMenuSemantics() {
    let e = MascotEngine(entrance: false)
    e.startDrain()
    #expect(e.force == nil)
    e.force = .work
    e.forceCrit = true
    e.stopDemo()
    #expect(e.force == nil && !e.forceCrit)
  }
}

@Suite struct CloudSnapshotTests {
  @Test func uploadThrottle() {
    #expect(!CloudSnapshot.shouldUpload(key: "b", lastKey: "a", since: 59))
    #expect(CloudSnapshot.shouldUpload(key: "b", lastKey: "a", since: 60))
    #expect(CloudSnapshot.shouldUpload(key: "a", lastKey: nil, since: .infinity))
    #expect(!CloudSnapshot.shouldUpload(key: "a", lastKey: "a", since: 599))
    #expect(CloudSnapshot.shouldUpload(key: "a", lastKey: "a", since: 600))
  }

  @Test func phoneCopyAgesLater() {
    var s = WidgetSnapshot()
    s.usageAt = date("2026-10-17 10:00")
    s.staleAfter = 210
    let p = CloudSnapshot.phoneCopy(s)
    #expect(s.isStale(at: date("2026-10-17 10:04")))
    #expect(!p.isStale(at: date("2026-10-17 10:28")))
    #expect(p.isStale(at: date("2026-10-17 10:29")))
    #expect(p.displayKey == s.displayKey)
  }

  @Test func codingRoundTrip() throws {
    var s = WidgetSnapshot.sample(now: date("2026-10-17 10:00"))
    s.writtenAt = date("2026-10-17 10:01")
    s.history = [[29_400_000, 42, 18]]
    s.lists = [.init(name: "Einkauf", open: 3)]
    #expect(try WidgetSnapshot.decoded(s.encoded()) == s)
  }
}

@Suite struct AppReleaseTests {
  @Test func comparesVersions() {
    #expect(AppRelease.newer("v1.1", than: "1.0.0"))
    #expect(AppRelease.newer("1.0.1", than: "1.0"))
    #expect(AppRelease.newer("1.10.0", than: "1.9.3"))
    #expect(!AppRelease.newer("v1.0.0", than: "1.0"))
    #expect(!AppRelease.newer("0.9", than: "1.0.0"))
    #expect(!AppRelease.newer("nightly", than: "1.0.0"))
  }

  @Test func parsesLatestRelease() throws {
    let json = """
    {"tag_name": "v1.2", "draft": false, "prerelease": false, "html_url": "https://evil.example/",
     "body": "## What's new\\r\\n- **Update hint** in the details\\r\\n* Faster `/usage`\\r\\n\\r\\nThanks!"}
    """
    let r = try #require(AppRelease.parse(Data(json.utf8)))
    #expect(r.version == "1.2.0")
    #expect(r.notes == ["Update hint in the details", "Faster /usage"])
    #expect(AppRelease.page == "https://github.com/Breitec/crabbar/releases/latest")
  }

  @Test func skipsDraftsAndJunk() {
    #expect(AppRelease.parse(Data(#"{"tag_name": "v2.0", "prerelease": true}"#.utf8)) == nil)
    #expect(AppRelease.parse(Data(#"{"message": "Not Found"}"#.utf8)) == nil)
    #expect(AppRelease.parse(Data("<html>".utf8)) == nil)
  }
}
