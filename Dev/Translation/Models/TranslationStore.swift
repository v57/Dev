//
//  TranslationStore.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import SwiftData

/// What one clear of the translation store removed, per model (Design notes 7.5).
///
/// Per MODEL, not as one total: what a table held is the only evidence that a
/// clear ran at all — an empty store is otherwise indistinguishable from a store
/// nothing ever wrote to — so this is what the button reports back.
struct StoreClearCounts: Equatable {
  var slots = 0
  var journal = 0
  var contextDocs = 0
  var contextEdits = 0
  var memory = 0
  var cursors = 0

  /// Every row the clear removed.
  var removed: Int { slots + journal + contextDocs + contextEdits + memory + cursors }

  /// True when there was nothing to delete — the second press of the button.
  var isEmpty: Bool { removed == 0 }

  /// One line naming every table, in the order 7.5 lists them.
  var summary: String {
    [
      "\(slots) slot record\(slots == 1 ? "" : "s")",
      "\(journal) journal row\(journal == 1 ? "" : "s")",
      "\(contextDocs) context document\(contextDocs == 1 ? "" : "s")",
      "\(contextEdits) context edit\(contextEdits == 1 ? "" : "s")",
      "\(memory) memory \(memory == 1 ? "entry" : "entries")",
      "\(cursors) run cursor\(cursors == 1 ? "" : "s")",
    ].joined(separator: ", ")
  }
}

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

  // MARK: - clearing the store (Design notes 7.5)

  /// Empties the app-side translation session and reports what it removed, per
  /// model.
  ///
  /// DELETES every row of `TranslationRecord`, `TranslationEdit`, `ContextDoc`,
  /// `ContextEdit`, `TranslationMemoryEntry` and `RunCursor`. KEEPS every
  /// `Project` row — the registry of names, catalog URLs and roots is
  /// configuration, not cache, and clearing it would empty the sidebar — and
  /// touches no `.xcstrings`: the artifact is untouched, which is the whole of
  /// what makes this survivable.
  ///
  /// NOTHING here re-derives what it deleted, deliberately: the context documents
  /// and the translation memory are what the app LEARNED from the reader's
  /// corrections, and re-scanning a catalog cannot rebuild either one.
  ///
  /// A caller that holds a MIRROR of this store must drop it before this runs, in
  /// the same main-actor turn: `LocalizationStore`'s rows carry the record objects
  /// themselves and the redesign's `Shell` holds workspaces built from them, so a
  /// live cache over a cleared store reads values that no longer exist.
  ///
  /// Idempotent: on an empty store it deletes nothing, saves nothing and returns
  /// an all-zero report. A second press is a no-op, not an error.
  @discardableResult
  func clear() throws -> StoreClearCounts {
    var counts = StoreClearCounts()
    counts.slots = try context.fetchCount(FetchDescriptor<TranslationRecord>())
    counts.journal = try context.fetchCount(FetchDescriptor<TranslationEdit>())
    counts.contextDocs = try context.fetchCount(FetchDescriptor<ContextDoc>())
    counts.contextEdits = try context.fetchCount(FetchDescriptor<ContextEdit>())
    counts.memory = try context.fetchCount(FetchDescriptor<TranslationMemoryEntry>())
    counts.cursors = try context.fetchCount(FetchDescriptor<RunCursor>())
    guard !counts.isEmpty else { return counts }
    // One fetch-and-delete per table, the trail before the rows it points at: an edit hangs off the
    // record it describes.
    //
    // NOT `ModelContext.delete(model:)`: the batch form is a store-level DELETE and cannot nullify
    // `TranslationEdit.record` — a mandatory to-one whose inverse, `TranslationRecord.edits`,
    // cascades — so it throws
    // "Constraint trigger violation: Batch delete failed due to mandatory OTO nullify inverse on
    // TranslationEdit/record" and deletes NOTHING. The object form walks the graph, which is what
    // the cascade rule is for. (`Project` is deliberately not in this list — the six tables above
    // are the scope, 7.5.)
    try deleteAll(TranslationEdit.self)
    try deleteAll(TranslationRecord.self)
    try deleteAll(ContextEdit.self)
    try deleteAll(ContextDoc.self)
    try deleteAll(TranslationMemoryEntry.self)
    try deleteAll(RunCursor.self)
    try context.save()
    NSLog("[TranslationStore] cleared %@", counts.summary)
    return counts
  }

  /// Deletes every row of one model, one object at a time. See `clear()` for why the batch form of
  /// a delete is not an option on these models.
  private func deleteAll<T: PersistentModel>(_ model: T.Type) throws {
    for row in try context.fetch(FetchDescriptor<T>()) {
      context.delete(row)
    }
  }
}
