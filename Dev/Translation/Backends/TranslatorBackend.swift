//
//  TranslatorBackend.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

// MARK: - TranslatorBackend

/// A uniform translation source for the self-improving translator.
///
/// Adapters are stateless `nonisolated` structs so the pipeline can drive
/// several of them concurrently off the main actor (the module defaults to
/// MainActor isolation). `isEligible` never throws and never crashes: it only
/// reports whether the backend can serve the language pair right now.
nonisolated protocol TranslatorBackend: Sendable {
  /// Stable identifier; raw value matches what records persist.
  var id: BackendID { get }
  /// Human-readable name for UI lists and logs.
  var displayName: String { get }
  /// Cheap capability probe: today, whether the OpenCode Go API key is
  /// present. The (from, to) pair is accepted for backends that need it.
  func isEligible(from: String, to: String) async -> Bool
  /// Translates one string. Throws `BackendError` on failure; never crashes,
  /// even when the backend is not configured.
  func translate(
    _ text: String,
    from: String,
    to: String,
    context: TranslationContext?
  ) async throws -> String
}

// MARK: - BackendError

/// Failure taxonomy shared by all backends. `errorDescription` is safe to
/// show in UI and logs — it never contains credentials or key material.
nonisolated enum BackendError: LocalizedError {
  /// Credential/config missing. This is a first-class state (mock-first
  /// policy): report it, never crash.
  case notConfigured(String)
  /// Transport-level failure (DNS, refused, timeout, encoding).
  case network(String)
  /// Non-2xx HTTP response, with a short body excerpt when available.
  case badStatus(Int, String?)
  /// Quota/rate refusal (HTTP 429/402), with an optional `Retry-After`.
  /// Distinct from `badStatus` so the router can cool the candidate down
  /// instead of treating it as a transient failure.
  case rateLimited(Int, String?, TimeInterval?)
  /// Response body did not match the documented shape.
  case decoding(String)
  /// 2xx, but the model produced no usable text.
  case emptyResult(String)

  var errorDescription: String? {
    switch self {
    case .notConfigured(let detail):
      return detail
    case .network(let detail):
      return "Network error: \(detail)"
    case .badStatus(let code, let excerpt):
      if let excerpt {
        return "HTTP \(code): \(excerpt)"
      }
      return "HTTP \(code)"
    case .rateLimited(let code, let excerpt, let retryAfter):
      var text = "HTTP \(code)"
      if let excerpt {
        text += ": \(excerpt)"
      }
      if let retryAfter {
        text += " (retry in \(Int(retryAfter))s)"
      }
      return text
    case .decoding(let detail):
      return "Unexpected response: \(detail)"
    case .emptyResult(let backend):
      return "\(backend) returned an empty translation"
    }
  }

  /// True when the account or model is out of quota/rate budget, so retrying
  /// this candidate immediately is pointless.
  nonisolated var isQuotaExhausted: Bool {
    switch self {
    case .notConfigured:
      return true
    case .rateLimited:
      return true
    case .badStatus(let code, let body):
      if code == 429 || code == 402 {
        return true
      }
      let text = (body ?? "").lowercased()
      return text.contains("quota") || text.contains("rate limit")
        || text.contains("free usage") || text.contains("insufficient")
    case .network, .decoding, .emptyResult:
      return false
    }
  }

  /// Provider-supplied cooldown, when it sent one.
  nonisolated var suggestedCooldown: TimeInterval? {
    if case .rateLimited(_, _, let retryAfter) = self {
      return retryAfter
    }
    return nil
  }

  /// First ~300 characters of a response body for error messages.
  static func bodyExcerpt(_ data: Data?) -> String? {
    guard let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
      return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.count > 300 {
      return String(trimmed.prefix(300)) + "…"
    }
    return trimmed
  }
}
