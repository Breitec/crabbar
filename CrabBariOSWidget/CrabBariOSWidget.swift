import WidgetKit
import SwiftUI
import AppIntents
import ClawdCore

struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> UsageEntry {
    UsageEntry(date: Date(), snap: .sample())
  }

  func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
    completion(UsageEntry(date: Date(), snap: SharedStore.load() ?? .sample()))
  }

  /// One entry per minute for an hour, so the countdown keeps going. The app reloads after a push;
  /// when pushes don't come through, this asks CloudKit itself on the next reload.
  func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
    Task {
      let snap = await CloudSnapshot.latest()
      let now = Date()
      let entries = (0..<60).map { UsageEntry(date: now.addingTimeInterval(Double($0) * 60), snap: snap) }
      completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(CloudSnapshot.phoneReload))))
    }
  }
}

/// The phone can't make the Mac ask /usage, but it can fetch what the Mac uploaded last.
struct RefreshIntent: AppIntent {
  static let title: LocalizedStringResource = "Refresh Claude usage"
  static let isDiscoverable = false

  func perform() async throws -> some IntentResult {
    _ = try? await CloudSnapshot.pull()
    return .result()
  }
}

@main
struct ClawdWidgets: WidgetBundle {
  var body: some Widget {
    CrabBarWidget()
    ClawdLockWidget()
  }
}

struct CrabBarWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "CrabBar", provider: Provider()) { entry in
      WidgetView(entry: entry)
        .containerBackground(Palette.card, for: .widget)
    }
    .configurationDisplayName("CrabBar")
    .description(T("widget.desc"))
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

struct ClawdLockWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "CrabBarLock", provider: Provider()) { entry in
      LockView(entry: entry)
    }
    .configurationDisplayName("CrabBar")
    .description(T("widget.lockDesc"))
    .supportedFamilies([.accessoryCircular, .accessoryRectangular])
  }
}
