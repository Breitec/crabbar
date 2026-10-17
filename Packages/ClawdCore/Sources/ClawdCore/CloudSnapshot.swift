import Foundation
import CloudKit

/// The widget snapshot as one record in the user's private CloudKit database. The Mac app writes it,
/// the iPhone app and its widgets read it, so the iPhone needs neither Claude credentials nor Anthropic APIs.
public enum CloudSnapshot {
  /// From the target's Info.plist (key ClawdCloudContainer, set from Config/Signing.xcconfig).
  public static let containerID: String = Bundle.main.object(forInfoDictionaryKey: "ClawdCloudContainer") as? String
    ?? "iCloud.com.example.crabbar"
  public static let subscriptionID = "clawd-snapshot"

  /// Uploads at most this often when what the widget shows changed...
  public static let minGap: TimeInterval = 60
  /// ...and at least this often, so the iPhone can tell a quiet Mac from one that stopped.
  public static let heartbeat: TimeInterval = 600
  /// How often the iPhone widget asks for a new timeline on its own.
  public static let phoneReload: TimeInterval = 900

  static let recordType = "Snapshot"
  static let field = "json"
  // Database subscriptions only see custom zones.
  static let zoneID = CKRecordZone.ID(zoneName: "CrabBar", ownerName: CKCurrentUserDefaultName)
  static let recordID = CKRecord.ID(recordName: "current", zoneID: zoneID)

  public static func shouldUpload(key: String, lastKey: String?, since: TimeInterval) -> Bool {
    since >= heartbeat || (key != lastKey && since >= minGap)
  }

  /// The iPhone hears from the Mac at least every heartbeat and its widget reloads about every 15 minutes,
  /// so its copy may be that much older before it counts as stale.
  public static func phoneCopy(_ s: WidgetSnapshot) -> WidgetSnapshot {
    var c = s
    c.staleAfter = (s.staleAfter ?? 210) + heartbeat + phoneReload
    return c
  }

  /// Seconds to wait after a failed upload.
  public static func retryDelay(_ error: Error) -> TimeInterval {
    guard let e = error as? CKError else { return 300 }
    if let r = e.retryAfterSeconds { return max(r, minGap) }
    switch e.code {
    case .notAuthenticated, .permissionFailure, .managedAccountRestricted, .badContainer, .missingEntitlement: return 1800
    default: return 300
    }
  }

  public static func isNoAccount(_ error: Error) -> Bool {
    (error as? CKError)?.code == .notAuthenticated
  }

  // MARK: - CloudKit

  static let database = CKContainer(identifier: containerID).privateCloudDatabase

  /// Short enough for a widget's timeline request.
  static func withTimeout<R>(_ body: @escaping @Sendable (CKDatabase) async throws -> R) async throws -> R {
    let c = CKOperation.Configuration()
    c.timeoutIntervalForRequest = 10
    c.timeoutIntervalForResource = 20
    return try await database.configuredWith(configuration: c) { try await body($0) }
  }

  /// Overwrites the record (the payload is an encrypted field); creates the zone on first use.
  public static func upload(_ s: WidgetSnapshot) async throws {
    let data = try s.encoded()
    func save() async throws {
      let rec = CKRecord(recordType: recordType, recordID: recordID)
      rec.encryptedValues[field] = data
      let (results, _) = try await withTimeout { try await $0.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys) }
      if case .failure(let e) = results[recordID] { throw e }
    }
    do {
      try await save()
    } catch let e where missingZone(e) {
      let (results, _) = try await withTimeout { try await $0.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: []) }
      if case .failure(let e) = results[zoneID] { throw e }
      try await save()
    }
  }

  /// The Mac's latest snapshot, nil while it has not written one.
  public static func fetch() async throws -> WidgetSnapshot? {
    do {
      let rec = try await withTimeout { try await $0.record(for: recordID) }
      guard let d = rec.encryptedValues[field] as? Data else { return nil }
      return try WidgetSnapshot.decoded(d)
    } catch let e where missingZone(e) || (e as? CKError)?.code == .unknownItem {
      return nil
    }
  }

  /// Fetches and keeps the result in this device's App Group for the widgets.
  @discardableResult
  public static func pull() async throws -> WidgetSnapshot? {
    guard let s = try await fetch() else { return nil }
    SharedStore.save(s)
    return s
  }

  /// The App Group copy if this device checked within `maxAge`, otherwise a fresh one;
  /// the old copy when iCloud can't be reached.
  public static func latest(maxAge: TimeInterval = minGap) async -> WidgetSnapshot? {
    let local = SharedStore.load()
    if local != nil, let at = SharedStore.savedAt, Date().timeIntervalSince(at) < maxAge { return local }
    return (try? await pull()) ?? local
  }

  /// A silent push for every change of the record. Saving it again just replaces it.
  public static func subscribe() async throws {
    let sub = CKDatabaseSubscription(subscriptionID: subscriptionID)
    sub.recordType = recordType
    let info = CKSubscription.NotificationInfo()
    info.shouldSendContentAvailable = true
    sub.notificationInfo = info
    let (results, _) = try await withTimeout { try await $0.modifySubscriptions(saving: [sub], deleting: []) }
    if case .failure(let e) = results[subscriptionID] { throw e }
  }

  static func missingZone(_ error: Error) -> Bool {
    guard let e = error as? CKError else { return false }
    if e.code == .zoneNotFound || e.code == .userDeletedZone { return true }
    return e.partialErrorsByItemID?.values.contains { missingZone($0) } ?? false
  }
}
