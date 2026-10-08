//
//  TranslationRouter.swift
//  Dev
//

import Foundation

// MARK: - Batch outcomes

/// Result of one routing attempt over a batch of records.
nonisolated struct BatchOutcome: Sendable {
  /// Ids that passed both the id-set and the deterministic checks.
  var values: [Int: String] = [:]
  /// Ids still needing a single-item repair pass.
  var failedIDs: [Int] = []
  var model = ""
  var provider = ""
  var isPaid = false
  /// Human-readable reasons for the failures, for the run log.
  var notes: [String] = []
  /// True when the reply was CUT OFF: the ids in `failedIDs` were lost to the
  /// cut rather than individually rejected, and `values` holds whatever arrived
  /// complete. The caller re-asks the remainder in smaller batches instead of
  /// repairing id by id.
  var truncated = false
}

// MARK: - TranslationRouter

/// The translation entry point the server pane's corpus run calls.
///
/// Walks `RoutedModel.chain` — one candidate today, Muse on OpenCode Go —
/// with candidate cooldowns, per-provider pacing and the deterministic
/// validation shared by both operations:
///
///  - `translateBatch` — the language-uniform batch path (one target
///    language per request).
///  - `translate` — the single-item path, used to repair batch failures.
///
/// The HTTP calls stay `nonisolated`; only routing state is main-actor bound.
@MainActor
final class TranslationRouter {
  /// App-wide instance, so cooldowns outlive a single run.
  static let shared = TranslationRouter()

  // MARK: routing state

  /// Candidate id → the instant it may be retried (cooldowns).
  private var cooldowns: [String: Date] = [:]

  // MARK: pacing

  /// Provider → instants of recent requests, for the per-minute budget.
  private var recentCalls: [RoutedModel.Provider: [Date]] = [:]

  /// Cooldown when a provider refuses for quota reasons without `Retry-After`.
  static let defaultCooldown: TimeInterval = 15 * 60
  /// Cooldown after a NON-quota failure. Without this a dead or unknown free
  /// id would be retried once per record instead of once per window.
  static let transientCooldown: TimeInterval = 5 * 60
  /// Source-character budget for one batch request; the context block is on
  /// top of it. A batch is sized by its payload instead of by record count — records range from a label to
  /// a sentence, and a fixed count is either wasteful or oversized. No
  /// tokenizer: the routed models carry very large context windows, so a
  /// grapheme count is accurate enough and free.
  nonisolated static let translateSourceBudget = 10_000

  // MARK: - eligibility

  /// Eligible whenever at least one candidate has a usable key.
  nonisolated func isEligible(from: String, to: String) async -> Bool {
    RoutedModel.chain.contains { $0.apiKey != nil }
  }

  /// Single-item routing entry point (the repair path).
  nonisolated func translate(
    _ text: String,
    from: String,
    to: String,
    context: TranslationContext?
  ) async throws -> String {
    try await routeSingle(text, from: from, to: to, context: context)
  }

  // MARK: - batch path

  /// Translates a whole language-grouped batch through the chain.
  ///
  /// Accepts whatever validates and reports the rest as `failedIDs`, so a
  /// partially bad reply costs a few single-item repairs rather than a whole
  /// re-run. A transport/quota failure moves to the next candidate with the
  /// full batch intact.
  func translateBatch(
    _ items: [ContextPromptBuilder.BatchItem],
    from: String,
    to: String
  ) async -> BatchOutcome {
    guard !items.isEmpty else { return BatchOutcome() }
    var lastFailure: BackendError?

    for candidate in RoutedModel.chain {
      guard let key = candidate.apiKey else { continue }
      if let until = cooldowns[candidate.id], until > .now { continue }
      await admit(candidate.provider)
      do {
        let prompt = ContextPromptBuilder.assembleBatch(
          items: items,
          sourceLanguage: from,
          targetLanguage: to,
          sharedContext: items.first?.context)
        let reply = try await Self.call(
          candidate, apiKey: key, system: prompt.system, user: prompt.user)
        return validate(reply.content, items: items, candidate: candidate)
      } catch {
        // Any escape from the error taxonomy still must not abort the run.
        let backendError = (error as? BackendError) ?? .network(error.localizedDescription)
        lastFailure = backendError
        cool(candidate, error: backendError)
      }
    }
    return BatchOutcome(
      failedIDs: items.map(\.id),
      model: RoutedModel.muse.name,
      provider: RoutedModel.muse.provider.displayName,
      isPaid: true,
      notes: [lastFailure?.localizedDescription ?? "no candidate available"])
  }

  /// Applies the deterministic checks to a parsed batch reply.
  private func validate(
    _ raw: String,
    items: [ContextPromptBuilder.BatchItem],
    candidate: RoutedModel
  ) -> BatchOutcome {
    let parsed = TranslationValidator.parseBatch(raw, expectedIDs: items.map(\.id))
    var outcome = BatchOutcome(
      model: candidate.name,
      provider: candidate.provider.displayName,
      isPaid: !candidate.isFree)
    for issue in parsed.issues {
      outcome.notes.append(issue.description)
      if case .truncated = issue { outcome.truncated = true }
    }
    for item in items {
      guard let value = parsed.values[item.id] else {
        outcome.failedIDs.append(item.id)
        continue
      }
      let issues = TranslationValidator.validate(source: item.sourceText, target: value)
      if issues.isEmpty {
        outcome.values[item.id] = value
      } else {
        outcome.failedIDs.append(item.id)
        outcome.notes.append("#\(item.id): " + issues.map(\.description).joined(separator: "; "))
      }
    }
    return outcome
  }

  // MARK: - single path

  private func routeSingle(
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
      await admit(candidate.provider)
      do {
        let prompt = ContextPromptBuilder.assemble(
          sourceText: text,
          sourceLanguage: from,
          targetLanguage: to,
          context: context)
        let reply = try await Self.call(
          candidate, apiKey: key, system: prompt.system, user: prompt.user)
        return reply.content
      } catch let error as BackendError {
        lastFailure = error
        cool(candidate, error: error)
        continue
      }
    }
    throw lastFailure ?? BackendError.notConfigured(
      "No translation model is available: no provider key is configured and every candidate is cooling down.")
  }

  // MARK: - shared plumbing

  private static func call(
    _ candidate: RoutedModel,
    apiKey: String,
    system: String,
    user: String
  ) async throws -> ChatReply {
    let client = OpenAIChatClient(
      endpoint: candidate.endpoint,
      wire: candidate.wire,
      apiKey: apiKey,
      model: candidate.model,
      headers: candidate.headers)
    return try await client.complete(system: system, user: user)
  }

  private func cool(_ candidate: RoutedModel, error: BackendError) {
    let cooldown = error.suggestedCooldown
      ?? (error.isQuotaExhausted ? Self.defaultCooldown : Self.transientCooldown)
    cooldowns[candidate.id] = Date.now.addingTimeInterval(cooldown)
  }

  /// Waits until this provider is inside its per-minute request budget.
  /// `Task.sleep` suspends without blocking the actor, so concurrent pool
  /// workers still interleave.
  private func admit(_ provider: RoutedModel.Provider) async {
    while true {
      let now = Date.now
      var times = (recentCalls[provider] ?? []).filter { now.timeIntervalSince($0) < 60 }
      guard times.count >= provider.requestsPerMinute else {
        times.append(now)
        recentCalls[provider] = times
        return
      }
      let oldest = times.min() ?? now
      recentCalls[provider] = times
      let wait = 60 - now.timeIntervalSince(oldest) + 0.05
      guard wait > 0 else { continue }
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }
  }
}
