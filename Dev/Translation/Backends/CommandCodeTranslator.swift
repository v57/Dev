//
//  CommandCodeTranslator.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

// MARK: - CommandCodeTranslator

/// Command Code's hosted LLM API (api.commandcode.ai, `api_mode =
/// chat_completions` — a standard OpenAI-style POST /chat/completions,
/// live-verified: the answer arrives in `choices[0].message.content`).
/// Model: deepseek/deepseek-v4-flash.
///
/// The API key comes from `CommandCodeKeychain` (login keychain →
/// COMMANDCODE_API_KEY environment variable → ~/.hermes/.env). Without a
/// key the backend is not eligible, and `translate` throws
/// `BackendError.notConfigured` — it never crashes.
nonisolated struct CommandCodeTranslator: TranslatorBackend {
  static let endpoint = URL(string: "https://api.commandcode.ai/provider/v1/chat/completions")!
  static let model = "deepseek/deepseek-v4-flash"
  /// Per-request budget; hosted deepseek can take a while on long strings.
  static let requestTimeout: TimeInterval = 180

  var id: BackendID { .commandcode }
  var displayName: String { id.displayName }

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
      context: context
    )
    let body: Data
    do {
      body = try JSONEncoder().encode(
        CompletionsRequest(
          model: Self.model,
          messages: [
            CompletionsRequest.Message(role: "system", content: prompt.system),
            CompletionsRequest.Message(role: "user", content: prompt.user),
          ]
        )
      )
    } catch {
      throw BackendError.network("could not encode request: \(error.localizedDescription)")
    }

    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = Self.requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = body

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw BackendError.network(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
      throw BackendError.network("no HTTP response from Command Code")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw BackendError.badStatus(http.statusCode, BackendError.bodyExcerpt(data))
    }

    let decoded: CompletionsResponse
    do {
      decoded = try JSONDecoder().decode(CompletionsResponse.self, from: data)
    } catch {
      throw BackendError.decoding(BackendError.bodyExcerpt(data) ?? "invalid JSON")
    }
    if let apiError = decoded.error?.message, !apiError.isEmpty {
      throw BackendError.badStatus(http.statusCode, apiError)
    }
    guard
      let content = decoded.choices?.first?.message?.content,
      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw BackendError.emptyResult("Command Code (\(Self.model))")
    }
    return content.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - wire shapes

  private struct CompletionsRequest: Encodable {
    var model: String
    var messages: [Message]
    /// Low but non-zero: Stage 3 reviews survivors, so a little variety is
    /// useful while still staying close to a single best translation.
    var temperature: Double = 0.2

    struct Message: Encodable {
      var role: String
      var content: String
    }
  }

  private struct CompletionsResponse: Decodable {
    struct Choice: Decodable {
      struct Message: Decodable {
        var content: String?
      }

      var message: Message?
    }

    struct APIError: Decodable {
      var message: String?
    }

    var choices: [Choice]?
    var error: APIError?
  }
}
