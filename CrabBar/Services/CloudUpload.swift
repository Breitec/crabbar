import Foundation
import Security
import ClawdCore

/// Puts the widget snapshot into the private CloudKit database for the iPhone, throttled by `CloudSnapshot`.
@MainActor
final class CloudUpload {
  private var lastKey: String?
  private(set) var lastAt = Date.distantPast
  private var pauseUntil = Date.distantPast
  private var running = false
  private(set) var lastError: String?

  /// CloudKit throws an exception rather than an error without the entitlement (e.g. an ad-hoc build).
  static let available: Bool = {
    guard let task = SecTaskCreateFromSelf(nil),
          let ids = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
            as? [String] else { return false }
    return ids.contains(CloudSnapshot.containerID)
  }()

  func offer(_ s: WidgetSnapshot) {
    let now = Date()
    // Right after launch there is nothing yet; don't replace the last good numbers with an empty card.
    guard Self.available, !running, now >= pauseUntil, s.usage != nil || s.error != nil,
          CloudSnapshot.shouldUpload(key: s.displayKey, lastKey: lastKey, since: now.timeIntervalSince(lastAt)) else { return }
    running = true
    Task {
      defer { running = false }
      do {
        try await CloudSnapshot.upload(CloudSnapshot.phoneCopy(s))
        // Note the first upload and every recovery, so the log shows the sync works, not only when it fails.
        if lastAt == .distantPast || lastError != nil { logError("icloud: snapshot uploaded") }
        lastKey = s.displayKey
        lastAt = Date()
        lastError = nil
      } catch {
        pauseUntil = Date().addingTimeInterval(CloudSnapshot.retryDelay(error))
        if lastError != error.localizedDescription { logError("icloud: \(error)") }
        lastError = error.localizedDescription
      }
    }
  }
}
