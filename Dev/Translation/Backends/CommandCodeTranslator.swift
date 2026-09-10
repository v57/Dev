//
//  CommandCodeTranslator.swift
//  Dev
//

import Foundation

// MARK: - CommandCodeTranslator

/// The Command Code client for the PAID destination model (Muse), used for
/// everything that must always run on the strongest model:
///
///  - the router's paid fallback when every free tier is exhausted,
///  - the Stage-0 learn fold (`Stage0ModelClient`),
///  - plural source-form authoring (`PluralGenerator`).
///
/// The translation path itself goes through `TranslationRouter`, which picks
/// a free tier first and lands here last. Wire format is shared with every
/// other provider via `OpenAIChatClient` (OpenAI-compatible
/// `POST /provider/v1/chat/completions`).
///
/// The API key comes from `CommandCodeKeychain` (login keychain →
/// COMMANDCODE_API_KEY environment variable → ~/.hermes/.env). Without a key
/// the backend is not eligible, and `translate` throws
/// `BackendError.notConfigured` — it never crashes.
nonisolated struct CommandCodeTranslator: TranslatorBackend {
  /// Root for the OpenAI-compatible Command Code provider API.
  static let baseURL = URL(string: "https://api.commandcode.ai/provider/v1")!
  static let endpoint = baseURL.appendingPathComponent("chat/completions")
  /// The paid destination model. `RoutedModel.muse` names the same model for
  /// the router; keep the two in step.
  static let model = RoutedModel.muse.model
  /// Per-request budget; hosted frontier models can take a while on long strings.
  static let requestTimeout: TimeInterval = 180

  var id: BackendID { .commandcode }
  var displayName: String { "Command Code" }

  func isEligible(from: String, to: String) async -> Bool {
    CommandCodeKeychain.apiKey() != nil
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
    guard let apiKey = CommandCodeKeychain.apiKey() else {
      throw BackendError.notConfigured(
        "Command Code is not configured: set COMMANDCODE_API_KEY in the login keychain, "
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
      apiKey: apiKey,
      model: Self.model,
      timeout: Self.requestTimeout)
    return try await client.complete(system: prompt.system, user: prompt.user)
  }
}
