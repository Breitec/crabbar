import AppIntents

/// "Refresh Claude usage" from Shortcuts or Spotlight; also lets the shared widget layouts render inside the app.
struct RefreshIntent: AppIntent {
  static let title: LocalizedStringResource = "Refresh Claude usage"

  @MainActor
  func perform() async throws -> some IntentResult {
    AppDelegate.shared?.model.refreshNow()
    return .result()
  }
}
