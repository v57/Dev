//
//  ProvenanceDisplay.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

// MARK: - Provenance markers

/// Stable marker strings the pipeline writes into `TranslationRecord.lastEditor`,
/// mirrored here so the UI checks survive in one place. The literals MUST
/// match what Dev/Translation/Pipeline writes (e.g. TranslationMemory.resolve
/// stamps "Translation Memory") — do not rename one side only.
enum ProvenanceMarkers {
  /// Set when a value was copied from the translation memory — the UI shows
  /// the "resolved from cache" indicator for these cells.
  static let translationMemory = "Translation Memory"
  /// PREFIX of the editor stamp the imported-DB stage writes ("Imported DB —
  /// <owning app>"). The `autoReviewed` record flag is the authoritative
  /// marker; this only names the producer in tooltips.
  static let importedDB = "Imported DB"
}

// MARK: - Provider

extension Provider {
  /// Human-readable producer name. Machine rows normally carry the real
  /// backend name in `lastEditor` (Apple Translation / Ollama / Command
  /// Code); this is the fallback for records without an editor stamp.
  var displayName: String {
    switch self {
    case .manual: return "Human"
    case .apple: return "Apple Translation"
    case .ollama: return "Ollama"
    case .deepseek: return "Command Code"
    case .importedDB: return "Imported DB"
    }
  }
}

// MARK: - TranslationState

extension TranslationState {
  /// Short state title for dots and tooltips.
  var displayName: String {
    switch self {
    case .empty: return "Empty"
    case .needs_review: return "Needs review"
    case .reviewed: return "Reviewed"
    }
  }
}

// MARK: - ContextVersions

extension ContextVersions {
  /// "Context versions — global 1, language 2" (scopes without a doc are
  /// omitted). Nil when nothing meaningful was recorded. `(global: 0)` is
  /// Reconcile's persisted sentinel for "no context doc existed when this
  /// was written" and is not worth showing.
  var provenanceText: String? {
    let parts = [
      global.map { "global \($0)" },
      project.map { "project \($0)" },
      language.map { "language \($0)" },
    ].compactMap { $0 }
    guard !parts.isEmpty else { return nil }
    if parts.count == 1, global == 0 {
      return nil
    }
    return "Context versions — " + parts.joined(separator: ", ")
  }
}

// MARK: - TranslationRecord

extension TranslationRecord {
  /// Multi-line provenance for a cell tooltip: who produced the current
  /// value (backend / human / translation memory), against which context
  /// versions, and the confirmation state. Nil while the slot has no value —
  /// an empty cell's help stays the plain "Missing" prompt.
  var provenanceSummary: String? {
    guard let value, !value.isBlankOrEmpty else { return nil }

    let producer: String
    if lastEditor == ProvenanceMarkers.translationMemory {
      producer = state == .reviewed
        ? "Translation memory — human-confirmed copy (gold)"
        : "Translation memory — machine hint"
    } else if let editor = lastEditor, !editor.isEmpty {
      producer = provider == .manual ? "Human edit — \(editor)" : editor
    } else if let provider {
      producer = provider.displayName
    } else {
      producer = "Imported from catalog"
    }

    var lines = [producer]
    if let versions = contextVersions.provenanceText {
      lines.append(versions)
    }
    switch state {
    case .empty:
      break
    case .needs_review:
      lines.append("Machine output — needs review")
    case .reviewed:
      lines.append("Reviewed")
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - String

/// `nonisolated`: a pure predicate, callable from the pipeline's off-main
/// stages too.
nonisolated extension String {
  var isBlankOrEmpty: Bool {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
