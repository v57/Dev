//
//  OpenAIChatClient.swift
//  Dev
//

import Foundation

// MARK: - Wire

/// Which OpenAI wire protocol a call speaks.
///
/// `chatCompletions` is the classic shape — `messages` in, `choices` out.
/// `responses` is the Responses API — `instructions` + `input` in, `output`
/// items out — which is what Muse speaks on OpenCode Go.
nonisolated enum Wire: String, Sendable {
  case chatCompletions
  case responses

  /// Path under the provider root.
  var path: String {
    switch self {
    case .chatCompletions: return "chat/completions"
    case .responses: return "responses"
    }
  }
}

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

/// One OpenAI-wire `POST {endpoint}` completion, in either protocol the
/// hosted providers speak (see `Wire`). The router, the translators and the
/// learn client all call this, so the wire code lives here exactly once.
nonisolated struct OpenAIChatClient: Sendable {
  /// Full completion URL (provider root + the wire protocol's path).
  let endpoint: URL
  /// Which protocol `endpoint` speaks.
  var wire: Wire = .chatCompletions
  let apiKey: String
  let model: String
  /// Extra headers a provider requires (OpenCode Go's session id, ...).
  var headers: [String: String] = [:]
  var timeout: TimeInterval = 180

  func complete(
    system: String,
    user: String,
    temperature: Double? = 0.2,
    maxTokens: Int? = nil,
    jsonObject: Bool = false
  ) async throws -> ChatReply {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // A local server takes no key: an empty one sends no header at all.
    if !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    do {
      switch wire {
      case .chatCompletions:
        var body = Request(
          model: model,
          messages: [
            Request.Message(role: "system", content: system),
            Request.Message(role: "user", content: user),
          ],
          temperature: temperature,
          max_tokens: maxTokens)
        // JSON mode keeps batch replies parseable; providers that ignore it
        // are unaffected because the validator parses tolerantly either way.
        body.response_format = jsonObject ? Request.ResponseFormat(type: "json_object") : nil
        request.httpBody = try JSONEncoder().encode(body)
      case .responses:
        // `jsonObject` models the chat protocol's response_format; the
        // Responses API would take `text.format`, but no caller asks for it
        // today — the prompts ask for JSON in words, and the validator
        // parses tolerantly either way.
        let body = ResponsesRequest(
          model: model,
          instructions: system,
          input: [ResponsesRequest.Item(role: "user", content: user)],
          temperature: temperature,
          max_output_tokens: maxTokens)
        request.httpBody = try JSONEncoder().encode(body)
      }
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
      // Reasoning models refuse a `temperature` outright: ask once more without it.
      if http.statusCode == 400, temperature != nil,
         excerpt?.localizedCaseInsensitiveContains("temperature") == true {
        return try await complete(
          system: system, user: user, temperature: nil, maxTokens: maxTokens,
          jsonObject: jsonObject)
      }
      throw BackendError.badStatus(http.statusCode, excerpt)
    }

    let reply: (content: String?, promptTokens: Int?, completionTokens: Int?, cachedTokens: Int?)
    do {
      switch wire {
      case .chatCompletions:
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if let apiError = decoded.error?.message, !apiError.isEmpty {
          throw BackendError.badStatus(http.statusCode, apiError)
        }
        reply = (
          decoded.choices?.first?.message?.content,
          decoded.usage?.prompt_tokens,
          decoded.usage?.completion_tokens,
          decoded.usage?.cachedTokens)
      case .responses:
        let decoded = try JSONDecoder().decode(ResponsesResponse.self, from: data)
        if let apiError = decoded.error?.message, !apiError.isEmpty {
          throw BackendError.badStatus(http.statusCode, apiError)
        }
        reply = (
          Self.text(of: decoded),
          decoded.usage?.input_tokens,
          decoded.usage?.output_tokens,
          decoded.usage?.cachedTokens)
      }
    } catch let error as BackendError {
      throw error
    } catch {
      throw BackendError.decoding(excerpt ?? "invalid JSON")
    }
    guard let content = reply.content,
      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw BackendError.emptyResult(model)
    }
    return ChatReply(
      content: content.trimmingCharacters(in: .whitespacesAndNewlines),
      promptTokens: reply.promptTokens,
      completionTokens: reply.completionTokens,
      cachedTokens: reply.cachedTokens)
  }

  /// The answer text of a Responses payload: every `output_text` part of
  /// every message item, in order. Reasoning items are not the answer.
  private static func text(of decoded: ResponsesResponse) -> String? {
    var parts: [String] = []
    for item in decoded.output ?? [] where item.type == "message" {
      for part in item.content ?? [] where part.type == "output_text" {
        if let text = part.text { parts.append(text) }
      }
    }
    return parts.isEmpty ? nil : parts.joined()
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
    var temperature: Double?
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

  /// The Responses-API request body (Muse on OpenCode Go).
  private struct ResponsesRequest: Encodable {
    var model: String
    var instructions: String
    var input: [Item]
    var temperature: Double?
    var max_output_tokens: Int?

    struct Item: Encodable {
      var role: String
      var content: String
    }
  }

  /// The Responses-API reply: `output` items carrying `output_text` parts,
  /// usage under `input_tokens` / `output_tokens`.
  private struct ResponsesResponse: Decodable {
    struct OutputItem: Decodable {
      struct ContentPart: Decodable {
        var type: String?
        var text: String?
      }

      var type: String?
      var content: [ContentPart]?
    }

    struct APIError: Decodable { var message: String? }

    struct Usage: Decodable {
      struct InputDetails: Decodable { var cached_tokens: Int? }
      var input_tokens: Int?
      var output_tokens: Int?
      var input_tokens_details: InputDetails?

      var cachedTokens: Int? { input_tokens_details?.cached_tokens }
    }

    var output: [OutputItem]?
    var error: APIError?
    var usage: Usage?
  }
}
