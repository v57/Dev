//
//  TranslationRouter.swift
//  Dev
//

import Foundation
import Observation

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

/// One record handed to the paid verification gate.
nonisolated struct GateItem: Sendable {
  var id: Int
  var sourceText: String
  var comment: String?
  var candidate: String
}

// MARK: - TranslationRouter

/// The single translation entry point the pipeline calls.
///
/// Two operations, both walking the same `RoutedModel.chain` and both falling
/// through to the paid `muse` model when the free tiers are exhausted:
///
///  - `translateBatch` — the batch path, used for whole language groups.
///  - `translate` — the single-item path, used to repair batch failures and
///    as the `TranslatorBackend` conformance.
///
/// A third operation, `verifyBatch`, ALWAYS runs on the paid model: review is
/// never routed to a free tier.
///
/// `@Observable` so the run footer can show which model is answering and how
/// much of the prompt the provider served from cache. The HTTP calls stay
/// `nonisolated`; only routing state is main-actor bound.
@MainActor
@Observable
final class TranslationRouter: TranslatorBackend {
  /// App-wide instance: the pipeline and the footer must observe the SAME
  /// routing state, and cooldowns should outlive a single run.
  static let shared = TranslationRouter()

  // MARK: observable state

  /// Status-bar label of the model that last served a request.
  private(set) var currentModel = RoutedModel.muse.name
  /// Provider of `currentModel`.
  private(set) var currentProvider = RoutedModel.muse.provider.displayName
  /// True while the paid destination is answering.
  private(set) var isUsingPaidModel = true
  /// Candidate id → the instant it may be retried (cooldowns).
  private(set) var cooldowns: [String: Date] = [:]
  /// Last routing failure, for the status tooltip.
  private(set) var lastError: String?

  // MARK: telemetry

  /// Requests issued per model label.
  private(set) var callsByModel: [String: Int] = [:]
  /// Prompt tokens the providers reported as cache hits (0 means the prompt
  /// layout is not being cached at all).
  private(set) var cachedPromptTokens = 0
  /// Total prompt tokens reported.
  private(set) var totalPromptTokens = 0
  /// Requests refused for quota reasons.
  private(set) var quotaRefusals = 0

  // MARK: diagnostics

  /// When set, every routing decision and model call is recorded here for the
  /// row inspector. Nil during normal runs, so they pay nothing for it.
  var trace: TranslationTrace?

  // MARK: pacing

  /// Provider → instants of recent requests, for the per-minute budget.
  private var recentCalls: [RoutedModel.Provider: [Date]] = [:]

  /// Cooldown when a provider refuses for quota reasons without `Retry-After`.
  static let defaultCooldown: TimeInterval = 15 * 60
  /// Cooldown after a NON-quota failure. Without this a dead or unknown free
  /// id would be retried once per record instead of once per window.
  static let transientCooldown: TimeInterval = 5 * 60
  /// Source-character budget for one batch request; the context block is on
  /// top of it. Spent via `ContextPromptBuilder.batchCost`, so a batch is sized
  /// by its payload instead of by record count — records range from a label to
  /// a sentence, and a fixed count is either wasteful or oversized. No
  /// tokenizer: the routed models carry very large context windows, so a
  /// grapheme count is accurate enough and free.
  /// `nonisolated`: read as a default argument value by the pipeline's entry
  /// points, which are not actor-isolated.
  nonisolated static let translateSourceBudget = 10_000
  /// The explicit "Update Translations" pass re-runs ONE row per request with
  /// every target language of that row in it, so its budget is larger.
  nonisolated static let updateSourceBudget = 20_000

  // MARK: - TranslatorBackend

  nonisolated var id: BackendID { .commandcode }

  /// Records persist the ACCOUNT that produced a value, not the model id, so
  /// the editor stamp stays stable across free/paid routing.
  nonisolated var displayName: String { "Command Code" }

  /// Eligible whenever at least one candidate has a usable key.
  nonisolated func isEligible(from: String, to: String) async -> Bool {
    RoutedModel.chain.contains { $0.apiKey != nil }
  }

  /// Single-item routing entry point (repair path + backend conformance).
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
    let expectedIDs = items.map(\.id)
    var lastFailure: BackendError?

    for candidate in RoutedModel.chain {
      guard let key = candidate.apiKey else { continue }
      if let until = cooldowns[candidate.id], until > .now { continue }
      await admit(candidate.provider)
      note(candidate)
      do {
        let prompt = ContextPromptBuilder.assembleBatch(
          items: items,
          sourceLanguage: from,
          targetLanguage: to,
          sharedContext: items.first?.context)
        let reply = try await Self.call(
          candidate, apiKey: key, system: prompt.system, user: prompt.user,
          maxTokens: nil, jsonObject: false)
        record(reply, candidate: candidate)
        let outcome = validate(reply.content, items: items, candidate: candidate)
        trace?.add(TranslationTrace.Step(
          kind: .translate,
          title: "Batch of \(items.count) into \(to)",
          model: candidate.name,
          provider: candidate.provider.displayName,
          isPaid: !candidate.isFree,
          input: items.first?.context?.traceSummary ?? "source text only",
          output: "\(outcome.values.count) accepted, \(outcome.failedIDs.count) rejected",
          isFailure: outcome.values.isEmpty))
        return outcome
      } catch {
        // Any escape from the error taxonomy still must not abort the run.
        let backendError = (error as? BackendError) ?? .network(error.localizedDescription)
        lastFailure = backendError
        cool(candidate, error: backendError)
        trace?.add(TranslationTrace.Step(
          kind: .skip,
          title: "\(candidate.name) unavailable",
          model: candidate.name,
          provider: candidate.provider.displayName,
          isPaid: !candidate.isFree,
          output: backendError.localizedDescription,
          isFailure: true))
        continue
      }
    }
    return BatchOutcome(
      failedIDs: expectedIDs,
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

  // MARK: - paid verification gate

  /// Reviews candidates with the PAID model and returns corrections only.
  ///
  /// The candidate is included in the prompt, which is the whole point: the
  /// model judges a concrete translation instead of re-translating blind. On
  /// any failure this returns no corrections — an unavailable reviewer must
  /// never block or corrupt a run.
  func verifyBatch(_ items: [GateItem]) async -> [Int: String] {
    guard !items.isEmpty else { return [:] }
    let muse = RoutedModel.muse
    guard let key = muse.apiKey else { return [:] }
    await admit(muse.provider)
    note(muse)

    let rows = items.map { item -> [String: String] in
      var row = ["id": String(item.id), "source": item.sourceText, "candidate": item.candidate]
      if let comment = item.comment, !comment.isEmpty {
        row["comment"] = comment
      }
      return row
    }
    guard let data = try? JSONSerialization.data(
      withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes]),
      let payload = String(data: data, encoding: .utf8) else {
      return [:]
    }
    let system = """
    You are a strict software-localization reviewer. For each item you get the \
    source string and a CANDIDATE translation. Judge the candidate in the \
    context of its COMMENT.
    Reply with ONLY a JSON array. Each element is \
    {"id": <id>, "valid": <true|false>, "fix": "<corrected translation>"}.
    Mark valid=false ONLY for a real defect: wrong meaning, broken or altered \
    placeholder, wrong language, wrong grammatical agreement, or clearly \
    non-idiomatic register. Do not rewrite a correct translation to your own \
    preference — when in doubt, mark it valid and leave "fix" empty.
    """
    do {
      let reply = try await Self.call(
        muse, apiKey: key, system: system,
        user: "ITEMS (JSON)\n" + payload, maxTokens: nil, jsonObject: false)
      record(reply, candidate: muse)
      let fixes = Self.parseGate(reply.content)
      trace?.add(TranslationTrace.Step(
        kind: .gate,
        title: "Verified \(items.count) candidate(s)",
        model: muse.name,
        provider: muse.provider.displayName,
        isPaid: true,
        input: "candidate translations + source + comments",
        output: fixes.isEmpty
          ? "all accepted unchanged"
          : "\(fixes.count) correction(s)",
        isFailure: false))
      return fixes
    } catch let error as BackendError {
      cool(muse, error: error)
      trace?.add(TranslationTrace.Step(
        kind: .gate,
        title: "Gate unavailable — candidates kept as-is",
        model: muse.name,
        provider: muse.provider.displayName,
        isPaid: true,
        output: error.localizedDescription,
        isFailure: true))
      return [:]
    } catch {
      return [:]
    }
  }

  /// Pulls `{id, valid, fix}` rows out of the gate reply.
  private static func parseGate(_ raw: String) -> [Int: String] {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```") {
      text = text.replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"),
          start <= end,
          let data = String(text[start...end]).data(using: .utf8),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return [:]
    }
    var fixes: [Int: String] = [:]
    for row in rows {
      let valid = (row["valid"] as? Bool) ?? true
      guard valid == false else { continue }
      guard let id = (row["id"] as? Int) ?? (row["id"] as? NSNumber)?.intValue
        ?? (row["id"] as? String).flatMap(Int.init) else { continue }
      let fix = ((row["fix"] as? String) ?? (row["text"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !fix.isEmpty else { continue }
      fixes[id] = fix
    }
    return fixes
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
      note(candidate)
      do {
        let prompt = ContextPromptBuilder.assemble(
          sourceText: text,
          sourceLanguage: from,
          targetLanguage: to,
          context: context)
        let reply = try await Self.call(
          candidate, apiKey: key, system: prompt.system, user: prompt.user,
          maxTokens: nil, jsonObject: false)
        record(reply, candidate: candidate)
        trace?.add(TranslationTrace.Step(
          kind: .translate,
          title: "Translated one string into \(to)",
          model: candidate.name,
          provider: candidate.provider.displayName,
          isPaid: !candidate.isFree,
          input: context?.traceSummary ?? "source text only",
          output: reply.content))
        return reply.content
      } catch let error as BackendError {
        lastFailure = error
        cool(candidate, error: error)
        continue
      }
    }
    throw lastFailure ?? BackendError.notConfigured(
      "No translation model is available: no provider key is configured and every free tier is cooling down.")
  }

  // MARK: - shared plumbing

  private static func call(
    _ candidate: RoutedModel,
    apiKey: String,
    system: String,
    user: String,
    maxTokens: Int?,
    jsonObject: Bool
  ) async throws -> ChatReply {
    let client = OpenAIChatClient(
      endpoint: candidate.provider.chatEndpoint,
      apiKey: apiKey,
      model: candidate.model,
      headers: candidate.headers)
    return try await client.complete(
      system: system, user: user, maxTokens: maxTokens, jsonObject: jsonObject)
  }

  private func note(_ candidate: RoutedModel) {
    currentModel = candidate.name
    currentProvider = candidate.provider.displayName
    isUsingPaidModel = !candidate.isFree
    callsByModel[candidate.name, default: 0] += 1
  }

  private func record(_ reply: ChatReply, candidate: RoutedModel) {
    if let prompt = reply.promptTokens { totalPromptTokens += prompt }
    if let cached = reply.cachedTokens { cachedPromptTokens += cached }
  }

  private func cool(_ candidate: RoutedModel, error: BackendError) {
    let cooldown = error.suggestedCooldown
      ?? (error.isQuotaExhausted ? Self.defaultCooldown : Self.transientCooldown)
    cooldowns[candidate.id] = Date.now.addingTimeInterval(cooldown)
    if error.isQuotaExhausted { quotaRefusals += 1 }
    lastError = "\(candidate.name): \(error.localizedDescription)"
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

  // MARK: - status

  /// One-line status for the run footer.
  var statusText: String { currentModel }

  /// Cache/utilization readout. A cached-token share near zero across a run
  /// means the provider is not caching the stable prefix (or the prompt
  /// layout regressed) — this is the number to watch.
  var telemetrySummary: String {
    let requests = callsByModel.values.reduce(0, +)
    let share = totalPromptTokens > 0
      ? Int((Double(cachedPromptTokens) / Double(totalPromptTokens)) * 100)
      : 0
    return "\(requests) request(s) · \(cachedPromptTokens)/\(totalPromptTokens) prompt tokens cached (\(share)%) · \(quotaRefusals) quota refusal(s)"
  }

  /// Clears quota cooldowns and telemetry (a manual "try free tiers again").
  func resetCooldowns() {
    cooldowns.removeAll()
    callsByModel.removeAll()
    cachedPromptTokens = 0
    totalPromptTokens = 0
    quotaRefusals = 0
    lastError = nil
  }
}
