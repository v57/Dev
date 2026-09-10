//
//  OpenAIChatClient.swift
//  Dev
//

import Foundation

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

  func complete(system: String, user: String, temperature: Double = 0.2) async throws -> String {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    do {
      request.httpBody = try JSONEncoder().encode(Request(
        model: model,
        messages: [
          Request.Message(role: "system", content: system),
          Request.Message(role: "user", content: user),
        ],
        temperature: temperature))
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
    return content.trimmingCharacters(in: .whitespacesAndNewlines)
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

    struct Message: Encodable {
      var role: String
      var content: String
    }
  }

  private struct Response: Decodable {
    struct Choice: Decodable {
      struct Message: Decodable { var content: String? }
      var message: Message?
    }

    struct APIError: Decodable { var message: String? }

    var choices: [Choice]?
    var error: APIError?
  }
}
