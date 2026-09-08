//
//  AppleTranslator.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import Translation

// MARK: - AppleTranslator

/// Apple's on-device translation (Translation framework, macOS 26+ session
/// API — deployment target is 27.0, so no availability guards are needed).
///
/// Eligibility mirrors `LanguageAvailability.status(from:to:)`: `.unsupported`
/// pairs report not eligible; `.installed` / `.supported` pairs translate
/// (the OS manages language packs, downloading on demand when permitted).
/// Context is deliberately ignored — Apple's engine has no prompt channel,
/// and every other card in the pipeline must treat Apple output as a plain
/// suggestion anyway.
nonisolated struct AppleTranslator: TranslatorBackend {
  var id: BackendID { .apple }
  var displayName: String { id.displayName }

  func isEligible(from: String, to: String) async -> Bool {
    let availability = LanguageAvailability()
    let status = await availability.status(
      from: Locale.Language(identifier: from),
      to: Locale.Language(identifier: to)
    )
    return status != .unsupported
  }

  func translate(
    _ text: String,
    from: String,
    to: String,
    context: TranslationContext?
  ) async throws -> String {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return text
    }
    let session = TranslationSession(
      installedSource: Locale.Language(identifier: from),
      target: Locale.Language(identifier: to)
    )
    do {
      let response = try await session.translate(text)
      return response.targetText
    } catch {
      throw BackendError.apple(error.localizedDescription)
    }
  }
}
