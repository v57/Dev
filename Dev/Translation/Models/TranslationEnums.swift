//
//  TranslationEnums.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

// MARK: - Provider

/// Which producer wrote a translation value. `manual` is a human; the rest
/// are the machine backends. Persisted as raw values — do not rename.
enum Provider: String, Codable, CaseIterable {
  case manual
  case apple
  case ollama
  case deepseek
}

// MARK: - TranslationState

/// App-wide translation state. `empty` = no value yet; `needs_review` =
/// machine produced the value (never auto-promoted); `reviewed` = a human
/// confirmed it. Persisted as raw values — do not rename.
enum TranslationState: String, Codable, CaseIterable {
  case empty
  case needs_review
  case reviewed
}

// MARK: - ContextScope

/// Scope of a ContextDoc: one global document, one per project, one per
/// language. Persisted as raw values — do not rename.
enum ContextScope: String, Codable, CaseIterable {
  case global
  case project
  case language
}

// MARK: - Editor

/// Who made a TranslationEdit. Machine edits carry their rationale in
/// `reason`; the producing backend lives on the record/TM provider at the
/// time of the edit. Persisted as raw values — do not rename.
enum Editor: String, Codable, CaseIterable {
  case human
  case provider
}
