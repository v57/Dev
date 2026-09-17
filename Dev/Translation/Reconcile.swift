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
///    The one case that rule cannot decide by itself is a slot BOTH sides
///    fill with DIFFERENT values: the app's records hold what a run or an
///    import wrote, the file holds what a translator typed in Xcode, and
///    whichever the mirror keeps the other one is gone (keeping the record
///    also means the next Save writes it back OVER the file's value). That
///    is a question, not a rule: an `.ask` pass writes nothing and reports
///    the differences (`SlotDifference`), and the user's answer is what the
///    load then mirrors with (`DifferencePolicy`). See
///    `LocalizationStore.resolveDifferences`.
///
///  - SAVE (`commit`) writes the working store back to the artifact: every
///    record with a value gets its value + mapped state written into the
///    parsed catalog's stringUnit and the file is atomically rewritten —
///    but only when something actually differs, so an untouched reload is a
///    no-op write. reviewed -> "translated", needs_review -> "needs_review",
///    and an AUTO-REVIEWED (imported-DB) copy -> "needs_review" too: a value
///    nobody vouched for is not the file's `translated`; empty records write
///    nothing (absence IS the empty state).
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

  /// The state one RECORD's value writes to the file.
  ///
  /// A record knows one thing its state alone does not: `autoReviewed` — an imported-DB copy
  /// is `.reviewed` with nobody behind it (no human confirmed it, `reviewedAt` is nil, the
  /// "auto" badge says so in the UI). Its file state is `"needs_review"`, the same one a
  /// machine value carries: `"translated"` is Xcode's word for a HUMAN confirmation and
  /// writing it here would claim one that never happened — a catalog that then reads back
  /// with the value looking approved by a person. The `.imported` provenance itself stays
  /// app-side; the file only learns that the value is unreviewed.
  static func fileState(for record: TranslationRecord) -> String? {
    if record.state == .reviewed, record.autoReviewed { return "needs_review" }
    return fileState(for: record.state)
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

  /// What the file's own unit says about one slot — the value it carries (`nil` when the
  /// file leaves it absent or blank, because absence IS the empty state) and the state it
  /// claims, mapped to the DB's vocabulary. The ONE reading of a unit: the mirror's slot
  /// upserts and the difference scan both go through it, so a scan can never disagree with
  /// the mirror about what the file said.
  private static func unitValue(
    _ unit: StringCatalog.StringUnit?
  ) -> (value: String?, state: TranslationState?) {
    let raw = unit?.value ?? ""
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed.isEmpty ? nil : raw, unit.map { seedState(fileState: $0.state) })
  }

  /// The file's unit for one FLAT (key, language).
  private static func fileUnit(
    _ catalog: StringCatalog, key: String, language: String
  ) -> (value: String?, state: TranslationState?) {
    unitValue(catalog.strings[key]?.localizations?[language]?.stringUnit)
  }

  /// The file's unit for one PLURAL form of a (key, language).
  private static func fileForm(
    _ catalog: StringCatalog, key: String, language: String, category: String
  ) -> (value: String?, state: TranslationState?) {
    let plural = catalog.strings[key]?.localizations?[language]?.variations?["plural"]
    return unitValue(plural?[category]?.stringUnit)
  }

  /// True when the app has worked on this record: a provider produced its value or an edit
  /// was journaled for it (a human's typing, a machine fill, a TM copy). The mirror's
  /// ownership test, in one place.
  private static func isOwned(_ record: TranslationRecord) -> Bool {
    record.provider != nil || record.edits?.isEmpty == false
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
    return project.records ?? []
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
    var refreshed = 0  // unowned slot adopted the file's value/state; or, under
                       // `fileWins`, an owned one the user told us to refresh
    var kept = 0       // DB-owned record untouched by the reload
    /// Slots where the file and a DB-OWNED record BOTH carry a value and they
    /// differ (see `SlotDifference`). Counted under every policy — the answer to
    /// the question does not change how many slots it was about.
    var differing = 0
    /// A capped sample of those slots, for the prompt's text (see
    /// `DifferenceReport.sampleLimit`). Never the whole set: a real catalog can
    /// differ on thousands of slots and nothing draws them.
    var differenceSample: [SlotDifference] = []

    /// What the pass found, in the form that crosses an actor boundary.
    var differenceReport: DifferenceReport {
      DifferenceReport(count: differing, sample: differenceSample)
    }
  }

  /// One slot the FILE and the app's records both fill, with different values.
  ///
  /// This is the set a load has to ASK about. Where a slot is filled on one side
  /// only, the mirror's rule is enough: the file's value wins for a row nobody in
  /// this app has worked on (an unowned file mirror), the app's value wins for a row
  /// it owns (a run's output the file has not been given yet) — and a slot the file
  /// has nothing for is the app's own unsaved work, which the design deliberately
  /// keeps alive rather than asking about on every open. Where BOTH sides hold a
  /// value and they disagree, keeping the record throws a human's Xcode-side edit
  /// away (and the next Save writes the record's value back over the file), while
  /// taking the file's throws the app's own value away. Neither is the app's call.
  struct SlotDifference: Sendable, Equatable {
    /// The catalog key.
    let key: String
    /// Target language.
    let language: String
    /// The plural form this slot is ("one", "other", …); nil for a flat slot.
    let category: String?
    /// What the FILE carries.
    let fileValue: String
    /// What the project's record carries.
    let recordValue: String

    /// The slot as the prompt names it: `key (language)` or `key (language, one)`.
    var label: String {
      guard let category else { return "\(key) (\(language))" }
      return "\(key) (\(language), \(category))"
    }
  }

  /// What a pass found, as an answer the caller can act on: the EXACT number of
  /// differing slots, plus a sample of them (the list is capped because a large
  /// catalog's diff is thousands of slots and only a few are ever printed).
  struct DifferenceReport: Sendable {
    let count: Int
    let sample: [SlotDifference]

    /// How many differing slots one report carries.
    static let sampleLimit = 8

    var isEmpty: Bool { count == 0 }
  }

  /// What a (re)load does when the file and the app's records disagree about a slot — the
  /// user's answer to the versions prompt.
  ///
  /// - `fileWins`: adopt the FILE's value for those slots, whatever the record's provenance
  ///   says (the user's answer when the file is the newer writer).
  /// - `appWins`: the mirror's own rule (a DB-owned record keeps its value and the file's
  ///   differing one is dropped, until the next Save writes the record's out).
  ///
  /// The QUESTION itself is not a policy: it is asked before anything is mirrored
  /// (`detectDifferences`), because a pass that had already picked a side would be asking
  /// about a state the user can no longer choose.
  enum DifferencePolicy: Sendable, Equatable {
    case fileWins
    case appWins
  }

  /// What a background mirror wrote, in Sendable form: the model object itself
  /// never crosses an actor boundary, only this identity plus the counts.
  struct MirrorResult: Sendable {
    let projectID: PersistentIdentifier
    let stats: UpsertStats
    /// Slots the pass had taken from the FILE and then gave back, because the app wrote
    /// them while it ran — by the guard before the commit (`revertFileWrites`) or by the
    /// repair after it. For the log.
    let reverted: Int
    /// Rows the pass's own commit dropped out of the project's membership and the pass put
    /// back (`orphanedRows`) — for the log.
    let repaired: Int
  }

  /// One write a pass made FROM the FILE, with what the slot held before it — enough to put
  /// the slot back when it turns out the app wrote it while the pass was running.
  ///
  /// The pass is a SNAPSHOT: it decides who owns a slot from the records it fetched when it
  /// started. The app keeps working beside it now (the pane is open and a run can be
  /// started while the mirror catches up), so a slot the app saves mid-pass is invisible to
  /// that snapshot — the pass would adopt the file over a value someone typed or a run just
  /// produced, and for a record the pass CREATES it would leave two rows for one slot
  /// (SwiftData has no unique constraint to stop it). `revertFileWrites` is what honours
  /// the newer writer.
  enum FileWrite {
    /// A record this pass inserted — the whole row is the pass's, so giving it back is a
    /// delete.
    case created(TranslationRecord)
    /// A record this pass re-mirrored or adopted from the file (unowned mirror, or the
    /// `fileWins` answer over an owned one) — with the edit row `fileWins` appended, if it
    /// did.
    case adopted(TranslationRecord, before: PreSlot, edit: TranslationEdit?)

    /// The record this write was about.
    var record: TranslationRecord {
      switch self {
      case .created(let record): return record
      case .adopted(let record, _, _): return record
      }
    }
  }

  /// The whole row a record held before a pass touched it, field by field — the fields a
  /// slot upsert can write, and nothing else.
  struct PreSlot {
    let value: String?
    let state: TranslationState
    let provider: Provider?
    let confidence: Double?
    let autoReviewed: Bool
    let reviewedAt: Date?
    let contextVersions: ContextVersions
    let sourceText: String
    let updatedAt: Date

    init(_ record: TranslationRecord) {
      value = record.value
      state = record.state
      provider = record.provider
      confidence = record.confidence
      autoReviewed = record.autoReviewed
      reviewedAt = record.reviewedAt
      contextVersions = record.contextVersions
      sourceText = record.sourceText
      updatedAt = record.updatedAt
    }

    func restore(_ record: TranslationRecord) {
      record.value = value
      record.state = state
      record.provider = provider
      record.confidence = confidence
      record.autoReviewed = autoReviewed
      record.reviewedAt = reviewedAt
      record.contextVersions = contextVersions
      record.sourceText = sourceText
      record.updatedAt = updatedAt
    }
  }

  /// The log a pass keeps of its own file-driven writes, for `revertFileWrites`.
  ///
  /// A box rather than a returned array, because the pass that needs it is deep inside the
  /// shared upsert and the two callers that do NOT need it (the per-key mutations, which
  /// write and save in place on the main actor where nothing can interleave) must not pay
  /// for it: they pass nil.
  ///
  /// `FileWrite`, `PreSlot` and this box are the pass's own bookkeeping and nothing else
  /// reads them; they are internal only because the shared upsert takes them as parameters.
  final class FileWriteLog {
    private(set) var writes: [FileWrite] = []

    /// The records this pass INSERTED — the membership write at the pass's tail needs them,
    /// because nothing else links them to the project (`upsertFromCatalog` skips its own bulk
    /// append while the app is live).
    var created: [TranslationRecord] {
      writes.compactMap {
        if case .created(let record) = $0 { return record }
        return nil
      }
    }

    func record(_ write: FileWrite) { writes.append(write) }
  }

  /// The difference scan a load runs BEFORE it mirrors anything: every slot the file and a
  /// DB-owned record both fill with different values (`SlotDifference`), found WITHOUT
  /// writing a row.
  ///
  /// This is what makes the versions prompt possible at all in a load that does not wait:
  /// the question has to be asked before a side is picked (see `DifferencePolicy`), and the
  /// load has to be able to ask it without having mirrored the catalog first. It is also the
  /// cheap half of the work — one scoped fetch plus a walk, no inserts, no save.
  ///
  /// A project the store does not know yet has nothing to disagree with (a first open can
  /// only seed), and neither does one whose records are all unowned file mirrors.
  static func detectDifferences(
    _ catalog: StringCatalog,
    catalogURL: URL,
    in container: ModelContainer
  ) async -> DifferenceReport {
    await Task.detached(priority: .userInitiated) {
      let context = ModelContext(container)
      guard let project = existingProject(catalogURL: catalogURL, in: context) else {
        return DifferenceReport(count: 0, sample: [])
      }
      return differences(catalog, existing: records(of: project, in: context))
    }.value
  }

  /// The scan itself, over records the caller hands in — pure, so a probe can ask it the
  /// same question the load asks.
  ///
  /// A slot counts when the file fills it AND the record is DB-OWNED (`isOwned`) and fills
  /// it with something else. Two shapes deliberately do NOT count: a slot the file has
  /// nothing for (the app's own unsaved work — the design keeps it alive across a crash
  /// rather than asking about it on every open) and a slot only the file fills (an unowned
  /// mirror, which the file already wins).
  static func differences(
    _ catalog: StringCatalog,
    existing: [TranslationRecord]
  ) -> DifferenceReport {
    var bySlot: [SlotKey: TranslationRecord] = [:]
    bySlot.reserveCapacity(existing.count)
    for record in existing {
      bySlot[SlotKey(
        key: record.key, language: record.language, category: record.category ?? "")] = record
    }

    var count = 0
    var sample: [SlotDifference] = []
    func compare(_ key: String, _ language: String, _ category: String?, _ fileValue: String?) {
      guard let fileValue,
            let record = bySlot[SlotKey(key: key, language: language, category: category ?? "")],
            isOwned(record),
            let recordValue = record.value,
            recordValue != fileValue
      else { return }
      count += 1
      if sample.count < DifferenceReport.sampleLimit {
        sample.append(SlotDifference(
          key: key, language: language, category: category,
          fileValue: fileValue, recordValue: recordValue))
      }
    }

    let sourceLanguage = catalog.sourceLanguage
    // Computed (walks every entry): hoisted out of the key loop, like the mirror's own.
    let languages = catalog.languages
    for (key, entry) in catalog.strings {
      if entry.shouldTranslate == false { continue }
      for language in languages where language != sourceLanguage {
        let variations = entry.localizations?[language]?.variations ?? [:]
        // A device-varied holder carries no translatable slot at all (same rule as the
        // mirror: a flat unit cannot live there and nothing ever cleans one up).
        if !variations.isEmpty, variations["plural"] == nil { continue }
        if let plural = variations["plural"], !plural.isEmpty {
          for category in PluralRules.categories(for: language) {
            compare(
              key, language, category,
              fileForm(catalog, key: key, language: language, category: category).value)
          }
          continue
        }
        compare(key, language, nil, fileUnit(catalog, key: key, language: language).value)
      }
    }
    return DifferenceReport(count: count, sample: sample)
  }

  /// Mirrors `catalog` into the store on a BACKGROUND `ModelContext` — the open/reload
  /// path for a catalog whose upsert is seconds of work (48,420 slots measured at ~6 s in
  /// Debug, and the inserts cannot be moved off the main actor without moving the context
  /// that owns them).
  ///
  /// The caller is responsible for what happens after: re-fetch the project in
  /// the main context (`project(id:in:)`) before reading its records, because
  /// the main context's copies are stale until then. Nothing here touches the
  /// open catalog's in-memory state, so a failed write leaves the document
  /// openable — the caller decides how to report it.
  ///
  /// This pass does NOT block the pane: the load adopts the parsed file first and submits
  /// this behind it (`StoreWork.shared`), so the table is up while the store catches up. A
  /// consequence worth naming: the app can now write a slot while this pass runs, and the
  /// pass's own snapshot cannot see that. `revertFileWrites` is what keeps the newer writer
  /// — and the only reason a pass needs to know when it started.
  static func mirrorOffMainActor(
    _ catalog: StringCatalog,
    catalogURL: URL,
    in container: ModelContainer,
    policy: DifferencePolicy = .appWins
  ) async -> Result<MirrorResult, Error> {
    await Task.detached(priority: .userInitiated) {
      // The watermark for "the app wrote this slot while the pass was running".
      let passStartedAt = Date()
      let context = ModelContext(container)
      let project = ensureProject(catalogURL: catalogURL, in: context)
      // This context is COLD, so the records come from one scoped fetch —
      // iterating the relationship here would fault every row one at a time
      // (measured 4.2 s for 48,420 records, versus ~0.6 s for the fetch).
      let existing = records(of: project, in: context)
      let log = FileWriteLog()
      var stats = upsertFromCatalog(
        catalog, project: project, existing: existing, context: context,
        policy: policy, fileWrites: log, liveWriters: true)
      // THE APP'S OWN WRITES, read here — as late as the pass can read them and still act: they
      // are the slots this pass gives back (`revertFileWrites`). What a read at this point
      // cannot catch (a write committed between it and the commit) is the repair below's job.
      let appWrites = appWrittenRows(
        project: project, since: passStartedAt, excluding: log, in: context)
      var reverted = revertFileWrites(
        log.writes, writtenByApp: Set(appWrites.map(slotKey)), context: context, stats: &stats)
      do {
        try context.save()
      } catch {
        return .failure(error)
      }
      // THE COMMIT'S OWN CASUALTY, repaired AFTER it — because only the store can show it.
      //
      // Writing a to-many from this context's view of the project writes the membership as this
      // context holds it, and every member it does not list has its inverse nullified: a row the
      // app links while the pass runs comes out of the commit with `project = nil` — ORPHANED,
      // invisible to every project-scoped reader in the app (found by the probe: an app edit
      // landing beside the pass's own row for its slot). The guard above cannot see that last
      // writer: it reads the app's writes a moment before the commit, and a write committed in
      // between is invisible until the commit is on disk. So the orphan is read back from the
      // store — the only place it is visible at all — and put where it belongs.
      //
      // Serial by construction, which is what makes this safe to do blind: only the mirror ever
      // writes a membership (the other bulk passes go through the same queue), so a project-less
      // row stamped inside this pass's window is this pass's doing, whatever slot it is.
      //
      // Paid only when the pass had something to link (no membership write, no casualty).
      var repaired = 0
      if !log.created.isEmpty {
        var createdBySlot: [SlotKey: TranslationRecord] = [:]
        for record in log.created { createdBySlot[slotKey(record)] = record }
        for orphan in orphanedRows(since: passStartedAt, in: container) {
          // The pass made its OWN row for that slot while the app was writing one — the guard
          // above missed it in the same window. The app's write is the newer one (that is the
          // guard's rule), so the pass's row goes.
          if let rival = createdBySlot[slotKey(orphan)] {
            context.delete(rival)
            stats.created -= 1
            // Counted as given back: that is what it is, only later than the guard could.
            reverted.insert(ObjectIdentifier(rival))
          }
          guard
            let row = context.model(for: orphan.persistentModelID) as? TranslationRecord,
            row.project == nil
          else { continue }
          row.project = project
          repaired += 1
        }
        if repaired > 0, (try? context.save()) == nil {
          NSLog("[Reconcile] \(repaired) app row(s) could not be re-linked to their project")
        }
      }
      return .success(MirrorResult(
        projectID: project.persistentModelID, stats: stats, reverted: reverted.count,
        repaired: repaired))
    }.value
  }

  /// The slot a record occupies, in the form the passes compare by.
  private static func slotKey(_ record: TranslationRecord) -> SlotKey {
    SlotKey(key: record.key, language: record.language, category: record.category ?? "")
  }

  /// The rows the APP ITSELF wrote since `since`, read on the pass's own context (so the two
  /// sets can be compared by identity) and with the pass's own writes removed — those are the
  /// ones whose `updatedAt` this pass just moved.
  ///
  /// Project-scoped and time-bounded: a row the app wrote has both. An already-orphaned row is
  /// NOT found here, which is why the repair below reads the store again with a time-only query.
  private static func appWrittenRows(
    project: Project,
    since: Date,
    excluding log: FileWriteLog,
    in context: ModelContext
  ) -> [TranslationRecord] {
    let id = project.persistentModelID
    let descriptor = FetchDescriptor<TranslationRecord>(
      predicate: #Predicate {
        $0.project?.persistentModelID == id && $0.updatedAt > since
      })
    guard let moved = try? context.fetch(descriptor) else { return [] }
    let ours = Set(log.writes.map { ObjectIdentifier($0.record) })
    return moved.filter { !ours.contains(ObjectIdentifier($0)) }
  }

  /// Every row saved since `since` that belongs to NO project — what a stale membership write
  /// leaves behind. One query, no project scope (an orphan has no project to be scoped by).
  private static func orphanedRows(
    since: Date,
    in container: ModelContainer
  ) -> [TranslationRecord] {
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<TranslationRecord>(
      predicate: #Predicate { $0.updatedAt > since })
    return ((try? context.fetch(descriptor)) ?? []).filter { $0.project == nil }
  }

  /// Gives back every write the pass made FROM THE FILE for a slot the app wrote while it
  /// ran: the record the pass inserted is deleted, a re-mirrored or adopted one is restored
  /// to the row it held before (and the edit row a `fileWins` adoption appended goes with
  /// it).
  ///
  /// Without this the two writers race and the OLDER one wins, because the pass decides
  /// ownership from a snapshot: an Xcode-side value would land over a translation a run had
  /// just produced, or over the word someone had just typed, and a created record would sit
  /// beside the app's own row for the same slot — two rows, one slot, SwiftData holding no
  /// constraint that could have refused it.
  ///
  /// Returns WHICH records were given back (by identity: the caller must not put a deleted one
  /// back into the project's member list). The counts in `stats` follow, so the log tells the
  /// truth about what the pass actually left behind.
  private static func revertFileWrites(
    _ writes: [FileWrite],
    writtenByApp: Set<SlotKey>,
    context: ModelContext,
    stats: inout UpsertStats
  ) -> Set<ObjectIdentifier> {
    guard !writtenByApp.isEmpty else { return [] }
    var reverted: Set<ObjectIdentifier> = []
    for write in writes {
      let record: TranslationRecord
      switch write {
      case .created(let created):
        record = created
        let slot = SlotKey(
          key: record.key, language: record.language, category: record.category ?? "")
        guard writtenByApp.contains(slot) else { continue }
        context.delete(record)
        stats.created -= 1
      case .adopted(let adopted, let before, let edit):
        record = adopted
        let slot = SlotKey(
          key: record.key, language: record.language, category: record.category ?? "")
        guard writtenByApp.contains(slot) else { continue }
        before.restore(record)
        if let edit {
          record.edits?.removeAll { $0 === edit }
          context.delete(edit)
        }
        stats.refreshed -= 1
      }
      reverted.insert(ObjectIdentifier(record))
    }
    return reverted
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
        project.records = (project.records ?? []) + created
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

  // MARK: - adding a language (off the main actor)

  /// What one "add a language" pass produced. Only counts cross the actor
  /// boundary — the document half of the add is the caller's own catalog,
  /// mutated in place (see `LocalizationStore.addLanguage`), never a snapshot
  /// from before the pass: a translation run or an edit can land while the
  /// seeding runs, and adopting a stale document would drop it.
  struct LanguageAddOutcome: Sendable {
    /// Records created — one per translatable key, one per CLDR form for a
    /// plural-source key.
    let inserted: Int
    /// Keys in scope when the pass ran (0 = an empty catalog, nothing to
    /// seed).
    let keyCount: Int
  }

  /// Seeds the records a freshly added `language` needs, OFF the main actor (a
  /// big catalog's seeding is thousands of inserts).
  ///
  /// Pairs with `StringCatalog.addLanguage`, which gives the document the
  /// language's nodes only. Those nodes are EMPTY, and an empty localization
  /// node is a file error — `normalizeForWrite` prunes them on the way to disk
  /// — so the added language is recognizable again after a reopen by its
  /// RECORDS, never by the file: the browser reads the record set alongside
  /// the catalog's own codes (see `LocalizationStore.browserLanguages`).
  ///
  /// Slot seeding follows the mirror's rule for a pair the file carries no unit
  /// for (an `.empty` record the pipeline fills), with one deliberate
  /// difference: a key whose SOURCE is plural-varied gets its per-form records
  /// straight away, because a flat record on a plural slot is something the
  /// merge refuses to write and nothing ever cleans up. The caller varies the
  /// document's forms for that key in the same breath.
  ///
  /// Records the project already holds for these languages are left exactly as
  /// they are (value, provenance, state), so re-adding a language costs nothing
  /// and can never rewrite a translation.
  static func addLanguage(
    _ language: String,
    catalog: StringCatalog,
    projectID: PersistentIdentifier,
    in container: ModelContainer
  ) async -> Result<LanguageAddOutcome, Error> {
    await addLanguages(
      [language], catalog: catalog, projectID: projectID, in: container)
  }

  /// Same for a SET of languages — the Add Languages overlay adds everything it
  /// was given in ONE pass: one background context, one slot set, one save, and
  /// one walk of the catalog's keys rather than one per language.
  static func addLanguages(
    _ languages: [String],
    catalog: StringCatalog,
    projectID: PersistentIdentifier,
    in container: ModelContainer
  ) async -> Result<LanguageAddOutcome, Error> {
    await Task.detached(priority: .userInitiated) {
      let context = ModelContext(container)
      guard let project = project(id: projectID, in: context) else {
        // The project is gone (removed while the add was in flight): nothing
        // to seed.
        return .success(LanguageAddOutcome(inserted: 0, keyCount: 0))
      }
      // This context is COLD, so the existing slots come from one scoped
      // fetch — iterating the relationship here would fault per row.
      let existing = records(of: project, in: context)
      var slots = Set<SlotKey>()
      slots.reserveCapacity(existing.count)
      for record in existing {
        slots.insert(SlotKey(
          key: record.key, language: record.language, category: record.category ?? ""))
      }

      var created: [TranslationRecord] = []
      var keyCount = 0
      for key in catalog.strings.keys {
        // Non-translatable keys are hidden from the workflow entirely.
        guard let entry = catalog.strings[key], entry.shouldTranslate != false else { continue }
        keyCount += 1
        let pluralSource = catalog.hasPlurals(for: key, language: catalog.sourceLanguage)
        for language in languages {
          if pluralSource {
            for category in PluralRules.categories(for: language) {
              let slot = SlotKey(key: key, language: language, category: category)
              if slots.contains(slot) { continue }
              let record = TranslationRecord(
                key: key,
                sourceText: catalog.sourcePluralDisplay(for: key, category: category),
                language: language,
                value: nil, provider: nil, state: .empty,
                contextVersions: persistableVersions(ContextVersions()),
                category: category)
              context.insert(record)
              created.append(record)
              slots.insert(slot)
            }
            continue
          }
          let slot = SlotKey(key: key, language: language, category: "")
          if slots.contains(slot) { continue }
          let record = TranslationRecord(
            key: key,
            sourceText: catalog.sourceDisplay(for: key),
            language: language,
            value: nil, provider: nil, state: .empty,
            contextVersions: persistableVersions(ContextVersions()))
          context.insert(record)
          created.append(record)
          slots.insert(slot)
        }
      }

      if !created.isEmpty {
        // ONE bulk append instead of a to-one assignment per insert.
        project.records = (project.records ?? []) + created
      }
      do {
        try context.save()
      } catch {
        return .failure(error)
      }
      return .success(LanguageAddOutcome(inserted: created.count, keyCount: keyCount))
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
  ///
  /// `policy` decides what a slot the file and an owned record disagree about does
  /// (`DifferencePolicy`): the load's answer. `.appWins` is the default because it is
  /// what every non-load caller wants — the per-key mutations (a scan merge, a plural
  /// vary) mirror a catalog whose values the app itself just wrote, so there is
  /// nothing for a user to decide.
  ///
  /// `fileWrites` is where the pass logs every write it makes FROM THE FILE, so a slot the
  /// app saves while the pass runs can be given back (`revertFileWrites`). The in-place
  /// callers pass nil: they write and save on the main actor, where nothing interleaves.
  ///
  /// `liveWriters` says the app itself may be writing records while this pass runs — true for
  /// the background mirror, which no longer blocks the pane, false for the in-place callers.
  /// It changes ONE thing: how the project's record list is written (see the bulk append at
  /// the end of the walk). Read it as "this pass is not the only writer right now".
  @discardableResult
  static func upsertFromCatalog(
    _ catalog: StringCatalog,
    project: Project,
    existing: [TranslationRecord],
    context: ModelContext,
    policy: DifferencePolicy = .appWins,
    fileWrites: FileWriteLog? = nil,
    liveWriters: Bool = false
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
            let form = fileForm(catalog, key: key, language: language, category: category)
            upsertForm(
              key: key, language: language, category: category,
              sourceText: catalog.sourcePluralDisplay(for: key, category: category),
              value: form.value,
              seedState: form.state,
              context: context, bySlot: &bySlot, stats: &stats,
              created: &created, policy: policy, fileWrites: fileWrites)
          }
          continue
        }
        // Flat slot (unchanged).
        let unit = fileUnit(catalog, key: key, language: language)
        upsertSlot(
          key: key, language: language,
          sourceText: catalog.sourceDisplay(for: key),
          value: unit.value,
          seedState: unit.state,
          context: context, bySlot: &bySlot, stats: &stats,
          created: &created, policy: policy, fileWrites: fileWrites)
      }
    }
    if !created.isEmpty {
      // ONE bulk append instead of a to-one assignment per record (see the note above).
      //
      // Either shape WRITES the whole membership, and that is what the mirror's repair step is
      // about: a to-many written from a view that predates another writer's link drops that
      // member and nullifies its inverse (probe: the app's mid-pass row came out `project = nil`
      // with both shapes, and the to-one form costs 3x here). So this stays the cheap shape and
      // `mirrorOffMainActor` re-links what the commit dropped.
      project.records = (project.records ?? []) + created
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
  /// vanished) — and a form both sides fill with different values is resolved by
  /// the same `resolveOwnedSlot` the flat slot uses, under the load's policy.
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
    created: inout [TranslationRecord],
    policy: DifferencePolicy,
    fileWrites: FileWriteLog?
  ) {
    if let record = bySlot[key]?[language]?[category] {
      let fileSlot = FileSlot(
        value: value, state: value != nil ? (seedState ?? .needs_review) : .empty,
        sourceText: sourceText)
      if isOwned(record) {
        // DB-OWNED record: keep value/provider/state/versions, unless the file carries a
        // different value for this very slot (see resolveOwnedSlot).
        resolveOwnedSlot(
          record: record, fileSlot: fileSlot, sourceText: sourceText,
          policy: policy, context: context, stats: &stats, fileWrites: fileWrites)
      } else if fileSlot.matches(record) {
        stats.kept += 1
      } else {
        fileWrites?.record(.adopted(record, before: PreSlot(record), edit: nil))
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
    fileWrites?.record(.created(record))
    bySlot[key, default: [:]][language, default: [:]][category] = record
    stats.created += 1
  }

  /// One (key, language) slot. Ownership rule on reload:
  ///  - record is DB-OWNED (provider or edit history — human edits, machine
  ///    fills, TM copies) -> keep value/provider/state/versions untouched;
  ///    refresh sourceText only. DB provenance survives the reload even
  ///    when the file is stale (a crash between pipeline run and commit
  ///    must not lose machine output). A file that fills this same slot with a
  ///    DIFFERENT value is the one thing this rule may not decide alone — see
  ///    `resolveOwnedSlot`.
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
    created: inout [TranslationRecord],
    policy: DifferencePolicy,
    fileWrites: FileWriteLog?
  ) {
    if let record = bySlot[key]?[language]?[""] {
      let fileSlot = FileSlot(
        value: value, state: value != nil ? (seedState ?? .needs_review) : .empty,
        sourceText: sourceText)
      if isOwned(record) {
        // DB-OWNED record: keep value/provider/state/versions, unless the file carries a
        // different value for this very slot (see resolveOwnedSlot).
        resolveOwnedSlot(
          record: record, fileSlot: fileSlot, sourceText: sourceText,
          policy: policy, context: context, stats: &stats, fileWrites: fileWrites)
      } else if fileSlot.matches(record) {
        stats.kept += 1
      } else {
        fileWrites?.record(.adopted(record, before: PreSlot(record), edit: nil))
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
    fileWrites?.record(.created(record))
    bySlot[key, default: [:]][language, default: [:]][""] = record
    stats.created += 1
  }

  /// The DB-OWNED branch of one slot, shared by `upsertSlot` and `upsertForm` — one
  /// definition, so a plural form can never be resolved differently from the flat row
  /// beside it.
  ///
  /// The record keeps everything (value, provider, state, context versions) and the
  /// file may only refresh its source text — EXCEPT when the file fills this very slot
  /// with a different value. That is the case the mirror's ownership rule cannot decide:
  /// the app's value came from a run or an import, the file's from a human in Xcode, and
  /// keeping the record both throws the file's edit away and makes the next Save write
  /// the record's value back over the file. So the slot is COUNTED as a difference
  /// (`stats`) and the policy — the user's answer to the load's question — decides:
  /// `fileWins` adopts the file's slot (`adoptFile`), anything else keeps the record.
  private static func resolveOwnedSlot(
    record: TranslationRecord,
    fileSlot: FileSlot,
    sourceText: String,
    policy: DifferencePolicy,
    context: ModelContext,
    stats: inout UpsertStats,
    fileWrites: FileWriteLog?
  ) {
    // The source is the artifact's wherever it moved, whether or not the value is
    // contested: the file is where source text is authored.
    if record.sourceText != sourceText { record.sourceText = sourceText }
    guard let fileValue = fileSlot.value,
          let recordValue = record.value,
          recordValue != fileValue
    else {
      stats.kept += 1
      return
    }

    stats.differing += 1
    if stats.differenceSample.count < DifferenceReport.sampleLimit {
      stats.differenceSample.append(SlotDifference(
        key: record.key, language: record.language, category: record.category,
        fileValue: fileValue, recordValue: recordValue))
    }
    if policy == .fileWins {
      adoptFile(fileSlot, into: record, context: context, fileWrites: fileWrites)
      stats.refreshed += 1
    } else {
      stats.kept += 1
    }
  }

  /// Adopts the file's slot over a DB-OWNED record: the value and mapped state, the
  /// source text, and the provenance reset that marks the record an unowned mirror
  /// again — PLUS an edit row for the value it replaced.
  ///
  /// The edit row is what keeps the app's own corpus honest: the value the record held
  /// was produced by a run or an import and the file's is a person's, so the
  /// before->after pair is exactly the correction Stage 0 learns from. Without it the
  /// app's value would be gone with no trace of who replaced it, which is the loss this
  /// whole path exists to make deliberate. `editor: .human` and `isUserConfirmed: true`
  /// say the truth about it: a person edited this catalog, and the app read it back.
  /// It also leaves the record DB-OWNED (`edits` is no longer empty), so the value the
  /// user just chose is what survives the reloads that follow.
  private static func adoptFile(
    _ fileSlot: FileSlot,
    into record: TranslationRecord,
    context: ModelContext,
    fileWrites: FileWriteLog?
  ) {
    let edit = TranslationEdit(
      record: record,
      fromValue: record.value,
      toValue: fileSlot.value ?? "",
      editor: .human,
      reason: "Adopted from the catalog file on reload",
      contextVersions: persistableVersions(ContextVersions()),
      isUserConfirmed: true)
    record.edits = (record.edits ?? []) + [edit]
    context.insert(edit)
    // Logged BEFORE the slot is overwritten: the row to restore is the one it holds now.
    fileWrites?.record(.adopted(record, before: PreSlot(record), edit: edit))
    fileSlot.apply(to: record)
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
    (project.records ?? []).first { $0.key == key && $0.language == language && $0.category == category }
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
      record.edits = (record.edits ?? []) + [edit]
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
    for record in project.records ?? [] where record.key == key {
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

  // MARK: - reviewer note (DB side)

  /// What a row's reviewer note does. `project` folds the note into the
  /// project's ContextDoc as a rule the translator follows; `memo` keeps it on
  /// the record for humans only — the translator never sees it. Persisted as a
  /// raw string on the record, so the cases must not be renamed.
  enum NoteScope: String, CaseIterable {
    case project
    case memo

    var title: String {
      switch self {
      case .project: return "Project rule (guides the translator)"
      case .memo: return "Note only (stays in the app)"
      }
    }
  }

  /// Sets (or clears) the reviewer note of every record of one key and, for
  /// `.project`, folds it into the project's ContextDoc.
  ///
  /// Folding is DETERMINISTIC, not model-driven: the doc line IS the note, so
  /// coverage is an exact-line check — no LLM call, no dedup marker, and the
  /// fold cannot drift from what the reviewer typed. Every real content change
  /// writes a ContextEdit with `author == .manual` and bumps the version; a
  /// note re-saved unchanged writes nothing.
  ///
  /// The project version is stamped on records for provenance and is the
  /// signal the Update Translations pass reads; it deliberately does NOT
  /// auto-enqueue records (see PipelineRunContext.isStale).
  @discardableResult
  static func applyNote(
    key: String,
    note: String,
    scope: NoteScope,
    project: Project,
    context: ModelContext
  ) -> Int {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    let records = (project.records ?? []).filter { $0.key == key }
    // The line folded by a previous save — retracted or replaced, if any.
    let previous = records.compactMap(\.noteFoldedText).first { !$0.isEmpty }

    for record in records {
      record.note = trimmed.isEmpty ? nil : trimmed
      record.noteScope = trimmed.isEmpty ? nil : scope.rawValue
      record.updatedAt = .now
    }

    guard scope == .project else {
      try? context.save()  // a memo never leaves the DB
      return records.count
    }

    foldProjectRule(
      line: trimmed, previous: previous, key: key, project: project, context: context)
    for record in records {
      record.noteFoldedText = trimmed.isEmpty ? nil : trimmed
      record.noteFoldedAt = trimmed.isEmpty ? nil : .now
    }
    try? context.save()
    return records.count
  }

  /// Applies ONE rule line to the project doc: replaces the previously folded
  /// line in place, appends a new one, or drops it when the note was cleared
  /// (a retraction). No-op when the doc already reads exactly like this, so a
  /// re-save never churns the version.
  private static func foldProjectRule(
    line: String,
    previous: String?,
    key: String,
    project: Project,
    context: ModelContext
  ) {
    let old = (previous ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let doc = project.contextDoc
    let current = doc?.content ?? ""
    var lines = current
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    if !old.isEmpty, let index = lines.firstIndex(of: old) {
      lines.remove(at: index)
    }
    if !line.isEmpty, !lines.contains(line) {
      lines.append(line)
    }
    while let first = lines.first,
          first.trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeFirst()
    }
    while let last = lines.last,
          last.trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeLast()
    }
    let revised = lines.joined(separator: "\n")
    guard revised != current else { return }

    let reason = line.isEmpty
      ? "Reviewer note retracted on \(key) — rule removed from the project context"
      : "Reviewer note on \(key) — project rule"
    let audit: ContextEdit
    if let doc {
      doc.content = revised
      doc.version += 1
      doc.updatedAt = .now
      audit = ContextEdit(
        contextDoc: doc, before: current, after: revised, reason: reason, author: .manual)
    } else {
      let created = ContextDoc(
        scope: .project, identifier: project.name, version: 1,
        content: revised, createdAt: .now, updatedAt: .now, project: project)
      context.insert(created)
      project.contextDoc = created
      audit = ContextEdit(
        contextDoc: created, before: nil, after: revised, reason: reason, author: .manual)
    }
    context.insert(audit)
  }

  /// Replaces the project's context body wholesale — the human editor's save
  /// path (trim, audit, ONE version bump; no-op when the text is unchanged).
  /// This is also where a rule is retracted by hand.
  @discardableResult
  static func applyProjectDoc(
    content: String,
    project: Project,
    context: ModelContext
  ) -> Bool {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    let doc = project.contextDoc
    guard trimmed != (doc?.content ?? "") else { return false }
    let audit: ContextEdit
    if let doc {
      let before = doc.content
      doc.content = trimmed
      doc.version += 1
      doc.updatedAt = .now
      audit = ContextEdit(
        contextDoc: doc, before: before, after: trimmed,
        reason: "Project context edited by hand", author: .manual)
    } else {
      let created = ContextDoc(
        scope: .project, identifier: project.name, version: 1,
        content: trimmed, createdAt: .now, updatedAt: .now, project: project)
      context.insert(created)
      project.contextDoc = created
      audit = ContextEdit(
        contextDoc: created, before: nil, after: trimmed,
        reason: "Project context created by hand", author: .manual)
    }
    context.insert(audit)
    try? context.save()
    return true
  }

  // MARK: - max width guideline (DB side)

  /// Sets (or clears, with nil) the row's MAX WIDTH guideline across every
  /// record of the key. App-local metadata: the .xcstrings format has no width
  /// field and Save is the only catalog writer, so nothing here touches the
  /// file.
  ///
  /// The guideline is NEVER sent to the translator — a width constraint in a
  /// translation prompt degrades the translation, which is exactly why it
  /// lives on the review side: the browser flags an over-width value for the
  /// human, and the paid verification gate may shorten one.
  @discardableResult
  static func applyMaxWidth(
    key: String,
    width: Int?,
    project: Project,
    context: ModelContext
  ) -> Int {
    var touched = 0
    for record in project.records ?? [] where record.key == key {
      record.maxWidth = width
      record.updatedAt = .now
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
      (project.records ?? []).filter { wanted.contains($0.key) }
    } ?? (project.records ?? [])
    for record in records {
      guard let value = record.value,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continue  // empty slots stay absent in the file
      }
      // Never resurrect a key the catalog no longer carries.
      guard updated.strings[record.key] != nil else { continue }
      if record.language == sourceLanguage { continue }
      guard let fileState = fileState(for: record) else { continue }

      if let category = record.category {
        // Plural form record: write the form, never the flat unit.
        let current = updated.pluralValue(for: record.key, language: record.language, category: category)
        let currentState = updated.pluralState(for: record.key, language: record.language, category: category)
        if current == value && currentState == fileState {
          continue  // file already carries this form
        }
        let owned = record.provider != nil || record.edits?.isEmpty == false
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
      let owned = record.provider != nil || record.edits?.isEmpty == false
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
