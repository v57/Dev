//
//  TranslationStore.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import SwiftData

/// All SwiftData persistence for the self-improving translator: the model types in
/// this directory, plus `RunCursor` (the redesign's one schema addition, 10.16),
/// which is declared beside its only reader in `Localization/Redesign/Store.swift`.
///
/// Owns the app's ONE shared ModelContainer — exactly one, ever (a second
/// container traps on first fetch). The container is created lazily in a
/// static closure and injected into the scene graph via
/// `.modelContainer(TranslationStore.container)`; imperative work
/// (reconcile, pipeline) goes through `TranslationStore.shared.context`.
final class TranslationStore {
  /// Process-lifetime singleton.
  static let shared = TranslationStore()

  /// The ONE shared SwiftData container, created lazily in a static
  /// closure. Local-only store: no CloudKit, no iCloud entitlement in this
  /// app.
  static let container: ModelContainer = {
    let schema = Schema([
      Project.self,
      TranslationRecord.self,
      TranslationEdit.self,
      ContextDoc.self,
      ContextEdit.self,
      TranslationMemoryEntry.self,
      RunCursor.self,
    ])
    // Explicit per-app store: a SwiftData app that omits a URL lands on
    // default.store in whatever Application Support resolves to — for an
    // UNSANDBOXED build that is the SHARED ~/Library/Application Support/
    // default.store, where other unsandboxed SwiftData apps collide ("The
    // file default.store couldn't be opened", dropped tables, lost data).
    // Pinning a per-app URL keeps sandboxed and unsandboxed builds isolated
    // from each other and from other apps.
    let appSupport = URL.applicationSupportDirectory.appendingPathComponent(
      "dev.v57.dev", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    } catch { NSLog("[TranslationStore] cannot create %@: %@", appSupport.path, error as NSError) }
    let storeURL = appSupport.appendingPathComponent("Translation.store")
    let disk = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
    if let container = try? ModelContainer(for: schema, configurations: [disk]) { return container }
    // Unwritable/corrupt store: fall back to in-memory so the translator
    // still works. Log the failure — a silently missing disk store loses
    // the learning corpus.
    do { return try ModelContainer(for: schema, configurations: [disk]) } catch {
      NSLog("[TranslationStore] disk container failed, falling back to memory: %@", error as NSError)
      let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
      return try! ModelContainer(for: schema, configurations: [memory])
    }
  }()

  /// Main context for imperative work (reconcile, pipeline stages).
  let context: ModelContext

  private init() {
    context = ModelContext(Self.container)
  }
}
