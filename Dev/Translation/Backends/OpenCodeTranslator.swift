//
//  OpenCodeTranslator.swift
//  Dev
//

import Foundation

// MARK: - OpenCodeTranslator

/// The OpenCode Go client for the destination model (Muse — the contributor
/// tier; see `RoutedModel.muse`), used for everything that must always run
/// on the strongest model:
///
///  - the router's chain (its only candidate today — `RoutedModel.chain`),
///  - the Stage-0 learn fold (`Stage0ModelClient`),
///  - plural source-form authoring (`PluralGenerator`).
///
/// The translation path itself goes through `TranslationRouter`. Wire format
/// is shared with every other provider via `OpenAIChatClient` — Muse speaks
/// the OpenAI **Responses** protocol on OpenCode Go (`POST
/// /zen/go/v1/responses`), which `wire: .responses` selects.
///
/// The API key comes from `OpenCodeKeychain` (login keychain →
/// OPENCODE_GO_API_KEY environment variable → ~/.hermes/.env). Without a key
/// the backend is not eligible, and `translate` throws
/// `BackendError.notConfigured` — it never crashes.
nonisolated struct OpenCodeTranslator: TranslatorBackend {
  /// Root for the OpenCode Go surface (`/zen/go/v1`).
  static let baseURL = RoutedModel.Provider.openCode.baseURL
  /// Muse's endpoint: the Responses API under the provider root.
  static let endpoint = RoutedModel.muse.endpoint
  /// The destination model. `RoutedModel.muse` names the same model for the
  /// router; keep the two in step.
  static let model = RoutedModel.muse.model
  /// Headers OpenCode Go asks every client to send — the client's own user
  /// agent plus the stable session id it routes and caches by.
  static let headers = RoutedModel.muse.headers
  /// Per-request budget; hosted frontier models can take a while on long strings.
  static let requestTimeout: TimeInterval = 180

  var id: BackendID { .opencode }
  var displayName: String { "OpenCode Go" }

  func isEligible(from: String, to: String) async -> Bool {
    OpenCodeKeychain.apiKey() != nil
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
    guard let apiKey = OpenCodeKeychain.apiKey() else {
      throw BackendError.notConfigured(
        "OpenCode Go is not configured: set \(OpenCodeKeychain.envName) in the login keychain, "
          + "the environment, or ~/.hermes/.env."
      )
    }
    let prompt = ContextPromptBuilder.assemble(
      sourceText: text,
      sourceLanguage: from,
      targetLanguage: to,
      context: context)
    let client = OpenAIChatClient(
      endpoint: Self.endpoint,
      wire: .responses,
      apiKey: apiKey,
      model: Self.model,
      headers: Self.headers,
      timeout: Self.requestTimeout)
    return try await client.complete(system: prompt.system, user: prompt.user).content
  }
}
