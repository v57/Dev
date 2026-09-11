//
//  Reconcile.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import SwiftData

// MARK: - Reconcile

/// The catalog <-> DB bridge. Two directions, one contract:
///
///  - LOAD (`upsertFromCatalog`) mirrors the .xcstrings file into the
///    project's TranslationRecords, keyed (key, language). One record per
///    (translatable key x non-source language) slot — the exact surface the
///    browser can edit — so untranslated slots become `.empty` records a
///    later pipeline run picks up. Records the DB already owns (any value,
///    provider, state or edit history) keep their DB-only provenance
///    (provider, context-versions, state) across a reload: only sourceText
///    is refreshed. Records are never deleted here — the DB is the durable
///    provenance store and a key dropped from the file must not erase who
///    translated it.
///
///  - SAVE (`commit`) writes the working store back to the artifact: every
///    record with a value gets its value + mapped state written into the
///    parsed catalog's stringUnit and the file is atomically rewritten —
///    but only when something actually differs, so an untouched reload is a
///    no-op write. reviewed -> "translated", needs_review -> "needs_review";
///    empty records write nothing (absence IS the empty state).
///
/// Keep the file the artifact; the DB is the working/provenance store.
///
/// `nonisolated`: the mirror is pure store work on models the caller hands in,
/// and the OPEN/RELOAD path runs it on a background `ModelContext` — a large
/// catalog's upsert is seconds of inserts (see `mirrorOffMainActor`). Marking
/// the enum instead of each member keeps that path and the main-actor callers
/// (edits, runs, the sidebar's import) on the same functions.
nonisolated enum Reconcile {
  // MARK: - state mapping

  /// SwiftData on this SDK decomposes ContextVersions into nullable columns
  /// and CRASHES re-faulting any row whose stored versions are all nil
  /// ("Could not cast Optional<Any> to ContextVersions"). ContextDocs start
  /// at version 1, so a stored 0 is a safe sentinel for "no doc existed at
  /// the time": staleness math treats it exactly like nil ((v ?? -1) < doc
  /// version, and 0 < 1 is always true once a doc exists). Every
  /// ContextVersions Reconcile persists goes through this — nil members are
  /// preserved, only the all-nil corner is lifted.
  static func persistableVersions(_ versions: ContextVersions) -> ContextVersions {
    if versions.global == nil, versions.project == nil, versions.language == nil {
      return ContextVersions(global: 0)
    }
    return versions
  }

  /// DB state -> xcstrings stringUnit state. `.empty` has no file
  /// representation (absence IS the empty state).
  static func fileState(for state: TranslationState) -> String? {
    switch state {
    case .empty: return nil
    case .needs_review: return "needs_review"
    case .reviewed: return "translated"
    }
  }

  /// File stringUnit state -> DB state when seeding a fresh record.
  /// "translated" is the only state that implies human approval; everything
  /// else with a value (needs_review, new, unknown/nil) is unconfirmed
  /// machine/import output until a human reviews it. Never auto-promotes.
  static func seedState(fileState: String?) -> TranslationState {
    switch fileState {
    case "translated": return .reviewed
    default: return .needs_review
    }
  }

  // MARK: - project

  /// The project's records, materialized in ONE query.
  ///
  /// Never bulk-iterate `project.records`: SwiftData faults a to-many one
  /// object at a time (measured 4.2 s to iterate 48,420 records, versus 0.7 s
  /// for the same rows through this fetch — same lesson as the sidebar's
  /// badges). Scoped by the project's identity, so a multi-project store pays
  /// only for this project. Falls back to the relationship if the predicate is
  /// ever unsupported, and returns nothing for a project that is not in the
  /// store yet (nothing to mirror against).
  static func records(of project: Project, in context: ModelContext) -> [TranslationRecord] {
    let id = project.persistentModelID
    let descriptor = FetchDescriptor<TranslationRecord>(
      predicate: #Predicate { $0.project?.persistentModelID == id })
    if let fetched = try? context.fetch(descriptor) { return fetched }
    return project.records
  }

  /// The project whose catalog lives at `catalogURL`, or nil.
  static func existingProject(
    catalogURL: URL,
    in context: ModelContext
  ) -> Project? {
    let descriptor = FetchDescriptor<Project>()
    guard let projects = try? context.fetch(descriptor) else { return nil }
    return projects.first { $0.catalogURL == catalogURL }
  }

  /// The project with this identity, or nil.
  ///
  /// A FETCH, not `context.model(for:)`: a fetch returns the store's current
  /// values for the registered instance, which is what a caller needs after
  /// another context wrote to the same rows (the mirror runs in its own
  /// background context — verified: a registered instance keeps serving its
  /// stale relationship snapshot until a fetch refreshes it).
  static func project(id: PersistentIdentifier, in context: ModelContext) -> Project? {
    let descriptor = FetchDescriptor<Project>()
    return (try? context.fetch(descriptor))?.first { $0.persistentModelID == id }
  }

  /// Finds the project for a catalog URL, creating it on first sight. The
  /// name is the catalog's home directory (the merged catalog lives at the
  /// repo root, so this is the repo name) — stable per URL.
  static func ensureProject(
    catalogURL: URL,
    in context: ModelContext
  ) -> Project {
    if let existing = existingProject(catalogURL: catalogURL, in: context) {
      return existing
    }
    let home = catalogURL.deletingLastPathComponent().lastPathComponent
    let name = home.isEmpty ? catalogURL.lastPathComponent : home
    let project = Project(name: name, catalogURL: catalogURL)
    context.insert(project)
    return project
  }

  /// Resolves the project a DROPPED DIRECTORY imports as: name = the
  /// folder's last path component, rootURL = the standardized folder URL,
  /// catalogURL = `catalogURL` when the caller discovered one deeper in the
  /// tree (see `CatalogDiscovery`), else <root>/Localizable.xcstrings — and
  /// iconURL = <root>/Assets.xcassets/AppIcon.appiconset. Resolved whether or
  /// not those files exist yet (a folder with neither still becomes a
  /// project; 'no catalog' / placeholder icon are display-time derivations).
  ///
  /// Finds-or-creates so re-dropping the same folder never duplicates:
  /// matched by rootURL first (an earlier directory drop), then by the
  /// resolved catalog URL (a row first seen via its .xcstrings file is
  /// adopted in place — records, contextDoc and name survive — and upgraded
  /// to a directory-root project). The catalog-file path (`ensureProject`)
  /// is untouched: LocalizationView reconcile still keys rows by catalog
  /// URL alone.
  static func resolveDirectoryProject(
    rootDir: URL,
    catalogURL discoveredCatalog: URL? = nil,
    in context: ModelContext
  ) -> Project {
    let root = rootDir.standardizedFileURL
    let catalogURL = discoveredCatalog?.standardizedFileURL
      ?? root.appendingPathComponent(CatalogDiscovery.canonicalName)
    let iconURL = root
      .appendingPathComponent("Assets.xcassets", isDirectory: true)
      .appendingPathComponent("AppIcon.appiconset", isDirectory: true)
    let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
    if let byRoot = projects.first(where: { $0.rootURL == root }) {
      return byRoot
    }
    if let byCatalog = projects.first(where: { $0.catalogURL == catalogURL }) {
      byCatalog.rootURL = root
      byCatalog.iconURL = iconURL
      return byCatalog
    }
    let project = Project(
      name: root.lastPathComponent,
      catalogURL: catalogURL,
      rootURL: root,
      iconURL: iconURL)
    context.insert(project)
    return project
  }

  // MARK: - load (file -> DB)

  /// Outcome counts of one upsert, for logging.
  struct UpsertStats: Sendable {
    var created = 0
    var refreshed = 0  // unowned slot adopted the file's value/state
    var kept = 0       // DB-owned record untouched by the reload
  }

  /// What a background mirror wrote, in Sendable form: the model object itself
  /// never crosses an actor boundary, only this identity plus the counts.
  struct MirrorResult: Sendable {
    let projectID: PersistentIdentifier
    let stats: UpsertStats
  }

  /// Mirrors `catalog` into the store on a BACKGROUND `ModelContext` — the
  /// open/reload path for a catalog whose upsert is seconds of work (48,420
  /// slots measured at ~6 s in Debug, and the inserts cannot be moved off the
  /// main actor without moving the context that owns them).
  ///
  /// The caller is responsible for what happens after: re-fetch the project in
  /// the main context (`project(id:in:)`) before reading its records, because
  /// the main context's copies are stale until then. Nothing here touches the
  /// open catalog's in-memory state, so a failed write leaves the document
  /// openable — the caller decides how to report it.
  static func mirrorOffMainActor(
    _ catalog: StringCatalog,
    catalogURL: URL,
    in container: ModelContainer
  ) async -> Result<MirrorResult, Error> {
    await Task.detached(priority: .userInitiated) {
      let context = ModelContext(container)
      let project = ensureProject(catalogURL: catalogURL, in: context)
      // This context is COLD, so the records come from one scoped fetch —
      // iterating the relationship here would fault every row one at a time
      // (measured 4.2 s for 48,420 records, versus ~0.6 s for the fetch).
      let existing = records(of: project, in: context)
      let stats = upsertFromCatalog(
        catalog, project: project, existing: existing, context: context)
      do {
        try context.save()
      } catch {
        return .failure(error)
      }
      return .success(MirrorResult(projectID: project.persistentModelID, stats: stats))
    }.value
  }

  // MARK: - plural skeleton (run preparation, off the main actor)

  /// Progress of one plural-skeleton pass, yielded from the background task.
  struct PluralSkeletonProgress: Sendable {
    let completed: Int
    let total: Int
    let key: String?
  }

  /// What a skeleton pass produced. The catalog crosses the actor boundary as
  /// a VALUE (it is a Sendable struct), so the caller adopts the varied
  /// document without the file being touched — Save stays the only writer.
  struct PluralSkeletonOutcome: Sendable {
    let catalog: StringCatalog
    /// True when the catalog gained plural variations.
    let varied: Bool
    /// Form records created.
    let inserted: Int
    /// True when the pass stopped early because the user cancelled.
    let cancelled: Bool
  }

  /// One (key, language, form) slot, as a Set member — the per-form
  /// existence check.
  private struct SlotKey: Hashable {
    let key: String
    let language: String
    let category: String
  }

  /// Creates the missing plural-form records + the CLDR form skeleton a run
  /// needs, OFF the main actor, and returns the catalog to adopt.
  ///
  /// This is the step that used to block the UI for a whole-catalog run: it
  /// asked `record(key:language:category:in:)` — a LINEAR SCAN of the
  /// project's records — once per (key, language, category), walked the
  /// relationship to collect the keys, recomputed the catalog's languages
  /// inside the key loop (computed property: walks every entry), and linked
  /// every inserted record with its own `record.project = project` assignment
  /// (SwiftData inverse maintenance per insert). It now runs in one background
  /// context with the existing slots in a Set, `catalog.languages` hoisted, and
  /// the project link applied in ONE bulk append.
  ///
  /// Mirrors the pipeline's reconcile rule: only keys whose SOURCE is
  /// plural-varied gain forms; a single-key run with no languages selected
  /// creates nothing. Cancelling stops the scan where it is and KEEPS what was
  /// already inserted (the same policy as a cancelled run: forms are additive
  /// and correct, nothing is rolled back); the caller decides not to start the
  /// run.
  static func ensurePluralForms(
    catalog: StringCatalog,
    projectID: PersistentIdentifier,
    key: String?,
    languages: Set<String>?,
    in container: ModelContainer,
    isCancelled: @escaping @Sendable () -> Bool = { false },
    progress: (@Sendable (PluralSkeletonProgress) -> Void)? = nil
  ) async -> Result<PluralSkeletonOutcome, Error> {
    await Task.detached(priority: .userInitiated) {
      let context = ModelContext(container)
      guard let project = project(id: projectID, in: context) else {
        // The project is gone (removed while the run was being prepared):
        // nothing to create forms for.
        return .success(PluralSkeletonOutcome(
          catalog: catalog, varied: false, inserted: 0, cancelled: false))
      }

      // One scoped fetch for the existing slots — this context is cold, so the
      // relationship would fault per row.
      let existing = records(of: project, in: context)
      var slots = Set<SlotKey>()
      slots.reserveCapacity(existing.count)
      for record in existing {
        slots.insert(SlotKey(
          key: record.key, language: record.language, category: record.category ?? ""))
      }

      var mutated = catalog
      let keys = key.map { [$0] } ?? existing.map(\.key).uniqued()
      // Computed (walks every entry): hoisted out of the key loop.
      let sourceLanguages = mutated.languages.filter { $0 != mutated.sourceLanguage }
      var varied = false
      var created: [TranslationRecord] = []
      var completed = 0
      var cancelled = false
      progress?(PluralSkeletonProgress(completed: 0, total: keys.count, key: nil))

      for (index, targetKey) in keys.enumerated() {
        // Reported per key, throttled: the footer needs a live count, not a
        // main-actor hop per key of a 1382-key catalog.
        defer {
          completed = index + 1
          if completed % 16 == 0 || completed == keys.count {
            progress?(PluralSkeletonProgress(
              completed: completed, total: keys.count, key: targetKey))
          }
        }
        if isCancelled() {
          cancelled = true
          break
        }
        guard mutated.hasPlurals(for: targetKey, language: mutated.sourceLanguage) else { continue }
        let targetLanguages: [String]
        if let languages {
          if languages.isEmpty { continue }
          targetLanguages = languages.sorted()
        } else {
          targetLanguages = sourceLanguages
        }
        for language in targetLanguages {
          if !mutated.hasPlurals(for: targetKey, language: language) {
            mutated.varyByPlural(key: targetKey, languages: [language])
            varied = true
          }
          guard mutated.hasPlurals(for: targetKey, language: language) else { continue }
          for category in PluralRules.categories(for: language) {
            let slot = SlotKey(key: targetKey, language: language, category: category)
            if slots.contains(slot) { continue }
            let record = TranslationRecord(
              key: targetKey,
              sourceText: mutated.sourcePluralDisplay(for: targetKey, category: category),
              language: language,
              value: nil, provider: nil, state: .empty,
              contextVersions: persistableVersions(ContextVersions()),
              category: category)
            context.insert(record)
            created.append(record)
            slots.insert(slot)
          }
        }
      }

      if !created.isEmpty {
        // ONE bulk append instead of a to-one assignment per insert.
        project.records.append(contentsOf: created)
      }
      do {
        try context.save()
      } catch {
        return .failure(error)
      }
      return .success(PluralSkeletonOutcome(
        catalog: mutated, varied: varied, inserted: created.count, cancelled: cancelled))
    }.value
  }

  /// Mirrors the parsed catalog into the project's TranslationRecords:
  /// every (translatable key, non-source language) pair the catalog knows.
  /// Pairs the file carries no unit for become `.empty` records (Stage 1
  /// fills those). Plural forms get one record per (key, language, category)
  /// — each form is a full translation slot the pipeline fills like a flat
  /// row. A variation holder with NO plural (device-only) gets no record — a
  /// device-varied key cannot carry a flat stringUnit, and the UI marks such
  /// cells read-only.
  ///
  /// `existing` is the project's current records, supplied by the caller
  /// because they are not free to obtain: fetching them is one query (~0.6 s
  /// for 48k rows) where the relationship is already materialized, and
  /// iterating `project.records` costs seconds where it is not (see
  /// `records(of:in:)`). So the background mirror passes a fetch, the warm
  /// main-actor paths pass the relationship.
  @discardableResult
  static func upsertFromCatalog(
    _ catalog: StringCatalog,
    project: Project,
    existing: [TranslationRecord],
    context: ModelContext
  ) -> UpsertStats {
    var stats = UpsertStats()

    // Existing records of this project, indexed for O(1) lookups.
    // Keyed (key, language, category-or-flat).
    var bySlot: [String: [String: [String: TranslationRecord]]] = [:]
    for record in existing {
      bySlot[record.key, default: [:]][record.language, default: [:]][record.category ?? ""] = record
    }

    let sourceLanguage = catalog.sourceLanguage
    // Newly created records are linked to the project in ONE bulk append
    // after the loop, never `record.project = project` per record: assigning
    // the to-one inside the loop makes SwiftData run its inverse-maintenance
    // bookkeeping once per insert, which is quadratic-ish on a big catalog —
    // measured 46.1 s for 48,420 records that way versus 2.0 s for
    // insert-then-`project.records.append(contentsOf:)` (7 MB / 1382-key
    // playgra catalog, 37 languages; the assignment must not move back into
    // the loop, and setting it BEFORE the insert is worse still: 455 s).
    // `catalog.languages` is COMPUTED: it walks every entry of the catalog and
    // sorts the result. Evaluating it inside the key loop made the reconcile
    // quadratic in the key count (1382 x 1382 entry walks for the playgra
    // catalog). Hoisted once, like `sourceLanguage`.
    let sourceLanguages = catalog.languages
    var created: [TranslationRecord] = []
    for (key, entry) in catalog.strings {
      // Non-translatable keys are hidden from the workflow entirely.
      if entry.shouldTranslate == false { continue }
      for language in sourceLanguages where language != sourceLanguage {
        let loc = entry.localizations?[language]
        let variations = loc?.variations ?? [:]
        let deviceOnly = !variations.isEmpty && variations["plural"] == nil
        if deviceOnly { continue }
        if let plural = variations["plural"], !plural.isEmpty {
          // Plural slot: one record per CLDR category of the target
          // language. The per-form source text comes from the source
          // language's matching form (fallback: source "other", then key).
          for category in PluralRules.categories(for: language) {
            let unit = plural[category]?.stringUnit
            let rawValue = unit?.value ?? ""
            let value: String? = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              ? nil
              : rawValue
            upsertForm(
              key: key, language: language, category: category,
              sourceText: catalog.sourcePluralDisplay(for: key, category: category),
              value: value,
              seedState: unit.map { seedState(fileState: $0.state) },
              context: context, bySlot: &bySlot, stats: &stats,
              created: &created)
          }
          continue
        }
        // Flat slot (unchanged).
        let unit = loc?.stringUnit
        let rawValue = unit?.value ?? ""
        let value: String? = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? nil
          : rawValue
        upsertSlot(
          key: key, language: language,
          sourceText: catalog.sourceDisplay(for: key),
          value: value,
          seedState: unit.map { seedState(fileState: $0.state) },
          context: context, bySlot: &bySlot, stats: &stats,
          created: &created)
      }
    }
    if !created.isEmpty {
      project.records.append(contentsOf: created)
    }
    // The CALLER saves: the background mirror reports a failed write to the
    // user, so the save cannot be a swallowed `try?` in here.
    return stats
  }

  /// What the FILE says one slot should be — the target an unowned mirror
  /// must equal after a reconcile.
  ///
  /// Exists so the upsert can COMPARE before writing. The previous version
  /// rewrote every unowned mirror record on every open unconditionally
  /// (measured: 45,306 records rewritten, 12.7 s on the 7 MB / 1382-key
  /// playgra catalog) even when file and DB already agreed, and bumped
  /// `updatedAt` on rows nothing had touched.
  private struct FileSlot {
    let value: String?
    let state: TranslationState
    let sourceText: String

    /// True when `record` already carries exactly the file's slot: value,
    /// mapped state, source text and the reset provenance an unowned mirror
    /// has (no provider/confidence/review stamp, default context versions).
    func matches(_ record: TranslationRecord) -> Bool {
      record.value == value
        && record.state == state
        && record.provider == nil
        && record.confidence == nil
        && record.reviewedAt == nil
        && record.sourceText == sourceText
        && record.contextVersions == persistableVersions(ContextVersions())
    }

    /// Adopts the file's slot: the value and mapped state, plus the provenance
    /// reset that marks the record an unowned mirror again.
    func apply(to record: TranslationRecord) {
      record.value = value
      record.state = state
      record.provider = nil
      record.confidence = nil
      record.reviewedAt = nil
      record.contextVersions = persistableVersions(ContextVersions())
      record.sourceText = sourceText
      record.updatedAt = .now
    }
  }

  /// Plural (key, language, category) slot. Same ownership rule as the flat
  /// slot: DB-owned records keep value/provider/state, unowned file mirrors
  /// adopt the file's current form value/state (or go empty when the form
  /// vanished).
  private static func upsertForm(
    key: String,
    language: String,
    category: String,
    sourceText: String,
    value: String?,
    seedState: TranslationState?,
    context: ModelContext,
    bySlot: inout [String: [String: [String: TranslationRecord]]],
    stats: inout UpsertStats,
    created: inout [TranslationRecord]
  ) {
    if let record = bySlot[key]?[language]?[category] {
      let fileSlot = FileSlot(
        value: value, state: value != nil ? (seedState ?? .needs_review) : .empty,
        sourceText: sourceText)
      if record.provider != nil || !record.edits.isEmpty {
        // DB-OWNED record: keep value/provider/state/versions; refresh the
        // source text only when it actually moved.
        if record.sourceText != sourceText { record.sourceText = sourceText }
        stats.kept += 1
      } else if fileSlot.matches(record) {
        stats.kept += 1
      } else {
        fileSlot.apply(to: record)
        stats.refreshed += 1
      }
      return
    }

    let record = TranslationRecord(
      key: key,
      sourceText: sourceText,
      language: language,
      value: value,
      provider: nil,
      state: value != nil ? (seedState ?? .needs_review) : .empty,
      contextVersions: persistableVersions(ContextVersions()),
      category: category
    )
    context.insert(record)
    // The project link is applied by the caller in one bulk append — see
    // upsertFromCatalog.
    created.append(record)
    bySlot[key, default: [:]][language, default: [:]][category] = record
    stats.created += 1
  }

  /// One (key, language) slot. Ownership rule on reload:
  ///  - record is DB-OWNED (provider or edit history — human edits, machine
  ///    fills, TM copies) -> keep value/provider/state/versions untouched;
  ///    refresh sourceText only. DB provenance survives the reload even
  ///    when the file is stale (a crash between pipeline run and commit
  ///    must not lose machine output).
  ///  - record is an unowned FILE MIRROR (provider nil, no edits — created
  ///    by an earlier upsert) -> re-mirror the file: adopt its value/state,
  ///    or go back to empty when the file dropped the unit. The artifact
  ///    wins for rows nobody in this app has worked on (e.g. an Xcode-side
  ///    edit between sessions must not be reverted by the next commit).
  ///  - no record -> create one from the file (or as an `.empty` seed).
  private static func upsertSlot(
    key: String,
    language: String,
    sourceText: String,
    value: String?,
    seedState: TranslationState?,
    context: ModelContext,
    bySlot: inout [String: [String: [String: TranslationRecord]]],
    stats: inout UpsertStats,
    created: inout [TranslationRecord]
  ) {
    if let record = bySlot[key]?[language]?[""] {
      let fileSlot = FileSlot(
        value: value, state: value != nil ? (seedState ?? .needs_review) : .empty,
        sourceText: sourceText)
      if record.provider != nil || !record.edits.isEmpty {
        // DB-OWNED record: keep value/provider/state/versions; the file may
        // only refresh the source text (and even that is skipped when it
        // already matches).
        if record.sourceText != sourceText { record.sourceText = sourceText }
        stats.kept += 1
      } else if fileSlot.matches(record) {
        stats.kept += 1
      } else {
        fileSlot.apply(to: record)
        stats.refreshed += 1
      }
      return
    }

    let record = TranslationRecord(
      key: key,
      sourceText: sourceText,
      language: language,
      value: value,
      provider: nil,
      state: value != nil ? (seedState ?? .needs_review) : .empty,
      contextVersions: persistableVersions(ContextVersions())
    )
    context.insert(record)
    // The project link is applied by the caller in one bulk append — see
    // upsertFromCatalog.
    created.append(record)
    bySlot[key, default: [:]][language, default: [:]][""] = record
    stats.created += 1
  }

  // MARK: - single record lookup

  /// The record for a (key, language) flat slot of a project, or nil.
  static func record(
    key: String,
    language: String,
    in project: Project
  ) -> TranslationRecord? {
    record(key: key, language: language, category: nil, in: project)
  }

  /// The record for a (key, language, category) slot, or nil. Category nil =
  /// the flat slot.
  static func record(
    key: String,
    language: String,
    category: String?,
    in project: Project
  ) -> TranslationRecord? {
    project.records.first { $0.key == key && $0.language == language && $0.category == category }
  }

  // MARK: - human edit (DB side)

  /// Applies a human-confirmed value to the record. A human typing a value
  /// IS a confirmation: state -> .reviewed, reviewedAt + lastEditor set.
  ///  - value changed -> provider .manual and a user-confirmed
  ///    TranslationEdit row (the Stage-0 learning corpus) is appended.
  ///  - value unchanged (pure confirmation of an existing machine value) ->
  ///    the producing provider is kept — provenance survives — and the
  ///    record is promoted to .reviewed without an edit row.
  /// Never touches the file; call `commit` to write it back.
  @discardableResult
  static func applyHumanEdit(
    key: String,
    language: String,
    value: String,
    sourceText: String,
    project: Project,
    context: ModelContext,
    category: String? = nil
  ) -> TranslationRecord {
    let record = record(key: key, language: language, category: category, in: project)
      ?? {
        let record = TranslationRecord(
          key: key, sourceText: sourceText, language: language,
          value: nil, provider: nil, state: .empty,
          contextVersions: persistableVersions(ContextVersions()),
          category: category)
        context.insert(record)
        record.project = project
        return record
      }()

    let valueChanged = record.value != value
    if valueChanged {
      let edit = TranslationEdit(
        record: record,
        fromValue: record.value,
        toValue: value,
        editor: .human,
        contextVersions: persistableVersions(ContextVersions()),
        isUserConfirmed: true
      )
      record.edits.append(edit)
      context.insert(edit)
      record.value = value
      // The human authored this value; the machine is no longer the writer.
      record.provider = .manual
      record.confidence = nil
    }
    record.sourceText = sourceText
    record.state = .reviewed
    record.autoReviewed = false  // any human action supersedes auto-reviewed
    record.reviewedAt = .now
    record.updatedAt = .now
    let userName = ProcessInfo.processInfo.fullUserName
    record.lastEditor = userName.isEmpty ? "Manual" : userName
    try? context.save()
    return record
  }

  // MARK: - row review state (DB side)

  /// Marks a whole key's filled slots as `reviewed` (human-confirmed — keeps
  /// the producing provider and value, so provenance survives; records the
  /// confirming user) or `needs_review` (un-confirm: keeps provider, clears
  /// reviewedAt). Empty slots are left untouched — a reviewed empty slot has
  /// no value to confirm, and committing one would write a bogus
  /// "translated" unit into the file. Pure confirmation of an existing value
  /// appends NO TranslationEdit (that is the learning signal for a value
  /// *change*; here nothing changed). Never touches the file; call `commit`
  /// to write it back. Returns how many records changed.
  @discardableResult
  static func applyReviewState(
    key: String,
    state: TranslationState,
    project: Project,
    context: ModelContext
  ) -> Int {
    let userName = ProcessInfo.processInfo.fullUserName
    var touched = 0
    for record in project.records where record.key == key {
      guard let value = record.value,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continue
      }
      record.state = state
      // A manual state flip ends auto-reviewed status either way: confirming
      // makes it human-reviewed, un-confirming demotes it to plain machine
      // output (the auto badge is a reviewed-state concept).
      record.autoReviewed = false
      record.updatedAt = .now
      if state == .reviewed {
        record.reviewedAt = .now
        record.lastEditor = userName.isEmpty ? "Manual" : userName
      } else {
        record.reviewedAt = nil
      }
      touched += 1
    }
    try? context.save()
    return touched
  }

  // MARK: - merge (DB -> in-memory catalog)

  /// Merges the working store into a copy of the parsed catalog — the pure,
  /// in-memory half of the former `commit`. The artifact write itself is
  /// scheduled by the caller through CatalogFileIO (background, coalesced),
  /// so no encode/file I/O ever runs on this thread. For every DB-OWNED
  /// record in scope that carries a value, the (key, language) stringUnit —
  /// or (plural key, language, category) form — value + state is set on the
  /// copy. DB-owned = the record carries provenance (provider or edit
  /// history): human edits, machine fills, TM copies. Pure file-origin seed
  /// rows (provider nil, no edits) are passive — their value already
  /// matches the file by construction, and their raw file state (Xcode may
  /// say "new") is left alone until a real owner writes the row. Device
  /// variation holders and the source language are never touched. Plural
  /// form records write into the variation skeleton (creating CLDR forms as
  /// needed); a flat record never touches a plural slot and vice versa.
  ///
  /// Pass `keys` to scope the walk to specific catalog keys — the
  /// row-driven saves the UI issues (one edited row = its key) merge only
  /// that row's records instead of the whole project. `nil` walks the full
  /// record set (end-of-run flush). Per-record semantics are identical.
  ///
  /// Returns the merged catalog (the caller adopts it so the UI stays in
  /// sync) plus whether any unit actually changed — a no-op merge never
  /// churns the artifact.
  @discardableResult
  static func merge(
    _ catalog: StringCatalog,
    project: Project,
    keys: Set<String>? = nil
  ) -> (catalog: StringCatalog, changed: Bool) {
    var updated = catalog
    var changed = false
    let sourceLanguage = catalog.sourceLanguage

    let records = keys.map { wanted in
      project.records.filter { wanted.contains($0.key) }
    } ?? project.records
    for record in records {
      guard let value = record.value,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continue  // empty slots stay absent in the file
      }
      // Never resurrect a key the catalog no longer carries.
      guard updated.strings[record.key] != nil else { continue }
      if record.language == sourceLanguage { continue }
      guard let fileState = fileState(for: record.state) else { continue }

      if let category = record.category {
        // Plural form record: write the form, never the flat unit.
        let current = updated.pluralValue(for: record.key, language: record.language, category: category)
        let currentState = updated.pluralState(for: record.key, language: record.language, category: category)
        if current == value && currentState == fileState {
          continue  // file already carries this form
        }
        let owned = record.provider != nil || !record.edits.isEmpty
        if !owned && (current == value || current == nil) {
          continue  // file-origin seed: passive, the artifact wins
        }
        updated.setPluralValue(value, state: fileState, key: record.key, language: record.language, category: category)
        changed = true
        continue
      }

      // Flat record: never touch a plural-varied slot.
      if updated.hasPlurals(for: record.key, language: record.language) {
        continue
      }
      if updated.hasDeviceVariations(for: record.key, language: record.language) {
        continue  // device holders are read-only in this phase
      }

      let current = updated.strings[record.key]?.localizations?[record.language]?.stringUnit
      let valueMatches = current?.value == value
      let stateMatches = current?.state == fileState
      if valueMatches && stateMatches {
        continue  // file already carries this row
      }
      let owned = record.provider != nil || !record.edits.isEmpty
      if !owned && (valueMatches || current == nil) {
        // File-origin seed: the value already matches (leave the file's raw
        // state alone), or the unit vanished from the file (the artifact
        // wins — the next reload refreshes this unowned record to empty).
        continue
      }

      var entry = updated.strings[record.key]!
      var localizations = entry.localizations ?? [:]
      var language = localizations[record.language] ?? StringCatalog.Language()
      language.stringUnit = StringCatalog.StringUnit(state: fileState, value: value)
      localizations[record.language] = language
      entry.localizations = localizations
      updated.strings[record.key] = entry
      changed = true
    }

    return (updated, changed)
  }
}
