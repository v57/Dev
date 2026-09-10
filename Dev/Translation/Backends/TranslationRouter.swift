//
//  TranslationRouter.swift
//  Dev
//

import Foundation
import Observation

// MARK: - TranslationRouter

/// The single translation entry point the pipeline calls.
///
/// ONE `translate` function walks the free-model chain in
/// `RoutedModel.chain` and falls through to the paid `muse` model when every
/// free tier is exhausted. Candidates that answer with a quota refusal
/// (HTTP 429/402) are cooled down in memory and skipped for the rest of the
/// session; transport failures just move on to the next candidate.
///
/// `@Observable` so the run footer can show which model is answering. All
/// routing state lives on the main actor; the HTTP calls themselves stay
/// `nonisolated`, so pool workers still run them off the main actor.
@MainActor
@Observable
final class TranslationRouter: TranslatorBackend {
  /// App-wide instance: the pipeline and the footer must observe the SAME
  /// routing state, and cooldowns should outlive a single run.
  static let shared = TranslationRouter()

  /// Status-bar label of the model that last served a request.
  private(set) var currentModel = RoutedModel.muse.name
  /// Provider of `currentModel`.
  private(set) var currentProvider = RoutedModel.muse.provider.displayName
  /// True while the paid destination is answering.
  private(set) var isUsingPaidModel = true
  /// Candidate id → the instant it may be retried (quota/rate cooldowns).
  private(set) var cooldowns: [String: Date] = [:]
  /// Last routing failure, for the status tooltip.
  private(set) var lastError: String?

  /// Cooldown applied when a provider refuses for quota reasons without a
  /// `Retry-After`.
  static let defaultCooldown: TimeInterval = 15 * 60
  /// Cooldown applied after a NON-quota failure. Without this a dead or
  /// unknown free id would be re-tried once per record instead of once per
  /// window — the whole catalog would pay for it.
  static let transientCooldown: TimeInterval = 5 * 60

  // MARK: - TranslatorBackend

  nonisolated var id: BackendID { .commandcode }

  /// Records persist the ACCOUNT that produced a value, not the model id, so
  /// the editor stamp stays stable across free/paid routing.
  nonisolated var displayName: String { "Command Code" }

  /// Eligible whenever at least one candidate has a usable key.
  nonisolated func isEligible(from: String, to: String) async -> Bool {
    RoutedModel.chain.contains { $0.apiKey != nil }
  }

  /// Routing entry point: free tiers in order, then the paid destination.
  nonisolated func translate(
    _ text: String,
    from: String,
    to: String,
    context: TranslationContext?
  ) async throws -> String {
    try await route(text, from: from, to: to, context: context)
  }

  // MARK: - routing

  private func route(
    _ text: String,
    from: String,
    to: String,
    context: TranslationContext?
  ) async throws -> String {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return text
    }
    var lastFailure: BackendError?
    for candidate in RoutedModel.chain {
      guard let key = candidate.apiKey else { continue }
      if let until = cooldowns[candidate.id], until > .now { continue }

      currentModel = candidate.name
      currentProvider = candidate.provider.displayName
      isUsingPaidModel = !candidate.isFree

      do {
        return try await Self.call(
          candidate, apiKey: key, text: text, from: from, to: to, context: context)
      } catch let error as BackendError {
        lastFailure = error
        // Cool the candidate down on ANY failure. A quota refusal gets the
        // provider's own `Retry-After`; everything else (dead free id,
        // upstream 5xx, unparseable reply) gets the shorter transient window.
        // Either way the next record skips it instead of paying again.
        let cooldown = error.suggestedCooldown
          ?? (error.isQuotaExhausted ? Self.defaultCooldown : Self.transientCooldown)
        cooldowns[candidate.id] = Date.now.addingTimeInterval(cooldown)
        lastError = "\(candidate.name): \(error.localizedDescription)"
        continue
      }
    }
    throw lastFailure ?? BackendError.notConfigured(
      "No translation model is available: no provider key is configured and every free tier is cooling down.")
  }

  /// Prompt assembly is shared, so routing never changes what a model sees.
  private static func call(
    _ candidate: RoutedModel,
    apiKey: String,
    text: String,
    from: String,
    to: String,
    context: TranslationContext?
  ) async throws -> String {
    let prompt = ContextPromptBuilder.assemble(
      sourceText: text,
      sourceLanguage: from,
      targetLanguage: to,
      context: context)
    let client = OpenAIChatClient(
      endpoint: candidate.provider.chatEndpoint,
      apiKey: apiKey,
      model: candidate.model,
      headers: candidate.headers)
    return try await client.complete(system: prompt.system, user: prompt.user)
  }

  // MARK: - status

  /// One-line status for the run footer, e.g. "DeepSeek V4 Flash (free)".
  var statusText: String { currentModel }

  /// Clears quota cooldowns (a manual "try free tiers again" affordance).
  func resetCooldowns() {
    cooldowns.removeAll()
    lastError = nil
  }
}
