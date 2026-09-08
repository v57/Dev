//
//  OllamaTranslator.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

// MARK: - OllamaTranslator

/// A local Ollama server (http://localhost:11434) running the
/// translate-tuned gemma model. Context is folded into the prompt via
/// `ContextPromptBuilder`.
///
/// Wire (live-verified against the documented /api/chat shape):
/// POST /api/chat with `{"model", "messages", "stream": false}`;
/// the answer comes back in `message.content`.
nonisolated struct OllamaTranslator: TranslatorBackend {
  static let baseURL = URL(string: "http://localhost:11434")!
  static let model = "translategemma:12b"
  /// How long the reachability probe waits before declaring the server gone.
  static let probeTimeout: TimeInterval = 5
  /// Per-request budget; the first call loads the model into memory.
  static let requestTimeout: TimeInterval = 180

  var id: BackendID { .ollama }
  var displayName: String { id.displayName }

  func isEligible(from: String, to: String) async -> Bool {
    guard let url = URL(string: "http://localhost:11434/api/tags") else {
      return false
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = Self.probeTimeout
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return false }
      return (200..<300).contains(http.statusCode)
    } catch {
      // Server down or not installed — degrade, never crash.
      return false
    }
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
    let prompt = ContextPromptBuilder.assemble(
      sourceText: text,
      sourceLanguage: from,
      targetLanguage: to,
      context: context
    )

    let requestBody = chatRequest(system: prompt.system, user: prompt.user)
    let body: Data
    do {
      body = try JSONEncoder().encode(requestBody)
    } catch {
      throw BackendError.network("could not encode request: \(error.localizedDescription)")
    }

    var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/chat"))
    request.httpMethod = "POST"
    request.timeoutInterval = Self.requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw BackendError.network(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
      throw BackendError.network("no HTTP response from Ollama")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw BackendError.badStatus(http.statusCode, BackendError.bodyExcerpt(data))
    }

    let decoded: ChatResponse
    do {
      decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
    } catch {
      throw BackendError.decoding(BackendError.bodyExcerpt(data) ?? "invalid JSON")
    }
    guard
      let content = decoded.message?.content,
      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw BackendError.emptyResult("Ollama (\(Self.model))")
    }
    return content.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - wire shapes

  private func chatRequest(system: String, user: String) -> ChatRequest {
    ChatRequest(
      model: Self.model,
      messages: [
        ChatRequest.Message(role: "system", content: system),
        ChatRequest.Message(role: "user", content: user),
      ]
    )
  }

  private struct ChatRequest: Encodable {
    var model: String
    var messages: [Message]
    var stream: Bool = false
    var options: Options = Options()

    struct Message: Encodable {
      var role: String
      var content: String
    }

    struct Options: Encodable {
      /// Low but non-zero so Stage 2 can surface alternative phrasings.
      var temperature: Double = 0.2
    }
  }

  private struct ChatResponse: Decodable {
    struct Message: Decodable {
      var content: String?
    }

    var message: Message?
    var error: String?
  }
}
