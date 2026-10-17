import SwiftUI
import UIKit
import CloudKit
import ClawdCore

@main
struct CrabBariOSApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @Environment(\.scenePhase) private var phase

  var body: some Scene {
    WindowGroup {
      ContentView(model: delegate.model)
        .preferredColorScheme(.dark)
    }
    .onChange(of: phase) { _, p in
      guard p == .active else { return }
      Task {
        await delegate.model.subscribe()
        await delegate.model.refresh()
      }
    }
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  let model = PhoneModel()

  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    application.registerForRemoteNotifications()
    return true
  }

  /// Silent push from the CloudKit subscription: fetch, keep it for the widgets, reload them.
  func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                   fetchCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void) {
    guard CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == CloudSnapshot.subscriptionID else {
      completion(.noData)
      return
    }
    Task { completion(await model.refresh() ? .newData : .failed) }
  }
}
