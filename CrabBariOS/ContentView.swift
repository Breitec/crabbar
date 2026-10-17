import SwiftUI
import ClawdCore

struct ContentView: View {
  var model: PhoneModel

  var body: some View {
    NavigationStack {
      ScrollView {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
          VStack(spacing: 14) {
            if let s = model.snap {
              if s.isStale(at: tl.date) { StaleNote(s: s, now: tl.date) }
              UsageCard(s: s, now: tl.date)
              UpdatedLine(s: s, now: tl.date)
            } else {
              NoData(loading: model.loading)
            }
            if let p = model.problem {
              Text(p).font(.footnote).foregroundStyle(Palette.warn).multilineTextAlignment(.center)
            }
          }
          .padding(16)
        }
      }
      .refreshable { await model.refresh() }
      .navigationTitle("CrabBar")
    }
  }
}

/// The large widget at phone size.
struct UsageCard: View {
  var s: WidgetSnapshot
  var now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("CLAUDE").font(.caption.weight(.semibold)).foregroundStyle(Palette.textHead)
        Spacer()
        if let h = s.halves { HeartsView(halves: h, scale: 1.6) }
      }
      HStack(alignment: .bottom) {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
          Text(s.usage?.session.map(String.init) ?? "--")
            .font(.system(size: 60, weight: .light))
            .foregroundStyle(s.level.color)
          Text("%").font(.title3).foregroundStyle(Palette.textHead)
        }
        Spacer(minLength: 0)
        ClawdStill(mood: s.mood, halves: s.halves).frame(width: 90, height: 60)
      }
      .background(alignment: .bottom) {
        SkyStill(s: s, now: now).frame(height: 80).padding(.horizontal, -8)
      }
      LimitBar(pct: s.usage?.session, color: s.level.color, height: 8)
      Text(s.resetLine(now)).font(.subheadline).foregroundStyle(Palette.textMain)
      LimitRow(label: T("ui.week"), text: s.limitText(s.usage?.week, s.usage?.weekReset, now),
               pct: s.usage?.week, color: Palette.week)
      if s.usage?.fable != nil {
        LimitRow(label: T("ui.fable"), text: s.limitText(s.usage?.fable, s.usage?.fableReset, now),
                 pct: s.usage?.fable, color: Palette.fable)
      }
      Row(label: T("ui.sessions"), text: s.sessionsLine)
      if !s.statusText.isEmpty {
        HStack(spacing: 6) {
          Circle().fill(s.statusLevel.color).frame(width: 8, height: 8)
          Text(s.statusText).font(.footnote).foregroundStyle(Palette.textHead)
        }
      }
      DayChart(s: s, now: now).frame(height: 64)
      if let r = s.nextReminder, let at = s.nextReminderAt {
        HStack(spacing: 6) {
          Image(systemName: "bell").foregroundStyle(Palette.warn)
          Text(T("widget.nextReminder", "\(Format.remindTime(at, now: now)) \(r)")).foregroundStyle(Palette.textMain)
        }
        .font(.footnote)
      }
      let open = s.lists.filter { $0.open > 0 }
      if !open.isEmpty {
        Text(open.prefix(3).map { T("widget.listOpen", $0.name, $0.open) }.joined(separator: "  ·  "))
          .font(.footnote).foregroundStyle(Palette.textHead)
      }
      if !s.plan.isEmpty { Text(s.plan).font(.caption2).foregroundStyle(Palette.textFoot) }
    }
    .padding(16)
    .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
  }
}

struct LimitRow: View {
  var label: String
  var text: String
  var pct: Int?
  var color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Row(label: label, text: text)
      LimitBar(pct: pct, color: color, height: 6)
    }
  }
}

struct Row: View {
  var label: String
  var text: String

  var body: some View {
    HStack {
      Text(label).font(.caption.weight(.semibold)).foregroundStyle(Palette.textDim)
      Spacer()
      Text(text).font(.subheadline).foregroundStyle(Palette.textHead)
    }
  }
}

struct StaleNote: View {
  var s: WidgetSnapshot
  var now: Date

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn)
      VStack(alignment: .leading, spacing: 2) {
        Text(T("ios.stale")).font(.headline)
        if let at = s.usageAt {
          Text(T("ios.staleSince", Format.remindTime(at, now: now))).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .background(Palette.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

struct UpdatedLine: View {
  var s: WidgetSnapshot
  var now: Date

  var body: some View {
    if let at = s.usageAt {
      Text(T("ios.updated", Format.remindTime(at, now: now)) + " · " + relative(at))
        .font(.footnote).foregroundStyle(.secondary)
    }
  }

  /// The Mac's clock may be a few seconds ahead; never "in 5 seconds".
  func relative(_ at: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = L10n.lang.locale
    f.dateTimeStyle = .named
    return f.localizedString(for: min(at, now), relativeTo: now)
  }
}

struct NoData: View {
  var loading: Bool

  var body: some View {
    VStack(spacing: 14) {
      ClawdStill(mood: .sleep, halves: nil).frame(width: 120, height: 80)
      Text(loading ? T("ios.loading") : T("ios.noData"))
        .font(.callout).foregroundStyle(Palette.textHead).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
    .padding(.horizontal, 20)
    .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
  }
}
