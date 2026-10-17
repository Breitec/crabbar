import WidgetKit
import SwiftUI
import ClawdCore

struct LockView: View {
  @Environment(\.widgetFamily) var family
  let entry: UsageEntry

  var body: some View {
    let _ = { L10n.setting = entry.snap?.language ?? "system" }()
    switch family {
    case .accessoryCircular:
      CircularView(s: entry.snap, now: entry.date)
        .containerBackground(for: .widget) { AccessoryWidgetBackground() }
    default:
      RectangularView(s: entry.snap, now: entry.date)
        .containerBackground(for: .widget) { Color.clear }
    }
  }
}

/// The session limit as a ring, like the battery widget.
struct CircularView: View {
  var s: WidgetSnapshot?
  var now: Date

  var body: some View {
    let pct = s?.usage?.session
    let stale = s?.isStale(at: now) ?? true
    Gauge(value: Double(min(100, max(0, pct ?? 0))), in: 0...100) {
      Text(T("hist.session"))
    } currentValueLabel: {
      Text(pct.map { "\($0)%" } ?? "--").minimumScaleFactor(0.6)
    }
    .gaugeStyle(.accessoryCircularCapacity)
    .tint(stale ? Palette.dead : s?.level.color ?? Palette.dead)
    .opacity(stale ? 0.55 : 1)
    .widgetAccentable()
  }
}

/// Clawd, the session limit as a bar, the reset and the week.
struct RectangularView: View {
  var s: WidgetSnapshot?
  var now: Date

  var body: some View {
    if let s {
      let stale = s.isStale(at: now)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 4) {
          ClawdStill(mood: s.mood, halves: s.halves).frame(width: 22, height: 15)
          Text(s.usage?.session.map { "\($0)%" } ?? "--").font(.headline).fixedSize().widgetAccentable()
          Spacer(minLength: 2)
          if let w = s.usage?.week {
            Text("\(T("ui.week").capitalized) \(w)%").font(.caption).lineLimit(1).minimumScaleFactor(0.6)
          }
        }
        LimitBar(pct: s.usage?.session, color: s.level.color, height: 5)
        Text(stale ? T("stale") + " · " + s.resetLine(now) : s.resetLine(now))
          .font(.caption).lineLimit(1).minimumScaleFactor(0.8)
      }
    } else {
      Text(T("widget.noApp")).font(.caption)
    }
  }
}
