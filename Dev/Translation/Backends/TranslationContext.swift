//
//  TranslationContext.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

// MARK: - TranslationContext

/// Everything the pipeline knows about one string besides its text and the
/// language pair. Command Code folds it into the prompt via
/// `ContextPromptBuilder`.
///
/// The three context texts are the bodies of the versioned ContextDocs
/// (scope .global / .project / .language) — they are carried here because
/// `translate(_:from:to:context:)` is the only channel into a backend, and
/// the builder needs them to assemble a prompt. Keeping this type Foundation-
/// only (no SwiftData import) is what lets the builder stay probe-able with
/// a standalone `swiftc` compile.
nonisolated struct TranslationContext: Sendable {
  /// Localization key of the record, when the string comes from a catalog.
  var key: String? = nil
  /// Developer comment attached to the key (where the string appears, any
  /// length/register hints).
  var comment: String? = nil
  /// Sibling values already in the TARGET language — register and
  /// terminology samples for nearby keys.
  var neighbors: [String] = []
  /// ContextDoc(scope: .global).content, when one exists.
  var globalContext: String? = nil
  /// ContextDoc(scope: .project).content for the owning project, if any.
  var projectContext: String? = nil
  /// ContextDoc(scope: .language) content for the TARGET language, if any.
  var languageContext: String? = nil
  /// Plural form being translated ("one", "other", …); nil for a flat slot.
  /// Backends fold it into the prompt ("translate the ONE form") so the
  /// model produces the right agreement/number for this category.
  var pluralCategory: String? = nil
  /// All source-language forms (category -> text) as reference for a plural
  /// fill: the model sees every source form, not just the one being
  /// translated.
  var sourcePluralForms: [String: String] = [:]
}
