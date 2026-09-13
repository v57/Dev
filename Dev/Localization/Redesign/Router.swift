//
//  Router.swift
//  Dev
//
//  Created by Dmitry on 14.09.26.
//
//  The Muse client — moved out of Runner.swift, which keeps the run machinery. A
//  client is not a run: the transport and the two pacing rules live together here.
//
//  What this client deliberately does NOT do is parse the reply. A reply's shape is
//  the payload's shape (10.15), and the party that asked the question is the party
//  that knows what it asked for, so the answer is read where it is used: `send` leaves
//  the raw text in `lastRawReply` and `Validator.answers` — the executor's parse, in
//  Runner.swift — turns it into per-id text. The parse that used to live here keyed on
//  `text as? String`, which silently dropped a PLURAL answer (an object of categories
//  nested under `text`) and with it the item's whole answer, so the second parser was
//  not a convenience, it was a second, quietly wrong answer key.
//
//  Real implementation, unlike the rest of this folder's stubs. Semantics are in
//  "Design notes.md" 5.2 and the rules at the top of that file. The wire details and
//  the keychain lookup follow Translation/Backends/CommandCodeTranslator.swift,
//  CommandCodeKeychain.swift and OpenAIChatClient.swift; nothing here calls
//  TranslationRouter or reaches into its chain, because the redesign has no chain to
//  walk.
//

import Foundation
import Observation

extension Translation {
  /// The one model client. Every call in the redesign goes to Muse: no free tier, no
  /// fallback ladder, no second opinion. What survives from the current
  /// implementation's routing work is admission and cooldown — neither was ever
  /// about model choice, both are about not burning a batch on a provider that is
  /// known to be down.
  ///
  /// `@Observable` so the run footer can show which model is answering, how many
  /// requests went out and how much of the prompt the provider served from cache
  /// (5.7). The HTTP call itself is off the actor; only the routing state lives on the
  /// main actor, which is also why waiting for a budget suspends instead of blocking.
  @Observable @MainActor class Router {
    /// Muse, the only candidate there is.
    ///
    /// `cooldownUntil` is part of the declared shape and says when a PARKED candidate
    /// may be retried. `next()` answers nil rather than handing out a parked candidate,
    /// so a candidate that was handed out is always usable and carries nil here; the
    /// instant itself is read from the router's `cooldownUntil`.
    struct Candidate: Identifiable {
      let id: String
      let model: String
      var cooldownUntil: Date?
    }

    /// The single candidate the redesign ever calls. The model id comes from
    /// `CommandCodeTranslator` — the same constant its own client names — so the
    /// transport and the router cannot end up speaking to two different models.
    static let defaultMuse = Candidate(
      id: "commandcode:\(CommandCodeTranslator.model)",
      model: CommandCodeTranslator.model)

    let muse: Candidate

    /// The one candidate, which is the whole point: there is nothing to choose between.
    init(muse: Candidate) {
      self.muse = muse
    }

    /// Muse on Command Code — what the app builds unless something hands in a candidate
    /// of its own.
    init() {
      muse = Self.defaultMuse
    }

    // MARK: - cooldown

    /// Candidate id → the instant it may be tried again. Keyed rather than carried on
    /// the candidate because `muse` is a `let`: a candidate says WHICH model to call,
    /// a park says WHEN, and only the second one moves.
    private(set) var cooldowns: [String: Date] = [:]

    /// How long a quota answer parks Muse when the provider named no `Retry-After`. A
    /// spent quota is not a blip, so it waits longer than a transport failure.
    static let quotaCooldown: TimeInterval = 15 * 60

    /// The fixed window everything else parks Muse for. Without it a provider that is
    /// down costs one call per RECORD instead of one call per window.
    static let cooldownWindow: TimeInterval = 5 * 60

    /// Muse, unless it is cooling down — in which case a run WAITS. There is nothing
    /// to fall back to, which is the point.
    ///
    /// A run that gets nil here reads `cooldownUntil`, sleeps for it and asks again:
    /// nothing else is going to answer.
    func next() -> Candidate? {
      guard !isCoolingDown else { return nil }
      return Candidate(id: muse.id, model: muse.model, cooldownUntil: nil)
    }

    /// True while Muse is parked.
    var isCoolingDown: Bool { cooldownUntil != nil }

    /// The instant Muse may be tried again, or nil when it is not parked. The runner
    /// waits for this instant — `next()` has no second candidate to hand back.
    var cooldownUntil: Date? {
      guard let until = cooldowns[muse.id], until > .now else { return nil }
      return until
    }

    /// A quota answer parks Muse until its `Retry-After`; anything else parks it for a
    /// fixed window. One dead provider then costs one call per window, not one per
    /// record.
    ///
    /// `retryAfter` is the provider's own number whenever it named one, and the caller
    /// classifies its own failure: `BackendError` knows whether an answer was a quota
    /// refusal, so it hands in `quotaCooldown` for a headerless 429. From nil alone this
    /// method cannot tell the two apart, and a non-positive number counts as "named
    /// none" — a park of zero seconds is not a park.
    func coolDown(_ candidate: Candidate, retryAfter: TimeInterval?) {
      var window = Self.cooldownWindow
      if let retryAfter, retryAfter > 0 {
        window = retryAfter
      }
      cooldowns[candidate.id] = Date.now.addingTimeInterval(window)
    }

    /// The manual "try Muse again". The status bar needs it when a stale park is the
    /// only thing holding a run back and the user knows the provider is up.
    func clearCooldowns() {
      cooldowns.removeAll()
    }

    // MARK: - admission

    /// Command Code's conservative per-minute request budget — the same number as
    /// `RoutedModel.Provider.commandCode.requestsPerMinute`, kept here so the redesign's
    /// router never reaches into the chain table for a provider figure.
    ///
    /// Low deliberately, as it was there: a burst that exhausts the budget returns 429s
    /// for every later record, which costs far more than waiting a few seconds up front.
    static let requestsPerMinute = 60

    /// Candidate id → instants of recent requests, for the per-minute budget.
    private var recentCalls: [String: [Date]] = [:]

    /// Admission: suspends while the provider's requests-per-minute budget is full,
    /// rather than failing the batch. `Task.sleep` suspends without blocking the actor,
    /// so a waiting run still paints — and a cancel interrupts the wait instead of
    /// being swallowed by it.
    func admit(_ candidate: Candidate) async throws {
      while true {
        try Task.checkCancellation()
        let now = Date.now
        var times = (recentCalls[candidate.id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard times.count >= Self.requestsPerMinute else {
          times.append(now)
          recentCalls[candidate.id] = times
          return
        }
        let oldest = times.min() ?? now
        recentCalls[candidate.id] = times
        let wait = 60 - now.timeIntervalSince(oldest) + 0.05
        guard wait > 0 else { continue }
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      }
    }

    // MARK: - telemetry

    /// Requests issued through this client.
    private(set) var requests = 0
    private(set) var promptTokens = 0
    private(set) var completionTokens = 0
    /// Tokens the provider served from its prompt cache. A flat zero across a run says
    /// the prompt layout is not cacheable, which is a bug in the prompt rather than a
    /// property of the model.
    private(set) var cachedTokens = 0

    /// The last answer exactly as the provider sent it, and the only way a reply
    /// leaves this client: nothing here parses it, and the caller turns the text into
    /// per-id answers itself (`Validator.answers`). Truncation is a property of the RAW
    /// text — the model stopping mid-array — so the caller needs the text
    /// `Validator.isTruncated` asks about, not a dictionary built from it. Nil after a
    /// failed call.
    private(set) var lastRawReply: String?

    /// Zeroes the request and token counts. These are per-run numbers the run's tally
    /// reads; the cooldowns are deliberately NOT touched here.
    func resetTelemetry() {
      requests = 0
      promptTokens = 0
      completionTokens = 0
      cachedTokens = 0
    }

    /// Adds one reply's usage. The run's tally cannot count usage itself — `send`
    /// answers with values, not with usage — so the numbers are kept where the reply is
    /// decoded.
    private func settle(_ reply: ChatReply) {
      requests += 1
      if let prompt = reply.promptTokens { promptTokens += prompt }
      if let completion = reply.completionTokens { completionTokens += completion }
      if let cached = reply.cachedTokens { cachedTokens += cached }
    }

    // MARK: - the request

    /// One request, through Muse and nothing else. Parses nothing and answers nothing:
    /// the reply is left in `lastRawReply` for the caller to read, because only the
    /// caller knows what it asked for. What the model answered — including the ids it
    /// never mentioned — is the validator's business, not an error here.
    ///
    /// The park lives on this method's failure path because this is the only place that
    /// sees WHY a call failed: the provider's `Retry-After` for a quota answer, the
    /// quota window when it named none, the fixed window for anything else. The caller's
    /// next `next()` then answers nil and the run waits instead of hammering a provider
    /// that has just refused it.
    ///
    /// `request.ids` is deliberately not consulted: filtering the reply against the
    /// expected set would hide an invented id from the validator, whose job (5.3) it is
    /// to report exactly that.
    func send(
      _ request: Prompt.Request,
      using candidate: Candidate
    ) async throws {
      guard let apiKey = CommandCodeKeychain.apiKey() else {
        throw BackendError.notConfigured(
          "Muse is not configured: set \(CommandCodeKeychain.envName) in the login keychain, "
            + "the environment, or ~/.hermes/.env."
        )
      }
      let client = OpenAIChatClient(
        endpoint: CommandCodeTranslator.endpoint,
        apiKey: apiKey,
        model: candidate.model,
        timeout: CommandCodeTranslator.requestTimeout)
      do {
        let reply = try await client.complete(
          system: request.system,
          user: request.user,
          maxTokens: nil,
          jsonObject: false)
        settle(reply)
        lastRawReply = reply.content
      } catch {
        lastRawReply = nil
        // A cancelled run is not a provider condition, and a park would outlive the
        // cancel it came from.
        if Task.isCancelled {
          throw CancellationError()
        }
        // Any escape from the error taxonomy still has to park Muse rather than abort
        // the run.
        let backendError = (error as? BackendError) ?? .network(error.localizedDescription)
        coolDown(candidate, retryAfter: Self.cooldown(for: backendError))
        throw backendError
      }
    }

    /// The park a failure earns, from `BackendError`'s own taxonomy: the provider's
    /// `Retry-After` when it named one, the longer quota window when a quota answer
    /// named none, and the fixed window (nil here) for everything else.
    private static func cooldown(for error: BackendError) -> TimeInterval? {
      error.suggestedCooldown ?? (error.isQuotaExhausted ? quotaCooldown : nil)
    }

    // MARK: - eligibility

    /// Is Muse usable at all (configured, not cooling down)? Asked before a run starts,
    /// so an unconfigured app fails at the button and not per batch.
    ///
    /// Its two halves are readable on their own — `isConfigured` and `isCoolingDown` —
    /// because they are different problems with different remedies: one is a missing
    /// credential, the other is a wait, and only the caller can word that.
    var isEligible: Bool { isConfigured && !isCoolingDown }

    /// True when the Command Code key is present in the login keychain, the environment
    /// or ~/.hermes/.env. Muse has no second credential and no second provider, so this
    /// is the app's only "can it translate at all" question — checked here rather than
    /// per batch.
    var isConfigured: Bool { CommandCodeKeychain.apiKey() != nil }
  }
}
