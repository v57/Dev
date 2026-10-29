//
//  Stream.swift
//  Dev
//
//  Created by Dmitry on 15.09.26.
//
//  One completion, read as it is written.
//
//  Three protocols arrive through this file, picked by `Wire` (OpenAIChatClient.swift):
//  the Responses and Messages protocols, whose frames name their own event type, and the
//  chat wire's `choices`/`delta` frames. Which one a model speaks is its preset's business.
//  Everything downstream is identical for all three — this file only turns frames into text.
//
//  The redesign's requirement is that a row reaches the run the moment the model finishes
//  writing it, not when the whole batch does (5.5): a 33-row reply is minutes of writing,
//  and a reply that breaks in the middle of it must not cost the rows that arrived before
//  the break. So the request goes out with `stream: true` and this file is the wire that
//  makes that readable — SSE frames in, text deltas out, usage at the end.
//
//  Two things are deliberately tolerant, both because a provider is a party we do not
//  control and neither of them costs anything:
//
//    · a provider that IGNORES `stream` answers with one whole JSON body instead. That is
//      detected from the response's own content type and read as a single delta, so a
//      non-streaming provider answers exactly as it does today instead of failing.
//    · `stream_options.include_usage` is what makes the last frame carry the token counts
//      (5.7's cached share depends on them), but a provider that rejects the field at all
//      answers 400 — so a 400 that arrived before any text is retried once without it,
//      and the run loses the numbers rather than the batch.
//
//  The wire details — endpoint, model, keychain, `BackendError`'s taxonomy — follow
//  Translation/Backends/OpenAIChatClient.swift and RoutedModel.swift, read as
//  the precedent and never called: the redesign carries its own client (see `Router`).

import Foundation
import PlatformHTTP

extension Translation {
  /// One streamed chat completion: what the provider wrote, as it wrote it.
  ///
  /// Not a client of its own — `Router` owns admission, the cooldown and the telemetry,
  /// and hands the one candidate in. This is only the transport, and it is why it parses
  /// no REPLY: the SSE frames are the envelope, and the text inside them is passed on
  /// untouched for the party that asked the question to read (`Validator.Scanner`).
  struct ChatStream {
    /// Full completion URL (provider root + the wire protocol's path).
    let endpoint: URL
    let apiKey: String
    let model: String
    /// Which wire protocol `endpoint` speaks (see `Wire` in OpenAIChatClient).
    var wire: Wire = .chatCompletions
    /// Extra headers a provider requires (OpenCode's session id, the user agent).
    var headers: [String: String] = [:]
    var timeout: TimeInterval = 180

    /// What the provider reported about the call. Every number is optional because a
    /// provider is free to report none of them, and — see `includeUsage` — may not know
    /// how to report them on a stream at all.
    struct Usage: Equatable {
      var promptTokens: Int? = nil
      var completionTokens: Int? = nil
      /// Tokens served from the provider's prompt cache. A flat zero across a run says the
      /// prompt layout is not cacheable, which is a bug in the prompt rather than a
      /// property of the model (5.7).
      var cachedTokens: Int? = nil

      /// True when the provider reported nothing at all.
      var isEmpty: Bool { promptTokens == nil && completionTokens == nil && cachedTokens == nil }
    }

    /// Sends one request and hands every piece of text to `onChunk`, in the order the
    /// model wrote them. Answers with the usage the provider reported, or nil when it
    /// reported none.
    ///
    /// Throws `BackendError.emptyResult` when the model answered nothing at all — the same
    /// reading the non-streamed client makes, so a silently empty answer is a retryable
    /// failure rather than a batch of empty rows.
    func send(
      system: String,
      user: String,
      temperature: Double = 0.2,
      onChunk: (String) -> Void
    ) async throws -> Usage? {
      return try await attempt(
        system: system, user: user, temperature: temperature,
        includeUsage: true, onChunk: onChunk)
    }

    // MARK: - one attempt

    private func attempt(
      system: String, user: String, temperature: Double?, includeUsage: Bool,
      onChunk: (String) -> Void
    ) async throws -> Usage? {
      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.timeoutInterval = timeout
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      // A local server takes no key: an empty one sends no header at all.
      if !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      }
      for (name, value) in wire.headers(apiKey: apiKey).merging(headers, uniquingKeysWith: { _, own in own }) {
        request.setValue(value, forHTTPHeaderField: name)
      }
      do {
        switch wire {
        case .chatCompletions:
          request.httpBody = try JSONEncoder().encode(
            Request(
              model: model,
              messages: [
                Request.Message(role: "system", content: system),
                Request.Message(role: "user", content: user),
              ],
              temperature: temperature,
              stream: true,
              stream_options: includeUsage ? Request.StreamOptions(include_usage: true) : nil))
        case .responses:
          // The Responses API streams usage in its closing frame and knows no
          // `stream_options`, so the includeUsage retry below only ever fires
          // for the chat wire.
          request.httpBody = try JSONEncoder().encode(
            ResponsesRequest(
              model: model,
              instructions: system,
              input: [ResponsesRequest.Item(role: "user", content: user)],
              temperature: temperature,
              stream: true))
        case .anthropicMessages:
          // Like Responses, Messages streams its usage on its own (`message_start`,
          // `message_delta`) and knows no `stream_options`.
          request.httpBody = try JSONEncoder().encode(
            MessagesRequest(
              model: model,
              system: system,
              messages: [MessagesRequest.Message(role: "user", content: user)],
              temperature: temperature,
              max_tokens: Wire.defaultMaxTokens,
              stream: true))
        }
      } catch {
        throw BackendError.network("could not encode request: \(error.localizedDescription)")
      }

      let bytes: HTTPBytes
      let response: URLResponse
      do {
        (bytes, response) = try await HTTPBytes.response(for: request)
      } catch {
        if Task.isCancelled { throw CancellationError() }
        throw BackendError.network(error.localizedDescription)
      }
      guard let http = response as? HTTPURLResponse else {
        throw BackendError.network("no HTTP response from \(endpoint.host ?? "provider")")
      }
      guard (200..<300).contains(http.statusCode) else {
        let excerpt = try? await body(of: bytes)
        if Task.isCancelled { throw CancellationError() }
        // A provider that does not know `stream_options` rejects the field with a 400, and
        // it says so before it writes a byte of the reply — so the retry cannot lose text,
        // it only loses the token numbers the run would have counted (5.7).
        // Only the chat wire sends `stream_options`: on the Responses wire the retry would
        // resend the very same body, so a 400 there is an answer, not a field to drop.
        // Reasoning models refuse a `temperature` outright, again before any text,
        // so it is dropped and the request asked once more.
        if http.statusCode == 400, temperature != nil,
           excerpt?.localizedCaseInsensitiveContains("temperature") == true {
          return try await attempt(
            system: system, user: user, temperature: nil,
            includeUsage: includeUsage, onChunk: onChunk)
        }
        if http.statusCode == 400, includeUsage, wire == .chatCompletions {
          return try await attempt(
            system: system, user: user, temperature: temperature,
            includeUsage: false, onChunk: onChunk)
        }
        // 429 / 402 are quota refusals: the router parks the candidate for them.
        if http.statusCode == 429 || http.statusCode == 402 {
          throw BackendError.rateLimited(http.statusCode, excerpt, Self.retryAfter(http))
        }
        throw BackendError.badStatus(http.statusCode, excerpt)
      }

      let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
      guard contentType.contains("text/event-stream") else {
        // The provider ignored `stream`: one whole reply, read as one delta.
        return try await whole(of: bytes, onChunk: onChunk)
      }
      return try await frames(of: bytes, onChunk: onChunk)
    }

    /// The SSE frames of a streamed reply. Every `data:` line is one frame; `[DONE]` ends
    /// the stream; a frame that carries no text (a role announcement, a keep-alive, the
    /// final usage-only frame) is read for what it has and passed over.
    private func frames(
      of bytes: HTTPBytes, onChunk: (String) -> Void
    ) async throws -> Usage? {
      var usage: Usage?
      var arrived = false
      for try await line in bytes.lines {
        guard line.hasPrefix("data:") else { continue }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { continue }
        if payload == "[DONE]" { break }
        let frame = try Self.reading(payload)
        if let text = frame.text, !text.isEmpty {
          arrived = true
          onChunk(text)
        }
        // The Messages wire reports its usage in two frames (input first, output
        // last), so a frame's numbers fill in the ones before it.
        if let reported = frame.usage, !reported.isEmpty {
          usage = Usage(
            promptTokens: reported.promptTokens ?? usage?.promptTokens,
            completionTokens: reported.completionTokens ?? usage?.completionTokens,
            cachedTokens: reported.cachedTokens ?? usage?.cachedTokens)
        }
      }
      guard arrived else { throw BackendError.emptyResult(model) }
      return usage
    }

    /// A reply from a provider that ignored `stream`: the whole body is one JSON object
    /// with the message in it — in the shape of the wire it was asked on — and it is
    /// handed over as a single chunk so the caller's scanner sees the same thing either way.
    private func whole(
      of bytes: HTTPBytes, onChunk: (String) -> Void
    ) async throws -> Usage? {
      var data = Data()
      do {
        for try await byte in bytes { data.append(byte) }
      } catch {
        if Task.isCancelled { throw CancellationError() }
        throw BackendError.network(error.localizedDescription)
      }
      let content: String?
      let usage: Usage?
      switch wire {
      case .chatCompletions:
        guard let decoded = try? JSONDecoder().decode(Whole.self, from: data) else {
          throw BackendError.decoding(BackendError.bodyExcerpt(data) ?? "invalid JSON")
        }
        if let message = decoded.error?.message, !message.isEmpty {
          throw BackendError.badStatus(200, message)
        }
        content = decoded.choices?.first?.message?.content
        usage = decoded.usage?.usage
      case .responses:
        // The Responses shape: `output` items, the answer in their `output_text` parts.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          throw BackendError.decoding(BackendError.bodyExcerpt(data) ?? "invalid JSON")
        }
        if let message = Self.errorMessage(in: object) {
          throw BackendError.badStatus(200, message)
        }
        content = Self.outputText(of: object)
        usage = (object["usage"] as? [String: Any]).flatMap(Self.responsesUsage(of:))
      case .anthropicMessages:
        // The Messages shape: `content` blocks, the answer in the `text` ones.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          throw BackendError.decoding(BackendError.bodyExcerpt(data) ?? "invalid JSON")
        }
        if let message = Self.errorMessage(in: object) {
          throw BackendError.badStatus(200, message)
        }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }
          .compactMap { $0["text"] as? String }.joined()
        content = text.isEmpty ? nil : text
        usage = (object["usage"] as? [String: Any]).flatMap(Self.messagesUsage(of:))
      }
      guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BackendError.emptyResult(model)
      }
      onChunk(content)
      return usage
    }

    /// A short excerpt of a failed response's body, bounded so a provider that answers an
    /// error with a megabyte of HTML cannot fill memory with it.
    private func body(of bytes: HTTPBytes) async throws -> String? {
      var data = Data()
      for try await byte in bytes {
        data.append(byte)
        if data.count >= 2048 { break }
      }
      return BackendError.bodyExcerpt(data)
    }

    /// `Retry-After` in seconds, when the provider sent one.
    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
      guard
        let raw = response.value(forHTTPHeaderField: "Retry-After")?
          .trimmingCharacters(in: .whitespaces),
        !raw.isEmpty
      else { return nil }
      return TimeInterval(raw)
    }

    // MARK: - one frame

    /// What one SSE frame carries: the text the model just wrote, the usage a final frame
    /// reports, or neither.
    ///
    /// Read with `JSONSerialization` rather than a decoded type on purpose: this is the
    /// frame of a stream that may be any length and may arrive in any of the shapes
    /// providers use (`delta` while streaming, `message` for a provider that sent the
    /// whole answer in one frame), and a strict type here would fail a batch over a frame
    /// the caller never needed.
    private static func reading(_ payload: String) throws -> (text: String?, usage: Usage?) {
      guard let data = payload.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return (nil, nil) }
      if let message = errorMessage(in: object) {
        throw BackendError.badStatus(200, message)
      }
      // A Responses or Messages frame names its own event type; the chat wire's
      // frames carry no `type` and fall through to the `choices` reading below.
      if let type = object["type"] as? String {
        switch type {
        case "content_block_delta":
          // Messages: only `text_delta`s are the answer; thinking deltas are not.
          guard let delta = object["delta"] as? [String: Any],
            delta["type"] as? String == "text_delta"
          else { return (nil, nil) }
          return (delta["text"] as? String, nil)
        case "message_start":
          // Messages: the input side of the usage, before any text.
          let message = object["message"] as? [String: Any]
          return (nil, (message?["usage"] as? [String: Any]).flatMap(messagesUsage(of:)))
        case "message_delta":
          // Messages: the output side of the usage, at the end.
          return (nil, (object["usage"] as? [String: Any]).flatMap(messagesUsage(of:)))
        case "response.output_text.delta":
          return (object["delta"] as? String, nil)
        case "response.completed", "response.incomplete":
          // The closing frame carries the usage; an `incomplete` answer is a
          // cut reply, which the caller's validator reports, not this reader.
          guard let response = object["response"] as? [String: Any],
            let reported = response["usage"] as? [String: Any]
          else { return (nil, nil) }
          return (nil, responsesUsage(of: reported))
        case "response.failed":
          let response = object["response"] as? [String: Any]
          let message = ((response?["error"] as? [String: Any])?["message"] as? String)
            ?? "the model call failed"
          throw BackendError.badStatus(200, message)
        case "error":
          // The Responses stream's own error event carries its message at the top level
          // (`{"type": "error", "code": …, "message": …}`), not under `error`.
          throw BackendError.badStatus(200, (object["message"] as? String) ?? "the model call failed")
        default:
          // created / in_progress / output_item.* / content_part.* / reasoning
          // deltas, and Messages' ping / content_block_start|stop / message_stop:
          // read for nothing, passed over.
          return (nil, nil)
        }
      }
      var text: String?
      if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
        if let delta = choice["delta"] as? [String: Any] {
          text = delta["content"] as? String
        }
        if text == nil, let message = choice["message"] as? [String: Any] {
          text = message["content"] as? String
        }
      }
      guard let reported = object["usage"] as? [String: Any] else { return (text, nil) }
      return (text, usage(of: reported))
    }

    /// The message of an `error` object a frame or a whole reply carries, when it has one.
    private static func errorMessage(in object: [String: Any]) -> String? {
      guard let error = object["error"] as? [String: Any],
        let message = error["message"] as? String, !message.isEmpty
      else { return nil }
      return message
    }

    /// The answer text of a whole Responses reply: every `output_text` part of every
    /// `message` item, in order. Reasoning items are not the answer.
    private static func outputText(of object: [String: Any]) -> String? {
      var parts: [String] = []
      for item in object["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
        for part in item["content"] as? [[String: Any]] ?? []
        where part["type"] as? String == "output_text" {
          if let text = part["text"] as? String { parts.append(text) }
        }
      }
      return parts.isEmpty ? nil : parts.joined()
    }

    /// The usage numbers of one JSON object, read tolerantly: the two cache keys are the
    /// two shapes providers report a prompt cache hit in.
    private static func usage(of object: [String: Any]) -> Usage? {
      var usage = Usage()
      usage.promptTokens = object["prompt_tokens"] as? Int
      usage.completionTokens = object["completion_tokens"] as? Int
      if let hit = object["prompt_cache_hit_tokens"] as? Int {
        usage.cachedTokens = hit
      } else if let details = object["prompt_tokens_details"] as? [String: Any] {
        usage.cachedTokens = details["cached_tokens"] as? Int
      }
      return usage.isEmpty ? nil : usage
    }

    /// The usage numbers of a Responses-API frame: `input_tokens` /
    /// `output_tokens`, cache hits under `input_tokens_details`.
    private static func responsesUsage(of object: [String: Any]) -> Usage? {
      var usage = Usage()
      usage.promptTokens = object["input_tokens"] as? Int
      usage.completionTokens = object["output_tokens"] as? Int
      if let details = object["input_tokens_details"] as? [String: Any] {
        usage.cachedTokens = details["cached_tokens"] as? Int
      }
      return usage.isEmpty ? nil : usage
    }

    /// The usage numbers of a Messages-API frame: `input_tokens` / `output_tokens`,
    /// cache hits as `cache_read_input_tokens`.
    private static func messagesUsage(of object: [String: Any]) -> Usage? {
      var usage = Usage()
      usage.promptTokens = object["input_tokens"] as? Int
      usage.completionTokens = object["output_tokens"] as? Int
      usage.cachedTokens = object["cache_read_input_tokens"] as? Int
      return usage.isEmpty ? nil : usage
    }

    // MARK: - wire shapes

    private struct Request: Encodable {
      var model: String
      var messages: [Message]
      var temperature: Double?
      var stream: Bool
      var stream_options: StreamOptions?

      struct Message: Encodable {
        var role: String
        var content: String
      }

      struct StreamOptions: Encodable {
        var include_usage: Bool
      }
    }

    /// The Responses-API request body. It streams usage
    /// in its closing frame; there is no `stream_options` in this protocol.
    private struct ResponsesRequest: Encodable {
      var model: String
      var instructions: String
      var input: [Item]
      var temperature: Double?
      var stream: Bool

      struct Item: Encodable {
        var role: String
        var content: String
      }
    }

    /// The Messages-API request body. It streams usage in its own frames; there is
    /// no `stream_options` in this protocol either.
    private struct MessagesRequest: Encodable {
      var model: String
      var system: String
      var messages: [Message]
      var temperature: Double?
      var max_tokens: Int
      var stream: Bool

      struct Message: Encodable {
        var role: String
        var content: String
      }
    }

    /// A whole (non-streamed) reply, for the provider that ignored `stream`.
    private struct Whole: Decodable {
      struct Choice: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message?
      }

      struct APIError: Decodable { var message: String? }

      struct Reported: Decodable {
        struct PromptDetails: Decodable { var cached_tokens: Int? }
        var prompt_tokens: Int?
        var completion_tokens: Int?
        var prompt_cache_hit_tokens: Int?
        var prompt_tokens_details: PromptDetails?

        var usage: Usage {
          Usage(
            promptTokens: prompt_tokens,
            completionTokens: completion_tokens,
            cachedTokens: prompt_cache_hit_tokens ?? prompt_tokens_details?.cached_tokens)
        }
      }

      var choices: [Choice]?
      var error: APIError?
      var usage: Reported?
    }
  }
}
