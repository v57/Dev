//
//  OpenAIChatClient.swift
//  Dev
//

import Foundation

// MARK: - ChatReply

/// One model reply plus the token accounting the provider reported.
nonisolated struct ChatReply: Sendable {
  var content: String
  var promptTokens: Int?
  var completionTokens: Int?
  /// Tokens served from the provider's prompt cache, when reported. A healthy
  /// stable prefix shows up here; zero across a whole run means the prompt
  /// layout is not cacheable.
  var cachedTokens: Int?
}

// MARK: - OpenAIChatClient

/// One OpenAI-compatible `POST {endpoint}` chat completion. Every hosted
/// provider the router talks to (Command Code, OpenCode Zen, OpenRouter)
/// speaks this shape, so the wire code lives here exactly once.
nonisolated struct OpenAIChatClient: Sendable {
  /// Full chat-completions URL (provider root + `/chat/completions`).
  let endpoint: URL
  let apiKey: String
  let model: String
  /// Extra headers a provider requires (OpenRouter attribution, ...).
  var headers: [String: String] = [:]
  var timeout: TimeInterval = 180

  func complete(
    system: String,
    user: String,
    temperature: Double = 0.2,
    maxTokens: Int? = nil,
    jsonObject: Bool = false
  ) async throws -> ChatReply {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    do {
      var body = Request(
        model: model,
        messages: [
          Request.Message(role: "system", content: system),
          Request.Message(role: "user", content: user),
        ],
        temperature: temperature,
        max_tokens: maxTokens)
      // JSON mode keeps batch replies parseable; providers that ignore it are
      // unaffected because the validator parses tolerantly either way.
      body.response_format = jsonObject ? Request.ResponseFormat(type: "json_object") : nil
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      throw BackendError.network("could not encode request: \(error.localizedDescription)")
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw BackendError.network(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
      throw BackendError.network("no HTTP response from \(endpoint.host ?? "provider")")
    }
    let excerpt = BackendError.bodyExcerpt(data)
    guard (200..<300).contains(http.statusCode) else {
      // 429 / 402 are quota refusals: the router cools the candidate down.
      if http.statusCode == 429 || http.statusCode == 402 {
        throw BackendError.rateLimited(http.statusCode, excerpt, Self.retryAfter(http))
      }
      throw BackendError.badStatus(http.statusCode, excerpt)
    }

    let decoded: Response
    do {
      decoded = try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw BackendError.decoding(excerpt ?? "invalid JSON")
    }
    if let apiError = decoded.error?.message, !apiError.isEmpty {
      throw BackendError.badStatus(http.statusCode, apiError)
    }
    guard let content = decoded.choices?.first?.message?.content,
          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BackendError.emptyResult(model)
    }
    return ChatReply(
      content: content.trimmingCharacters(in: .whitespacesAndNewlines),
      promptTokens: decoded.usage?.prompt_tokens,
      completionTokens: decoded.usage?.completion_tokens,
      cachedTokens: decoded.usage?.cachedTokens)
  }

  /// `Retry-After` in seconds, when the provider sent one.
  private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
    guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
      .trimmingCharacters(in: .whitespaces),
      !raw.isEmpty else {
      return nil
    }
    return TimeInterval(raw)
  }

  // MARK: - wire shapes

  private struct Request: Encodable {
    var model: String
    var messages: [Message]
    var temperature: Double
    var max_tokens: Int?
    var response_format: ResponseFormat?

    struct Message: Encodable {
      var role: String
      var content: String
    }

    struct ResponseFormat: Encodable {
      var type: String
    }
  }

  private struct Response: Decodable {
    struct Choice: Decodable {
      struct Message: Decodable { var content: String? }
      var message: Message?
    }

    struct APIError: Decodable { var message: String? }

    struct Usage: Decodable {
      struct PromptDetails: Decodable { var cached_tokens: Int? }
      var prompt_tokens: Int?
      var completion_tokens: Int?
      /// DeepSeek reports cache hits at the top level.
      var prompt_cache_hit_tokens: Int?
      var prompt_tokens_details: PromptDetails?

      var cachedTokens: Int? {
        prompt_cache_hit_tokens ?? prompt_tokens_details?.cached_tokens
      }
    }

    var choices: [Choice]?
    var error: APIError?
    var usage: Usage?
  }
}
