import WidgetKit
import SwiftUI
import AppIntents
import notify
import ClawdCore

struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> UsageEntry {
    UsageEntry(date: Date(), snap: .sample())
  }

  func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
    completion(SharedStore.load().map { UsageEntry(date: Date(), snap: $0) } ?? placeholder(in: context))
  }

  /// One entry per minute for an hour, so the countdown keeps going; the app reloads on real changes.
  func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
    let snap = SharedStore.load()
    let now = Date()
    let entries = (0..<60).map { UsageEntry(date: now.addingTimeInterval(Double($0) * 60), snap: snap) }
    completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
  }
}

struct RefreshIntent: AppIntent {
  static let title: LocalizedStringResource = "Refresh Claude usage"
  static let isDiscoverable = false

  func perform() async throws -> some IntentResult {
    notify_post(SharedStore.refreshNotification)
    try? await Task.sleep(for: .seconds(4))
    WidgetCenter.shared.reloadAllTimelines()
    return .result()
  }
}

@main
struct ClawdWidgets: WidgetBundle {
  var body: some Widget { CrabBarWidget() }
}

struct CrabBarWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "CrabBar", provider: Provider()) { entry in
      WidgetView(entry: entry)
        .containerBackground(Palette.card, for: .widget)
        .widgetURL(URL(string: "crabbar://open"))
    }
    .configurationDisplayName("CrabBar")
    .description("Claude-Limits mit Clawd · Claude limits with Clawd")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
