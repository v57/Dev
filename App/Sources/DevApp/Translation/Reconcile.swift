//
//  Reconcile.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

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
/// `nonisolated`: the load's passes (the difference and shape scans, the mirror) are pure
/// functions over a snapshot of the project's records, so the open/reload path runs them off
/// the main thread and hands the result to `TranslationData` in one step. The per-key paths
/// (an edit, a review, a note) are `@MainActor` and write through `TranslationData` directly.
nonisolated enum Reconcile {
  // MARK: - state mapping

  /// A stamp of three nils is stored as the sentinel `global: 0` ("no doc existed at the
  /// time"): staleness math treats it exactly like nil ((v ?? -1) < doc version, and 0 < 1 is
  /// always true once a doc exists). The rule dates from the SwiftData store, which crashed
  /// re-faulting an all-nil row; it is kept so the stamps the app reads stay the ones it wrote.
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

  /// What the file's own unit says about one slot: the value it carries (`nil` when the file
  /// leaves it absent or blank, because absence IS the empty state), the state it claims mapped to
  /// the DB's vocabulary, and the state the file itself printed (the reviewed question is asked in
  /// the FILE's words — see `isReviewed(fileState:)`). The ONE reading of a unit: the mirror's
  /// slot upserts, the difference scan and the shape scan all go through it, so no two of them can
  /// disagree about what the file said.
  private static func unitValue(
    _ unit: StringCatalog.StringUnit?
  ) -> (value: String?, state: TranslationState?, fileState: String?) {
    let raw = unit?.value ?? ""
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return (
      trimmed.isEmpty ? nil : raw,
      unit.map { seedState(fileState: $0.state) },
      unit?.state
    )
  }

  /// The file's unit for one FLAT (key, language).
  private static func fileUnit(
    _ catalog: StringCatalog, key: String, language: String
  ) -> (value: String?, state: TranslationState?, fileState: String?) {
    unitValue(catalog.strings[key]?.localizations?[language]?.stringUnit)
  }

  /// The file's unit for one PLURAL form of a (key, language).
  private static func fileForm(
    _ catalog: StringCatalog, key: String, language: String, category: String
  ) -> (value: String?, state: TranslationState?, fileState: String?) {
    let plural = catalog.strings[key]?.localizations?[language]?.variations?["plural"]
    return unitValue(plural?[category]?.stringUnit)
  }

  /// True when the app has worked on this record: a provider produced its value or an edit
  /// was journaled for it (a human's typing, a machine fill, a TM copy). The mirror's
  /// ownership test, in one place.
  static func isOwned(_ record: TranslationRecord) -> Bool {
    record.provider != nil || record.hasEdits
  }

  /// True when the RECORD holds a value a PERSON vouched for.
  ///
  /// `.reviewed` alone is not enough: an imported-database copy is `.reviewed` with the auto
  /// marker set (`autoReviewed`) precisely because nobody confirmed it — that is what the "auto"
  /// badge says and why the file carries it as `needs_review`. Reviewed means `.reviewed` with
  /// that marker CLEAR, i.e. a human confirmed this value, and it is the only state worth stopping
  /// a load for: machine output and imported text are both things a run is free to replace.
  static func isReviewed(_ record: TranslationRecord) -> Bool {
    record.state == .reviewed && !record.autoReviewed
  }

  /// `isReviewed` for a slot that may hold no record at all.
  static func isReviewed(_ record: TranslationRecord?) -> Bool {
    guard let record else { return false }
    return isReviewed(record)
  }

  /// True when the FILE claims the value was reviewed — its own word for it is `translated`
  /// (Xcode writes it when a person confirms a translation; `needs_review`, `new`, `stale` and a
  /// missing state are all unreviewed). The same rule the mirror uses to seed a record's state,
  /// asked from the other side.
  static func isReviewed(fileState: String?) -> Bool {
    fileState == "translated"
  }

  // MARK: - project

  /// The project whose catalog lives at `catalogURL`, or nil.
  @MainActor static func existingProject(catalogURL: URL) -> Project? {
    TranslationData.shared.projects.first { $0.catalogURL == catalogURL }
  }

  /// Finds the project for a catalog URL, creating it on first sight. The
  /// name is the catalog's home directory (the merged catalog lives at the
  /// repo root, so this is the repo name) — stable per URL.
  @MainActor static func ensureProject(catalogURL: URL) -> Project {
    if let existing = existingProject(catalogURL: catalogURL) {
      return existing
    }
    let home = catalogURL.deletingLastPathComponent().lastPathComponent
    let name = home.isEmpty ? catalogURL.lastPathComponent : home
    return TranslationData.shared.insertProject(name: name, catalogURL: catalogURL)
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
  /// to a directory-root project).
  @MainActor static func resolveDirectoryProject(
    rootDir: URL,
    catalogURL discoveredCatalog: URL? = nil
  ) -> Project {
    let root = rootDir.standardizedFileURL
    let catalogURL = discoveredCatalog?.standardizedFileURL
      ?? root.appendingPathComponent(CatalogDiscovery.canonicalName)
    let iconURL = root
      .appendingPathComponent("Assets.xcassets", isDirectory: true)
      .appendingPathComponent("AppIcon.appiconset", isDirectory: true)
    let data = TranslationData.shared
    let projects = data.projects
    if let byRoot = projects.first(where: { $0.rootURL == root }) {
      return byRoot
    }
    if var byCatalog = projects.first(where: { $0.catalogURL == catalogURL }) {
      byCatalog.rootURL = root
      byCatalog.iconURL = iconURL
      data.update(byCatalog)
      return byCatalog
    }
    return data.insertProject(
      name: root.lastPathComponent, catalogURL: catalogURL, rootURL: root, iconURL: iconURL)
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
    /// Records dropped because the slot's SHAPE was settled the other way (see `ShapeConflict`):
    /// the losing shape's value-carrying, unreviewed rows.
    var dropped = 0

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
    /// True when the FILE's value is the one a person confirmed (state `translated`).
    let fileIsReviewed: Bool
    /// True when the RECORD's value is the one a person confirmed (`isReviewed`).
    let recordIsReviewed: Bool

    /// The slot as the prompt names it: `key (language)` or `key (language, one)`.
    var label: String {
      guard let category else { return "\(key) (\(language))" }
      return "\(key) (\(language), \(category))"
    }

    /// Which side a person vouched for, as the prompt says it.
    var reviewedSide: String {
      switch (fileIsReviewed, recordIsReviewed) {
      case (true, true): return "both"
      case (true, false): return "the file"
      default: return "the app"
      }
    }
  }

  /// The shape one side of a slot has: a single value, or one value per CLDR plural form.
  enum SlotShape: Sendable, Equatable {
    case flat
    case plural
  }

  /// One (key, language) the FILE and the app's records disagree about the SHAPE of — one side
  /// plural, the other flat — with a REVIEWED value on one of them.
  ///
  /// A shape is not a value: the same translation can be stored flat or split over CLDR forms, and
  /// which of the two a slot has decides what a run may write into it and what the merge can carry
  /// back to the file (a flat record is never written into a plural slot, and vice versa). When the
  /// two sides disagree, the value the REVIEWED side holds is the one a person stands behind, so
  /// its shape is the one worth keeping — `reviewedShape` is that, and the load converts the other
  /// side to it (see `mirrorOffMainActor`'s shape pass and `LocalizationStore`'s file-side
  /// conversion). Both sides reviewed is NOT a conflict: nothing here may overrule a person.
  struct ShapeConflict: Sendable, Equatable {
    let key: String
    let language: String
    /// The shape the slot should end up with (the reviewed side's).
    let reviewedShape: SlotShape
    /// What the file holds for it now.
    let fileShape: SlotShape
    /// What the project's records hold for it now.
    let recordShape: SlotShape
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
    _ catalog: StringCatalog, existing: ProjectRecords
  ) async -> DifferenceReport {
    await Task.detached(priority: .userInitiated) {
      differences(catalog, existing: existing)
    }.value
  }

  /// The scan itself, over records the caller hands in — pure, so a probe can ask it the
  /// same question the load asks.
  ///
  /// A slot counts when the file fills it, the record is DB-OWNED (`isOwned`) and fills it with
  /// something else, AND a person stands behind one of the two values (`isReviewed`) — the alert
  /// is about REVIEWED values only, so `needs_review` machine output, imported text and empty
  /// slots never raise it: those are the app's own working material and a run replaces them
  /// freely, which is exactly what the mirror's ordinary ownership rule already decides.
  ///
  /// Two slot shapes deliberately do NOT count either: a slot the file has nothing for (the app's
  /// own unsaved work — the design keeps it alive across a crash rather than asking about it on
  /// every open) and a slot only the file fills (an unowned mirror, which the file already wins).
  static func differences(
    _ catalog: StringCatalog,
    existing bySlot: ProjectRecords
  ) -> DifferenceReport {

    var count = 0
    var sample: [SlotDifference] = []
    func compare(
      _ key: String, _ language: String, _ category: String?,
      _ fileValue: String?, _ fileState: String?
    ) {
      guard let fileValue,
            let record = bySlot[SlotKey(key: key, language: language, category: category ?? "")],
            isOwned(record),
            let recordValue = record.value,
            recordValue != fileValue
      else { return }
      let fileIsReviewed = isReviewed(fileState: fileState)
      let recordIsReviewed = isReviewed(record)
      // Neither side reviewed: not a question. See the rule above.
      guard fileIsReviewed || recordIsReviewed else { return }
      count += 1
      if sample.count < DifferenceReport.sampleLimit {
        sample.append(SlotDifference(
          key: key, language: language, category: category,
          fileValue: fileValue, recordValue: recordValue,
          fileIsReviewed: fileIsReviewed, recordIsReviewed: recordIsReviewed))
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
            let form = fileForm(catalog, key: key, language: language, category: category)
            compare(key, language, category, form.value, form.fileState)
          }
          continue
        }
        let unit = fileUnit(catalog, key: key, language: language)
        compare(key, language, nil, unit.value, unit.fileState)
      }
    }
    return DifferenceReport(count: count, sample: sample)
  }

  /// The SHAPE scan: every (key, language) where the file and the app's records disagree about the
  /// shape of the slot — one plural, one flat — while a person stands behind one of them.
  ///
  /// Same gating as the value scan, for the same reason: a shape is only worth changing on the
  /// authority of a reviewed value. Where the reviewed value is plural, the slot should be plural;
  /// where it is flat, flat. Both sides reviewed is NOT a conflict (nothing here may overrule a
  /// person), and a side with no value at all is not a shape (an empty form skeleton is the plural
  /// machinery's, not a translation).
  static func detectShapeConflicts(
    _ catalog: StringCatalog, existing: ProjectRecords
  ) async -> [ShapeConflict] {
    await Task.detached(priority: .userInitiated) {
      shapeConflicts(catalog, existing: existing)
    }.value
  }

  /// The scan itself, over records the caller hands in — pure, like `differences`.
  ///
  /// The shape a slot has is read from what each side HOLDS, not from what it could hold: the file
  /// is plural when its plural variation carries forms, the records are plural when they carry form
  /// records at all (the empty ones included — a form skeleton is the app saying this slot is a
  /// plural one, which is the app's own plural workflow's doing).
  static func shapeConflicts(
    _ catalog: StringCatalog,
    existing bySlot: ProjectRecords
  ) -> [ShapeConflict] {

    func hasValue(_ record: TranslationRecord?) -> Bool {
      record?.value?.isBlankOrEmpty == false
    }

    var conflicts: [ShapeConflict] = []
    let sourceLanguage = catalog.sourceLanguage
    let languages = catalog.languages
    for (key, entry) in catalog.strings {
      if entry.shouldTranslate == false { continue }
      for language in languages where language != sourceLanguage {
        let variations = entry.localizations?[language]?.variations ?? [:]
        if !variations.isEmpty, variations["plural"] == nil { continue }  // device-only
        let fileShape: SlotShape = (variations["plural"]?.isEmpty ?? true) ? .flat : .plural

        let flat = bySlot[SlotKey(key: key, language: language, category: "")]
        let forms = PluralRules.categories(for: language).compactMap {
          bySlot[SlotKey(key: key, language: language, category: $0)]
        }
        guard flat != nil || !forms.isEmpty else { continue }  // the store knows nothing: no shape

        // Who may settle it: a reviewed value on one side, and only one.
        let flatReviewed = isReviewed(flat) && hasValue(flat)
        let reviewedForms = forms.filter { isReviewed($0) && hasValue($0) }
        // BOTH reviewed: a person's flat value and a person's per-form values. Nothing here may
        // overrule either, so the slot is left exactly as it is — no conversion, and the value scan
        // will not ask about a flat value against a form either.
        if flatReviewed, !reviewedForms.isEmpty { continue }

        let reviewedShape: SlotShape
        if flatReviewed {
          reviewedShape = .flat
        } else if !reviewedForms.isEmpty {
          reviewedShape = .plural
        } else {
          // No reviewed record, so the file's own claim is the only authority there is — and
          // without it there is nothing to convert on.
          guard isReviewed(fileState: fileOrFormState(
            catalog, key: key, language: language, isPlural: fileShape == .plural))
          else { continue }
          reviewedShape = fileShape
        }
        // The conflict is the FILE's shape against the shape the reviewed value says the slot
        // should have — not against the records' own shape, which is often the file's shape plus a
        // stale row from an earlier era (a flat value a person typed while the file was flat, a
        // form skeleton the plural workflow made). Those are exactly the rows this pass is here
        // to settle.
        guard fileShape != reviewedShape else { continue }
        // What the records hold, as a shape — the reviewed value's when there is one.
        let recordShape: SlotShape = flatReviewed
          ? .flat
          : (!reviewedForms.isEmpty ? .plural : (forms.isEmpty ? .flat : .plural))
        conflicts.append(ShapeConflict(
          key: key, language: language, reviewedShape: reviewedShape,
          fileShape: fileShape, recordShape: recordShape))
      }
    }
    return conflicts
  }

  /// The file's own state for a slot, plural or flat — the reviewed question asked of the artifact.
  private static func fileOrFormState(
    _ catalog: StringCatalog, key: String, language: String, isPlural: Bool
  ) -> String? {
    guard isPlural else { return fileUnit(catalog, key: key, language: language).fileState }
    let states = PluralRules.categories(for: language).compactMap {
      fileForm(catalog, key: key, language: language, category: $0).fileState
    }
    return states.first { isReviewed(fileState: $0) } ?? states.first
  }

  // MARK: - the mirror (file -> records), off the main thread

  /// What one mirror pass decided: the record set it leaves the project with, and the exact
  /// difference from the set it started from — what `TranslationData` persists.
  struct MirrorPlan: Sendable {
    var records: ProjectRecords
    var upserts: [SlotKey: TranslationRecord] = [:]
    var deletions: Set<SlotKey> = []
    var edits: [TranslationEdit] = []
    var stats = UpsertStats()

    init(records: ProjectRecords) {
      self.records = records
    }

    mutating func put(_ record: TranslationRecord) {
      let slot = record.slotKey
      records[slot] = record
      upserts[slot] = record
      deletions.remove(slot)
    }

    mutating func remove(_ slot: SlotKey) {
      records[slot] = nil
      upserts[slot] = nil
      deletions.insert(slot)
    }

    var isEmpty: Bool { upserts.isEmpty && deletions.isEmpty && edits.isEmpty }
  }

  /// Mirrors the parsed catalog into a project's records — PURE: it reads `existing` and returns
  /// the records it would leave behind (`MirrorPlan`), so the open/reload path runs it off the
  /// main thread over a snapshot and `apply` hands the result to the store.
  ///
  /// Every (translatable key, non-source language) pair the catalog knows gets a record. Pairs the
  /// file carries no unit for become `.empty` records (Stage 1 fills those). Plural forms get one
  /// record per (key, language, category) — each form is a full translation slot the pipeline
  /// fills like a flat row. A variation holder with NO plural (device-only) gets no record — a
  /// device-varied key cannot carry a flat stringUnit, and the UI marks such cells read-only.
  ///
  /// `policy` decides what a slot the file and an owned record disagree about does
  /// (`DifferencePolicy`): the load's answer. `.appWins` is the default because it is what every
  /// non-load caller wants — the per-key mutations (a scan merge, a plural vary) mirror a catalog
  /// whose values the app itself just wrote, so there is nothing for a user to decide.
  ///
  /// `shapeConflicts` are the load's shape pass (`shapeConflicts`): the FILE side was converted by
  /// the load already, so what is left here is the records — the LOSING shape's rows go. Only the
  /// ones that carry a value and have nobody behind them: an empty form skeleton is the plural
  /// machinery's own, and a reviewed record is a person's, which nothing in a load may overrule.
  ///
  /// `keys` scopes the walk to the keys a per-key mutation touched; the language set stays the
  /// WHOLE catalog's, so a scoped pass seeds exactly what a whole one would for them.
  static func mirror(
    _ catalog: StringCatalog,
    projectID: Int64,
    existing: ProjectRecords,
    policy: DifferencePolicy = .appWins,
    shapeConflicts: [ShapeConflict] = [],
    keys: Set<String>? = nil
  ) -> MirrorPlan {
    var plan = MirrorPlan(records: existing)
    let sourceLanguage = catalog.sourceLanguage
    // `catalog.languages` is COMPUTED: it walks every entry of the catalog and sorts the result,
    // so it is hoisted out of the key loop.
    let languages = catalog.languages
    let now = Date()
    let scope: [(key: String, entry: StringCatalog.Entry)] = keys.map { wanted in
      wanted.compactMap { key in catalog.strings[key].map { (key, $0) } }
    } ?? catalog.strings.map { ($0.key, $0.value) }
    for (key, entry) in scope {
      // Non-translatable keys are hidden from the workflow entirely.
      if entry.shouldTranslate == false { continue }
      for language in languages where language != sourceLanguage {
        let variations = entry.localizations?[language]?.variations ?? [:]
        let deviceOnly = !variations.isEmpty && variations["plural"] == nil
        if deviceOnly { continue }
        if let plural = variations["plural"], !plural.isEmpty {
          // Plural slot: one record per CLDR category of the target language. The per-form
          // source text comes from the source language's matching form (fallback: source
          // "other", then key).
          for category in PluralRules.categories(for: language) {
            let form = fileForm(catalog, key: key, language: language, category: category)
            upsert(
              SlotKey(key: key, language: language, category: category), projectID: projectID,
              sourceText: catalog.sourcePluralDisplay(for: key, category: category),
              value: form.value, seedState: form.state, policy: policy, now: now, plan: &plan)
          }
          continue
        }
        let unit = fileUnit(catalog, key: key, language: language)
        upsert(
          SlotKey(key: key, language: language, category: ""), projectID: projectID,
          sourceText: catalog.sourceDisplay(for: key),
          value: unit.value, seedState: unit.state, policy: policy, now: now, plan: &plan)
      }
    }
    for conflict in shapeConflicts {
      for record in plan.records.records(key: conflict.key) where record.language == conflict.language {
        let isForm = record.category != nil
        let losingShape = conflict.reviewedShape == .flat ? isForm : !isForm
        guard losingShape, record.value?.isBlankOrEmpty == false, !isReviewed(record) else { continue }
        plan.remove(record.slotKey)
        plan.stats.dropped += 1
      }
    }
    return plan
  }

  /// Hands a mirror's result to the store. In one step when nothing wrote the project since the
  /// pass took its snapshot (`generation`); otherwise slot by slot, and only where the slot still
  /// holds what the pass started from — a slot the app wrote meanwhile (a run's write-back, an
  /// edit) keeps the newer writer's value.
  @MainActor static func apply(
    _ plan: MirrorPlan, projectID: Int64, base: ProjectRecords, generation: Int
  ) {
    let data = TranslationData.shared
    defer { data.append(plan.edits) }
    guard !plan.upserts.isEmpty || !plan.deletions.isEmpty else { return }
    if data.replaceRecords(
      project: projectID, generation: generation, with: plan.records,
      upserts: Array(plan.upserts.values), deletions: Array(plan.deletions)) {
      return
    }
    guard let current = data.records(project: projectID) else { return }
    var upserts: [TranslationRecord] = []
    for (slot, record) in plan.upserts where current[slot] == base[slot] {
      upserts.append(record)
    }
    data.upsert(upserts)
    data.delete(
      project: projectID, slots: plan.deletions.filter { current[$0] == base[$0] && current[$0] != nil })
  }

  /// The mirror of a few keys, on the main actor: the per-key mutations (a plural vary, a scan
  /// merge) touch a handful of rows, so they mirror and apply in place.
  @MainActor static func mirror(_ catalog: StringCatalog, project: Project, keys: Set<String>) {
    let data = TranslationData.shared
    guard let existing = data.records(project: project.id) else { return }
    let generation = data.generation(project: project.id)
    let plan = mirror(catalog, projectID: project.id, existing: existing, keys: keys)
    apply(plan, projectID: project.id, base: existing, generation: generation)
  }

  /// What the FILE says one slot should be — the target an unowned mirror
  /// must equal after a reconcile.
  ///
  /// Exists so the upsert can COMPARE before writing: a mirror that rewrote every unowned
  /// record on every open would rewrite the whole project (and bump `updatedAt` on rows
  /// nothing had touched) even when file and DB already agree.
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
    func apply(to record: inout TranslationRecord, now: Date) {
      record.value = value
      record.state = state
      record.provider = nil
      record.confidence = nil
      record.reviewedAt = nil
      record.contextVersions = persistableVersions(ContextVersions())
      record.sourceText = sourceText
      record.updatedAt = now
    }
  }

  /// One slot, flat or a plural form. Ownership rule on reload:
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
  private static func upsert(
    _ slot: SlotKey,
    projectID: Int64,
    sourceText: String,
    value: String?,
    seedState: TranslationState?,
    policy: DifferencePolicy,
    now: Date,
    plan: inout MirrorPlan
  ) {
    let fileSlot = FileSlot(
      value: value, state: value != nil ? (seedState ?? .needs_review) : .empty,
      sourceText: sourceText)
    if var record = plan.records[slot] {
      if isOwned(record) {
        resolveOwnedSlot(&record, fileSlot: fileSlot, policy: policy, now: now, plan: &plan)
      } else if fileSlot.matches(record) {
        plan.stats.kept += 1
      } else {
        fileSlot.apply(to: &record, now: now)
        plan.put(record)
        plan.stats.refreshed += 1
      }
      return
    }
    plan.put(TranslationRecord(
      key: slot.key, sourceText: sourceText, language: slot.language, value: value,
      provider: nil, state: fileSlot.state, contextVersions: persistableVersions(ContextVersions()),
      createdAt: now, updatedAt: now, projectID: projectID,
      category: slot.category.isEmpty ? nil : slot.category))
    plan.stats.created += 1
  }

  /// The DB-OWNED branch of one slot, flat or plural — one definition, so a plural form can
  /// never be resolved differently from the flat row beside it.
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
    _ record: inout TranslationRecord,
    fileSlot: FileSlot,
    policy: DifferencePolicy,
    now: Date,
    plan: inout MirrorPlan
  ) {
    // The source is the artifact's wherever it moved, whether or not the value is
    // contested: the file is where source text is authored.
    var moved = false
    if record.sourceText != fileSlot.sourceText {
      record.sourceText = fileSlot.sourceText
      moved = true
    }
    guard let fileValue = fileSlot.value,
          let recordValue = record.value,
          recordValue != fileValue
    else {
      if moved { plan.put(record) }
      plan.stats.kept += 1
      return
    }

    plan.stats.differing += 1
    if plan.stats.differenceSample.count < DifferenceReport.sampleLimit {
      plan.stats.differenceSample.append(SlotDifference(
        key: record.key, language: record.language, category: record.category,
        fileValue: fileValue, recordValue: recordValue,
        // The mapped state carries the same answer as the raw one: `translated` is the only file
        // state that seeds `.reviewed` (see `seedState(fileState:)`).
        fileIsReviewed: fileSlot.state == .reviewed,
        recordIsReviewed: isReviewed(record)))
    }
    if policy == .fileWins {
      adoptFile(fileSlot, into: &record, now: now, plan: &plan)
      plan.stats.refreshed += 1
    } else {
      if moved { plan.put(record) }
      plan.stats.kept += 1
    }
  }

  /// Adopts the file's slot over a DB-OWNED record: the value and mapped state, the
  /// source text, and the provenance reset that marks the record an unowned mirror
  /// again — PLUS an edit row for the value it replaced.
  ///
  /// The edit row is what keeps the app's own corpus honest: the value the record held
  /// was produced by a run or an import and the file's is a person's, so the
  /// before->after pair is exactly the correction Stage 0 learns from. `editor: .human` and
  /// `isUserConfirmed: true` say the truth about it: a person edited this catalog, and the app
  /// read it back. It also leaves the record DB-OWNED (it now has an edit), so the value the
  /// user just chose is what survives the reloads that follow.
  private static func adoptFile(
    _ fileSlot: FileSlot,
    into record: inout TranslationRecord,
    now: Date,
    plan: inout MirrorPlan
  ) {
    plan.edits.append(TranslationEdit(
      record: record,
      fromValue: record.value,
      toValue: fileSlot.value ?? "",
      editor: .human,
      reason: "Adopted from the catalog file on reload",
      contextVersions: persistableVersions(ContextVersions()),
      isUserConfirmed: true,
      createdAt: now))
    fileSlot.apply(to: &record, now: now)
    record.hasEdits = true
    plan.put(record)
  }

  // MARK: - adding a language

  /// What one "add a language" pass produced.
  struct LanguageAddOutcome: Sendable {
    /// Records created — one per translatable key, one per CLDR form for a
    /// plural-source key.
    let inserted: Int
    /// Keys in scope when the pass ran (0 = an empty catalog, nothing to
    /// seed).
    let keyCount: Int
  }

  /// The records freshly added `languages` need — PURE, so a big catalog's seeding (thousands of
  /// records) runs off the main thread.
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
  static func seedLanguages(
    _ languages: [String],
    catalog: StringCatalog,
    projectID: Int64,
    existing: ProjectRecords
  ) -> (records: [TranslationRecord], outcome: LanguageAddOutcome) {
    var created: [TranslationRecord] = []
    var keyCount = 0
    let now = Date()
    for (key, entry) in catalog.strings {
      // Non-translatable keys are hidden from the workflow entirely.
      guard entry.shouldTranslate != false else { continue }
      keyCount += 1
      let pluralSource = catalog.hasPlurals(for: key, language: catalog.sourceLanguage)
      for language in languages {
        let categories = pluralSource ? PluralRules.categories(for: language) : [""]
        for category in categories {
          let slot = SlotKey(key: key, language: language, category: category)
          if existing[slot] != nil { continue }
          created.append(TranslationRecord(
            key: key,
            sourceText: category.isEmpty
              ? catalog.sourceDisplay(for: key)
              : catalog.sourcePluralDisplay(for: key, category: category),
            language: language, value: nil, provider: nil, state: .empty,
            contextVersions: persistableVersions(ContextVersions()),
            createdAt: now, updatedAt: now, projectID: projectID,
            category: category.isEmpty ? nil : category))
        }
      }
    }
    return (created, LanguageAddOutcome(inserted: created.count, keyCount: keyCount))
  }

  // MARK: - single record lookup

  /// The record for a (key, language) flat slot of a project, or nil.
  @MainActor static func record(
    key: String,
    language: String,
    in project: Project
  ) -> TranslationRecord? {
    record(key: key, language: language, category: nil, in: project)
  }

  /// The record for a (key, language, category) slot, or nil. Category nil =
  /// the flat slot.
  @MainActor static func record(
    key: String,
    language: String,
    category: String?,
    in project: Project
  ) -> TranslationRecord? {
    TranslationData.shared.record(
      project: project.id, slot: SlotKey(key: key, language: language, category: category))
  }

  /// ONE KEY's records of a project.
  @MainActor static func records(ofKey key: String, in project: Project) -> [TranslationRecord] {
    TranslationData.shared.records(project: project.id, key: key)
  }

  // MARK: - human edit (DB side)

  /// Applies a human-confirmed value to the record. A human typing a value
  /// IS a confirmation: state -> .reviewed, reviewedAt + lastEditor set.
  ///  - value changed -> provider .manual and a user-confirmed
  ///    TranslationEdit row (the Stage-0 learning corpus) is appended.
  ///  - value unchanged (pure confirmation of an existing machine value) ->
  ///    the producing provider is kept — provenance survives — and the
  ///    record is promoted to .reviewed without an edit row.
  /// Never touches the file.
  @discardableResult
  @MainActor static func applyHumanEdit(
    key: String,
    language: String,
    value: String,
    sourceText: String,
    project: Project,
    category: String? = nil
  ) -> TranslationRecord {
    let data = TranslationData.shared
    var record = self.record(key: key, language: language, category: category, in: project)
      ?? TranslationRecord(
        key: key, sourceText: sourceText, language: language,
        value: nil, provider: nil, state: .empty,
        contextVersions: persistableVersions(ContextVersions()),
        projectID: project.id, category: category)

    let valueChanged = record.value != value
    var edit: TranslationEdit?
    if valueChanged {
      edit = TranslationEdit(
        record: record,
        fromValue: record.value,
        toValue: value,
        editor: .human,
        contextVersions: persistableVersions(ContextVersions()),
        isUserConfirmed: true
      )
      record.value = value
      // The human authored this value; the machine is no longer the writer.
      record.provider = .manual
      record.confidence = nil
      record.hasEdits = true
    }
    record.sourceText = sourceText
    record.state = .reviewed
    record.autoReviewed = false  // any human action supersedes auto-reviewed
    record.reviewedAt = .now
    record.updatedAt = .now
    let userName = ProcessInfo.processInfo.fullUserName
    record.lastEditor = userName.isEmpty ? "Manual" : userName
    data.upsert(record)
    if let edit { data.append(edit) }
    return record
  }

  // MARK: - translation memory (gold)

  /// Promotes or creates the translation-memory entry for a value a human just
  /// confirmed. Entries are unique per (sourceText, sourceLanguage,
  /// targetLanguage): an existing machine hint is upgraded in place, and an
  /// existing gold entry with a different value is overwritten — the newer
  /// confirmation wins.
  @discardableResult
  @MainActor static func upsertGoldMemory(
    sourceText: String,
    sourceLanguage: String,
    targetLanguage: String,
    value: String,
    contextVersions: ContextVersions,
    projectTag: String?
  ) -> TranslationMemoryEntry {
    let data = TranslationData.shared
    var entry = data.memoryEntry(
      source: sourceText, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
      ?? TranslationMemoryEntry(
        sourceText: sourceText,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        value: value,
        contextVersions: contextVersions)
    entry.value = value
    entry.provider = .manual  // a human vouched for this value
    entry.state = .reviewed
    entry.projectTag = projectTag
    entry.contextVersions = contextVersions
    entry.confirmedAt = .now
    entry.confidence = nil
    data.upsert(entry)
    return entry
  }

  // MARK: - row review state (DB side)

  /// Marks a whole key's filled slots as `reviewed` (human-confirmed — keeps
  /// the producing provider and value, so provenance survives; records the
  /// confirming user) or `needs_review` (un-confirm: keeps provider, clears
  /// reviewedAt). Empty slots are left untouched — a reviewed empty slot has
  /// no value to confirm, and committing one would write a bogus
  /// "translated" unit into the file. Pure confirmation of an existing value
  /// appends NO TranslationEdit (that is the learning signal for a value
  /// *change*; here nothing changed). Never touches the file. Returns how many
  /// records changed.
  @discardableResult
  @MainActor static func applyReviewState(
    key: String,
    state: TranslationState,
    project: Project,
    language: String? = nil
  ) -> Int {
    let userName = ProcessInfo.processInfo.fullUserName
    var changed: [TranslationRecord] = []
    for var record in records(ofKey: key, in: project) where language == nil || record.language == language {
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
      changed.append(record)
    }
    TranslationData.shared.upsert(changed)
    return changed.count
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
  /// The project version is stamped on records for provenance; it
  /// deliberately does NOT auto-enqueue records.
  @discardableResult
  @MainActor static func applyNote(
    key: String,
    note: String,
    scope: NoteScope,
    project: Project
  ) -> Int {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    var records = Reconcile.records(ofKey: key, in: project)
    // The line folded by a previous save — retracted or replaced, if any.
    let previous = records.compactMap(\.noteFoldedText).first { !$0.isEmpty }
    // The line this note owns in the project doc: empty for a memo and for a
    // cleared note, so one path folds, replaces AND retracts — a note that turns
    // into a memo takes its rule out of the translator's context, the same rule
    // the redesign's `Workspace.setNote` follows. The doc is one rule per line, so
    // a multi-line note folds as ONE line; otherwise it could never be found
    // again to replace or retract.
    let rule = scope == .project ? ruleLine(trimmed) : ""

    if rule != (previous ?? "") {
      // A rule another key still owns stays in the doc: two notes can say the same
      // thing, and retracting one must not silently drop the other.
      let shared = previous.map { isFolded($0, byAnotherKeyThan: key, in: project) } ?? false
      foldProjectRule(line: rule, previous: shared ? nil : previous, key: key, project: project)
    }
    for index in records.indices {
      records[index].note = trimmed.isEmpty ? nil : trimmed
      records[index].noteScope = trimmed.isEmpty ? nil : scope.rawValue
      records[index].updatedAt = .now
      records[index].noteFoldedText = rule.isEmpty ? nil : rule
      records[index].noteFoldedAt = rule.isEmpty ? nil : .now
    }
    TranslationData.shared.upsert(records)
    return records.count
  }

  /// A note as the single line it folds into the project doc: every run of
  /// whitespace that contains a line break becomes one space.
  private static func ruleLine(_ note: String) -> String {
    note.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// True when some record of a key OTHER than `key` still carries `line` as its
  /// folded rule.
  @MainActor private static func isFolded(
    _ line: String, byAnotherKeyThan key: String, in project: Project
  ) -> Bool {
    guard let records = TranslationData.shared.records(project: project.id) else { return false }
    return records.values.contains { $0.key != key && $0.noteFoldedText == line }
  }

  /// The project's own context document (its project-scope ContextDoc), or nil.
  @MainActor static func projectDoc(of project: Project) -> ContextDoc? {
    let documents = TranslationData.shared.documents.filter { $0.scope == .project }
    return documents.first { $0.projectID == project.id }
      ?? documents.first { $0.projectID == nil && $0.identifier == project.name }
  }

  /// Applies ONE rule line to the project doc: replaces the previously folded
  /// line in place, appends a new one, or drops it when the note was cleared
  /// (a retraction). No-op when the doc already reads exactly like this, so a
  /// re-save never churns the version.
  @MainActor private static func foldProjectRule(
    line: String,
    previous: String?,
    key: String,
    project: Project
  ) {
    let old = (previous ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let doc = projectDoc(of: project)
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
    writeProjectDoc(revised, before: doc, project: project, reason: reason)
  }

  /// Writes the project doc's new body — a version bump on the existing document, or the
  /// document itself — with its audit row.
  @MainActor private static func writeProjectDoc(
    _ content: String, before doc: ContextDoc?, project: Project, reason: String
  ) {
    let data = TranslationData.shared
    if var doc {
      let before = doc.content
      doc.content = content
      doc.version += 1
      doc.updatedAt = .now
      data.update(doc)
      data.append(ContextEdit(docID: doc.id, before: before, after: content, reason: reason, author: .manual))
    } else {
      let created = data.insertDocument(
        scope: .project, identifier: project.name, content: content, projectID: project.id)
      data.append(ContextEdit(docID: created.id, before: nil, after: content, reason: reason, author: .manual))
    }
  }

  /// Replaces the project's context body wholesale — the human editor's save
  /// path (trim, audit, ONE version bump; no-op when the text is unchanged).
  /// This is also where a rule is retracted by hand.
  @discardableResult
  @MainActor static func applyProjectDoc(content: String, project: Project) -> Bool {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    let doc = projectDoc(of: project)
    guard trimmed != (doc?.content ?? "") else { return false }
    writeProjectDoc(
      trimmed, before: doc, project: project,
      reason: doc == nil ? "Project context created by hand" : "Project context edited by hand")
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
  @MainActor static func applyMaxWidth(key: String, width: Int?, project: Project) -> Int {
    var records = records(ofKey: key, in: project)
    for index in records.indices {
      records[index].maxWidth = width
      records[index].updatedAt = .now
    }
    TranslationData.shared.upsert(records)
    return records.count
  }

  // MARK: - merge (DB -> in-memory catalog)

  /// True when a file-origin (unowned) record's STATE is no longer the one the
  /// file's own state seeds — i.e. something in the app moved it, which today
  /// is a row review (`applyReviewState`): confirming or un-confirming a value
  /// that came from the file changes the state and nothing else. That is an
  /// edit the artifact has to learn on Save; without this test the passive rule
  /// below kept the file's state, and the next reload re-mirrored it over the
  /// review. A record that still carries the file's seed (Xcode's raw `new`
  /// reads as `needs_review`) is left alone, so the raw state is not rewritten.
  private static func appMovedState(_ record: TranslationRecord, fileState: String?) -> Bool {
    seedState(fileState: fileState) != record.state
  }

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
  @MainActor static func merge(
    _ catalog: StringCatalog,
    project: Project,
    keys: Set<String>? = nil
  ) -> (catalog: StringCatalog, changed: Bool) {
    let data = TranslationData.shared
    let records = keys.map { wanted in
      wanted.flatMap { data.records(project: project.id, key: $0) }
    } ?? data.records(project: project.id).map { Array($0.values) } ?? []
    return merge(catalog, records: records)
  }

  /// The merge itself, over the records the caller hands in — pure, so a whole project's merge
  /// can run off the main thread.
  static func merge(
    _ catalog: StringCatalog,
    records: [TranslationRecord]
  ) -> (catalog: StringCatalog, changed: Bool) {
    var updated = catalog
    var changed = false
    let sourceLanguage = catalog.sourceLanguage
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
        // Plural form record: write the form, never the flat unit — and never into a flat
        // slot a person confirmed (`holdsReviewedFlat`).
        if updated.holdsReviewedFlat(key: record.key, language: record.language) {
          continue
        }
        let current = updated.pluralValue(for: record.key, language: record.language, category: category)
        let currentState = updated.pluralState(for: record.key, language: record.language, category: category)
        if current == value && currentState == fileState {
          continue  // file already carries this form
        }
        // A file-origin seed is passive — the artifact wins — unless the app moved
        // its STATE (a row review): see `appMovedState`.
        if !isOwned(record), current == nil
          || (current == value && !appMovedState(record, fileState: currentState)) {
          continue
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
      if !isOwned(record), current == nil
        || (valueMatches && !appMovedState(record, fileState: current?.state)) {
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
