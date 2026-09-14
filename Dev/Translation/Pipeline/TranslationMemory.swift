//
//  TranslationMemory.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import SwiftData

// MARK: - TranslationMemory

/// Translation-memory store operations + the resolve step of a Translate run.
///
/// Entries are unique over (sourceText, sourceLanguage, targetLanguage), so
/// there is at most ONE entry per triple: its `state` decides how a hit is
/// applied:
///  - .reviewed  -> gold (a human confirmed it). Copies as .reviewed into any
///    future catalog — gold is gold, cross-project. Never overwritten by
///    machine stages.
///  - .needs_review -> machine-only hint. Copies as .needs_review.
///
/// Write discipline: the Stage-0 learner upserts the REVIEWED entry only
/// AFTER the context-doc fold succeeded, so a reviewed entry for a triple is
/// also the marker that the fold ran (runs stay idempotent without extra
/// model fields). Machine stages upsert .needs_review hints from their
/// output; a later human confirmation promotes the same triple to .reviewed.
enum TranslationMemory {
  /// One entry per (sourceText, sourceLanguage, targetLanguage) triple.
  static func entry(
    in context: ModelContext,
    sourceText: String,
    sourceLanguage: String,
    targetLanguage: String
  ) -> TranslationMemoryEntry? {
    let predicate = #Predicate<TranslationMemoryEntry> {
      $0.sourceText == sourceText
        && $0.sourceLanguage == sourceLanguage
        && $0.targetLanguage == targetLanguage
    }
    let descriptor = FetchDescriptor<TranslationMemoryEntry>(predicate: predicate)
    return try? context.fetch(descriptor).first
  }

  // MARK: - upserts

  /// Promotes/creates the entry for a user-confirmed translation (Stage 0).
  /// `state` becomes .reviewed with a confirmation timestamp; an existing
  /// machine-only hint is upgraded in place, an existing reviewed entry with
  /// a different value is OVERWRITTEN (the human just re-confirmed a newer
  /// value — the newer confirmation wins).
  @discardableResult
  static func upsertReviewed(
    in context: ModelContext,
    sourceText: String,
    sourceLanguage: String,
    targetLanguage: String,
    value: String,
    contextVersions: ContextVersions,
    projectTag: String?
  ) -> TranslationMemoryEntry {
    let existing = entry(
      in: context,
      sourceText: sourceText,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage
    )
    let entry: TranslationMemoryEntry
    if let existing {
      entry = existing
    } else {
      entry = TranslationMemoryEntry(
        sourceText: sourceText,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        value: value,
        // Set at init, not via the model's all-nil ContextVersions() default:
        // the caller's value is already persistable-guarded (snapshot routes
        // through Reconcile.persistableVersions), so the inserted row never
        // holds an all-nil ContextVersions even transiently.
        contextVersions: contextVersions
      )
      context.insert(entry)
    }
    entry.value = value
    entry.provider = .manual  // a human vouched for this value
    entry.state = .reviewed
    entry.projectTag = projectTag
    entry.contextVersions = contextVersions
    entry.confirmedAt = .now
    entry.confidence = nil
    return entry
  }

  /// Records a machine translation as a .needs_review hint. Never touches a
  /// .reviewed entry — gold is gold and machine output must not clobber it
  /// (the resolve stage copies gold BEFORE machine stages run, so a machine
  /// stage should never even see such a record).
  static func upsertMachineHint(
    in context: ModelContext,
    sourceText: String,
    sourceLanguage: String,
    targetLanguage: String,
    value: String,
    provider: Provider,
    contextVersions: ContextVersions,
    projectTag: String?
  ) {
    guard let existing = entry(
      in: context,
      sourceText: sourceText,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage
    ) else {
      let entry = TranslationMemoryEntry(
        sourceText: sourceText,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        value: value,
        provider: provider,
        state: .needs_review,
        projectTag: projectTag,
        contextVersions: contextVersions
      )
      context.insert(entry)
      return
    }
    guard existing.state != .reviewed else { return }
    existing.value = value
    existing.provider = provider
    existing.state = .needs_review
    existing.projectTag = projectTag
    existing.contextVersions = contextVersions
    existing.confirmedAt = nil
  }

  // MARK: - resolve

  /// Outcome of one TM-resolve attempt.
  enum ResolveOutcome {
    /// No exact (sourceText, targetLanguage) hit.
    case none
    /// Reviewed entry copied; record is now .reviewed and skips the pipeline.
    case resolvedGold
    /// Machine-only hint copied; record is .needs_review and skips the
    /// pipeline THIS run (a later context bump re-exposes it to stages).
    case resolvedHint
  }

  /// Applies an exact (sourceText, sourceLanguage, targetLanguage) hit to a
  /// record that needs a target value. The hit's value, provider, state and
  /// context-versions snapshot are copied verbatim — the record inherits the
  /// memory's provenance, and the write is audited as a TranslationEdit.
  ///
  /// Resolve only when the hit ADDS something:
  ///  - empty record  -> any hit (gold or machine hint) fills the slot,
  ///  - record already has a value -> only a REVIEWED (gold) hit is useful:
  ///    it upgrades the value, or promotes an identical machine value to
  ///    .reviewed. A machine hint is never copied over an existing machine
  ///    value (the record's own value is the fresher derivation) — such a
  ///    record stays a normal pipeline candidate instead, so staleness flows
  ///    it into the machine stages.
  static func resolve(
    in context: ModelContext,
    env: PipelineRunContext,
    record: TranslationRecord,
    sourceLanguage: String
  ) -> ResolveOutcome {
    guard let hit = entry(
      in: context,
      sourceText: record.sourceText,
      sourceLanguage: sourceLanguage,
      targetLanguage: record.language
    ) else {
      return .none
    }

    // A record that already carries a value gains nothing from a machine
    // hint; only gold may upgrade/promote it.
    if record.value != nil {
      guard hit.state == .reviewed, record.state == .needs_review, record.provider != .manual else {
        return .none
      }
    } else {
      guard hit.state != .empty else { return .none }
    }

    let outcome: ResolveOutcome
    switch hit.state {
    case .reviewed:
      outcome = .resolvedGold
    case .needs_review:
      outcome = .resolvedHint
    case .empty:
      // An entry never carries an empty value (model invariant); treat a
      // corrupted row as no hit.
      return .none
    }

    let oldValue = record.value
    let isPromotion = record.value == hit.value && record.state == .needs_review
    record.value = hit.value
    record.provider = hit.provider
    if hit.state == .reviewed {
      record.state = .reviewed
      record.reviewedAt = .now
    } else {
      record.state = .needs_review
      record.reviewedAt = nil
    }
    record.contextVersions = hit.contextVersions
    record.updatedAt = .now
    record.lastEditor = "Translation Memory"
    record.confidence = hit.confidence
    // Audit the copy unless the record already carried exactly this value at
    // needs_review (a pure gold-promotion of identical machine output — the
    // value itself did not change, only its state did).
    if !isPromotion {
      let edit = TranslationEdit(
        record: record,
        fromValue: oldValue,
        toValue: hit.value,
        editor: .provider,
        reason: hit.state == .reviewed
          ? "Resolved from reviewed translation memory (gold)"
          : "Resolved from machine translation memory (hint)",
        contextVersions: hit.contextVersions,
        isUserConfirmed: false
      )
      record.edits = (record.edits ?? []) + [edit]
      context.insert(edit)
    }
    return outcome
  }
}
