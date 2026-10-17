import Foundation
import UIKit
import WidgetKit
import ClawdCore

/// The App Group copy right away, then whatever the Mac last put into CloudKit.
@MainActor
@Observable
final class PhoneModel {
  var snap: WidgetSnapshot? {
    didSet { L10n.setting = snap?.language ?? "system" }
  }
  var problem: String?
  var loading = false
  @ObservationIgnored private var subscribed = false
  /// `--demo`: made-up numbers for screenshots, nothing from iCloud.
  @ObservationIgnored let demo = CommandLine.arguments.contains("--demo")

  init() {
    if demo {
      snap = Demo.snapshot()
      return
    }
    snap = SharedStore.load()
    L10n.setting = snap?.language ?? "system"
  }

  /// False when iCloud could not be asked.
  @discardableResult
  func refresh() async -> Bool {
    if demo { snap = Demo.snapshot(); return true }
    loading = true
    defer { loading = false }
    do {
      let new = try await CloudSnapshot.pull()
      problem = nil
      guard let new else { return true }
      let old = snap
      snap = new
      // Reloads from the background count against the widgets' daily budget.
      if UIApplication.shared.applicationState == .active || old?.displayKey != new.displayKey
          || old?.isStale(at: Date()) != false {
        WidgetCenter.shared.reloadAllTimelines()
      }
      return true
    } catch {
      problem = CloudSnapshot.isNoAccount(error) ? T("ios.noAccount") : T("ios.error", error.localizedDescription)
      return false
    }
  }

  /// Once per launch; a failure is retried the next time the app comes to the front.
  func subscribe() async {
    guard !subscribed, !demo else { return }
    do {
      try await CloudSnapshot.subscribe()
      subscribed = true
    } catch {}
  }
}
