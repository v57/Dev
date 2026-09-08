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
enum Reconcile {
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

  /// The project whose catalog lives at `catalogURL`, or nil.
  static func existingProject(
    catalogURL: URL,
    in context: ModelContext
  ) -> Project? {
    let descriptor = FetchDescriptor<Project>()
    guard let projects = try? context.fetch(descriptor) else { return nil }
    return projects.first { $0.catalogURL == catalogURL }
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

  // MARK: - load (file -> DB)

  /// Outcome counts of one upsert, for logging.
  struct UpsertStats {
    var created = 0
    var refreshed = 0  // unowned slot adopted the file's value/state
    var kept = 0       // DB-owned record untouched by the reload
  }

  /// Mirrors the parsed catalog into the project's TranslationRecords:
  /// every (translatable key, non-source language) pair the catalog knows.
  /// Pairs the file carries no unit for become `.empty` records (Stage 1
  /// fills those); variation holders get no record — a varied key cannot
  /// carry a flat stringUnit, and the UI marks such cells read-only.
  @discardableResult
  static func upsertFromCatalog(
    _ catalog: StringCatalog,
    project: Project,
    context: ModelContext
  ) -> UpsertStats {
    var stats = UpsertStats()

    // Existing records of this project, indexed for O(1) lookups.
    var bySlot: [String: [String: TranslationRecord]] = [:]
    for record in project.records {
      bySlot[record.key, default: [:]][record.language] = record
    }

    let sourceLanguage = catalog.sourceLanguage
    for (key, entry) in catalog.strings {
      // Non-translatable keys are hidden from the workflow entirely.
      if entry.shouldTranslate == false { continue }
      for language in catalog.languages where language != sourceLanguage {
        // A variation holder has no flat stringUnit; never fake one.
        if entry.localizations?[language]?.variations?.isEmpty == false {
          continue
        }
        let unit = entry.localizations?[language]?.stringUnit
        let rawValue = unit?.value ?? ""
        let value: String? = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? nil
          : rawValue
        upsertSlot(
          key: key, language: language,
          sourceText: catalog.sourceDisplay(for: key),
          value: value,
          seedState: unit.map { seedState(fileState: $0.state) },
          in: project, context: context, bySlot: &bySlot, stats: &stats)
      }
    }

    try? context.save()
    return stats
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
    in project: Project,
    context: ModelContext,
    bySlot: inout [String: [String: TranslationRecord]],
    stats: inout UpsertStats
  ) {
    if let record = bySlot[key]?[language] {
      let owned = record.provider != nil || !record.edits.isEmpty
      if owned {
        record.sourceText = sourceText
        stats.kept += 1
      } else if let value, let seedState {
        // File mirror adopts the file's current value + mapped state.
        record.value = value
        record.state = seedState
        record.provider = nil
        record.confidence = nil
        record.reviewedAt = nil
        record.contextVersions = persistableVersions(ContextVersions())
        record.sourceText = sourceText
        record.updatedAt = .now
        stats.refreshed += 1
      } else if record.value != nil || record.state != .empty {
        // File mirror whose unit vanished from the file: slot goes empty.
        record.value = nil
        record.provider = nil
        record.state = .empty
        record.confidence = nil
        record.reviewedAt = nil
        record.contextVersions = persistableVersions(ContextVersions())
        record.sourceText = sourceText
        record.updatedAt = .now
        stats.refreshed += 1
      } else {
        record.sourceText = sourceText
        stats.kept += 1
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
    record.project = project
    bySlot[key, default: [:]][language] = record
    stats.created += 1
  }

  // MARK: - single record lookup

  /// The record for a (key, language) slot of a project, or nil.
  static func record(
    key: String,
    language: String,
    in project: Project
  ) -> TranslationRecord? {
    project.records.first { $0.key == key && $0.language == language }
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
    context: ModelContext
  ) -> TranslationRecord {
    let record = record(key: key, language: language, in: project)
      ?? {
        let record = TranslationRecord(
          key: key, sourceText: sourceText, language: language,
          value: nil, provider: nil, state: .empty,
          contextVersions: persistableVersions(ContextVersions()))
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

  // MARK: - commit (DB -> file)

  /// Writes the working store back to the artifact: for every DB-OWNED
  /// record of the project that carries a value, set its (key, language)
  /// stringUnit value + state on a copy of the parsed catalog, then
  /// atomically rewrite the file at `project.catalogURL` — but ONLY when at
  /// least one unit actually changed, so a no-op commit never churns the
  /// artifact. DB-owned = the record carries provenance (provider or edit
  /// history): human edits, machine fills, TM copies. Pure file-origin seed
  /// rows (provider nil, no edits) are passive — their value already
  /// matches the file by construction, and their raw file state (Xcode may
  /// say "new") is left alone until a real owner writes the row. Variation
  /// holders and the source language are never touched. Returns the updated
  /// catalog (the caller adopts it so the UI stays in sync without a
  /// reload). Throws on encode/write failure.
  @discardableResult
  static func commit(
    _ catalog: StringCatalog,
    project: Project
  ) throws -> StringCatalog {
    var updated = catalog
    var changed = false
    let sourceLanguage = catalog.sourceLanguage

    for record in project.records {
      guard let value = record.value,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continue  // empty slots stay absent in the file
      }
      // Never resurrect a key the catalog no longer carries.
      guard var entry = updated.strings[record.key] else { continue }
      if record.language == sourceLanguage { continue }
      if entry.localizations?[record.language]?.variations?.isEmpty == false {
        continue  // variation holders are read-only in this phase
      }
      guard let fileState = fileState(for: record.state) else { continue }

      let current = entry.localizations?[record.language]?.stringUnit
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

      var localizations = entry.localizations ?? [:]
      var language = localizations[record.language] ?? StringCatalog.Language()
      language.stringUnit = StringCatalog.StringUnit(state: fileState, value: value)
      localizations[record.language] = language
      entry.localizations = localizations
      updated.strings[record.key] = entry
      changed = true
    }

    guard changed else { return updated }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(updated)
    try data.write(to: project.catalogURL, options: .atomic)
    return updated
  }
}
