//
//  ProvenanceDisplay.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

// MARK: - Provenance markers

/// Stable marker strings a run writes into `TranslationRecord.lastEditor`,
/// mirrored here so the UI checks survive in one place. The literals MUST
/// match what the writers stamp (`Translation.Runner.memoryEditor` writes
/// "Translation Memory") — do not rename one side only.
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
  /// model id in `lastEditor` (the model chosen in Settings); this is
  /// the fallback for records without an editor stamp. Apple/Ollama are
  /// retired producers kept only so historical records still render.
  var displayName: String {
    switch self {
    case .manual: return String(localized: "Human")
    case .apple: return "Apple Translation"
    case .ollama: return "Ollama"
    case .deepseek: return String(localized: "AI model")
    case .importedDB: return String(localized: "Imported DB")
    }
  }
}

// MARK: - TranslationState

extension TranslationState {
  /// Short state title for dots and tooltips.
  var displayName: String {
    switch self {
    case .empty: return String(localized: "Empty")
    case .needs_review: return String(localized: "Needs review")
    case .reviewed: return String(localized: "Reviewed")
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
      global.map { String(localized: "global \($0)") },
      project.map { String(localized: "project \($0)") },
      language.map { String(localized: "language \($0)") },
    ].compactMap { $0 }
    guard !parts.isEmpty else { return nil }
    if parts.count == 1, global == 0 {
      return nil
    }
    return String(localized: "Context versions — \(parts.joined(separator: ", "))")
  }
}

// MARK: - TranslationRecord

extension TranslationRecord {
  /// Multi-line provenance for a cell tooltip: who produced the current
  /// value (backend / human / translation memory / imported DB), against
  /// which context versions, and the confirmation state. Nil while the slot
  /// has no value — an empty cell's help stays the plain "Missing" prompt.
  var provenanceSummary: String? {
    guard let value, !value.isBlankOrEmpty else { return nil }

    let producer: String
    if autoReviewed {
      // Imported-DB copy: lastEditor is "Imported DB — <owning app>".
      let prefix = ProvenanceMarkers.importedDB + " — "
      let app = lastEditor.flatMap {
        $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil
      }
      producer = String(localized: "Imported translation DB — \(app ?? "source")")
    } else if lastEditor == ProvenanceMarkers.translationMemory {
      producer = state == .reviewed
        ? String(localized: "Translation memory — human-confirmed copy (gold)")
        : String(localized: "Translation memory — machine hint")
    } else if let editor = lastEditor, !editor.isEmpty {
      producer = provider == .manual ? String(localized: "Human edit — \(editor)") : editor
    } else if let provider {
      producer = provider.displayName
    } else {
      producer = String(localized: "Imported from catalog")
    }

    var lines = [producer]
    if let versions = contextVersions.provenanceText {
      lines.append(versions)
    }
    switch state {
    case .empty:
      break
    case .needs_review:
      lines.append(String(localized: "Machine output — needs review"))
    case .reviewed:
      lines.append(autoReviewed
        ? String(localized: "Automatically reviewed — click the auto badge to confirm")
        : String(localized: "Reviewed"))
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - String

/// `nonisolated`: a pure predicate, callable from off-main store work too.
nonisolated extension String {
  var isBlankOrEmpty: Bool {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
