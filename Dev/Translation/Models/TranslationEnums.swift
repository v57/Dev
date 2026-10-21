//
//  TranslationEnums.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

// MARK: - Provider

/// Which producer wrote a translation value. `manual` is a human; the rest
/// are the machine backends plus the imported translation DB. Persisted as
/// raw values — do not rename.
nonisolated enum Provider: String, Codable, CaseIterable, Sendable {
  case manual
  /// Retired: Apple Translation. Kept so historical records still decode.
  case apple
  /// Retired: local Ollama (translategemma). Kept so historical records
  /// still decode.
  case ollama
  /// The machine backend: whichever model the user configured in Settings
  /// (historically deepseek-v4-flash, then Muse). Raw value stays `deepseek`
  /// for record compatibility.
  case deepseek
  /// A value copied from the app's imported translation database (shipped
  /// human translations). Records carrying it are `.reviewed` with
  /// `autoReviewed` set until a human confirms them.
  case importedDB
}

// MARK: - TranslationState

/// App-wide translation state. `empty` = no value yet; `needs_review` =
/// machine produced the value (never auto-promoted); `reviewed` = a human
/// confirmed it. Persisted as raw values — do not rename.
nonisolated enum TranslationState: String, Codable, CaseIterable, Sendable {
  case empty
  case needs_review
  case reviewed
}

// MARK: - ContextScope

/// Scope of a ContextDoc: one global document, one per project, one per
/// language. Persisted as raw values — do not rename.
nonisolated enum ContextScope: String, Codable, CaseIterable, Sendable {
  case global
  case project
  case language
}

// MARK: - Editor

/// Who made a TranslationEdit. Machine edits carry their rationale in
/// `reason`; the producing backend lives on the record/TM provider at the
/// time of the edit. Persisted as raw values — do not rename.
nonisolated enum Editor: String, Codable, CaseIterable, Sendable {
  case human
  case provider
}
