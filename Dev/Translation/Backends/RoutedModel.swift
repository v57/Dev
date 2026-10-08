//
//  RoutedModel.swift
//  Dev
//

import Foundation

// MARK: - RoutedModel

/// One model the translation router may call.
///
/// The ORDER of `RoutedModel.chain` IS the routing policy. One candidate
/// today — Muse on OpenCode Go — but the chain stays the single place a
/// second candidate would be ordered: the router walks it in order, skips a
/// candidate whose key is missing, and cools a failing candidate down.
///
/// Verified live on 2026-10-08 against OpenCode Go's `/models` endpoint
/// (`https://opencode.ai/zen/go/v1/models`): `muse-spark-1.3-contributor` is
/// in the listing, and it answers on the `/responses` endpoint — the
/// chat-completions endpoint refuses it with "ModelProtocolUnsupported".
nonisolated struct RoutedModel: Sendable, Identifiable {
  /// Hosted provider. OpenCode Go serves the subscription's models under
  /// the `/zen/go/v1` root; each model speaks one of the OpenAI wire
  /// protocols, picked per model by `wire`.
  enum Provider: String, Sendable, CaseIterable {
    case openCode

    /// Root of the provider's OpenAI-compatible surface.
    var baseURL: URL {
      switch self {
      case .openCode:
        return URL(string: "https://opencode.ai/zen/go/v1")!
      }
    }

    /// Environment-variable name / keychain account holding the API key.
    var keyName: String {
      switch self {
      case .openCode: return "OPENCODE_GO_API_KEY"
      }
    }

    /// Keychain service for the login-keychain item.
    var keychainService: String {
      switch self {
      case .openCode: return "opencode"
      }
    }

    var displayName: String {
      switch self {
      case .openCode: return "OpenCode Go"
      }
    }

    /// Conservative client-side pacing budget — kept so a burst cannot turn
    /// into error retries. Go's own limits are window budgets (5-hour,
    /// weekly, monthly), not per-minute figures, so this only paces.
    var requestsPerMinute: Int {
      switch self {
      case .openCode: return 30
      }
    }
  }

  let provider: Provider
  /// Which OpenAI wire protocol this model speaks. Muse answers on the
  /// Responses API (`/responses`); a future chat-completions candidate
  /// leaves this at the default.
  var wire: Wire = .chatCompletions
  /// Provider-side model id.
  let model: String
  /// Status-bar label.
  let name: String
  /// False only for a free tier. One paid candidate today.
  let isFree: Bool

  var id: String { "\(provider.rawValue):\(model)" }

  /// The full URL this model's calls go to — the provider root plus the
  /// wire protocol's path.
  var endpoint: URL { provider.baseURL.appendingPathComponent(wire.path) }

  /// The provider key, or nil when this provider is not configured — a
  /// candidate without a key is skipped, never failed.
  var apiKey: String? {
    ProviderSecrets.value(named: provider.keyName, service: provider.keychainService)
  }

  /// Provider-specific headers. OpenCode Go asks its clients to identify
  /// themselves with their own user agent and to carry a stable session id
  /// (`x-opencode-session`) for routing and prompt-cache affinity.
  var headers: [String: String] {
    switch provider {
    case .openCode:
      return [
        "User-Agent": Self.userAgent,
        "x-opencode-session": Self.sessionID,
      ]
    }
  }

  /// The name the app calls itself by on OpenCode Go's wire — its own agent
  /// name, not a generic SDK's (the Go terms ask for that).
  static let userAgent = "Dev/1.0"

  /// One session id per process, sent as `x-opencode-session` on every call.
  /// Go routes requests and optimizes prompt caching by it, so it must stay
  /// stable across a run instead of changing per request.
  static let sessionID = "ses_dev_" + UUID().uuidString.lowercased()
}

// MARK: - The chain

nonisolated extension RoutedModel {
  /// The one model every translation call runs on: Meta's Muse Spark 1.3
  /// contributor tier, served by OpenCode Go.
  ///
  /// The contributor tier is roughly an order of magnitude cheaper per token
  /// than the full tier, and the price is the data policy — contributor
  /// prompts and outputs may be used to improve Meta's products — so this
  /// is a deliberate trade for a batch translation workload, and it is the
  /// one thing to revisit if user catalog content must never leave for
  /// training.
  ///
  /// The earlier bake-off ranked the FULL tier (8.63/10); the contributor
  /// variant was never scored, so re-run the bake-off before quoting a
  /// number for this slot.
  static let muse = RoutedModel(
    provider: .openCode,
    wire: .responses,
    model: "muse-spark-1.3-contributor",
    name: "Muse Spark 1.3 Contributor",
    isFree: false)

  /// Routing order, and the only change needed to add, drop or reorder a
  /// candidate.
  ///
  /// ONE candidate today, deliberately:
  ///
  ///  - **The account moved.** The free tiers the chain used to lead with
  ///    were Command Code's own catalog (LongCat, Ling, Laguna); translation
  ///    moved to OpenCode Go with the account, where those ids do not exist.
  ///  - **A free tier saves nothing on a flat plan.** Go ships its models by
  ///    subscription — Muse included, an order of magnitude under its full
  ///    tier — so routing around it would buy quality risk for no saving.
  ///  - **One model keeps a run measurable.** Every row of a run is the same
  ///    model's output, so a quality reading of the run is a reading of one
  ///    model.
  ///
  /// A failing candidate is cooled down by the router (quota → `Retry-After`
  /// or 15 min; anything else → 5 min), so a dead id would cost one call per
  /// window rather than one per record.
  static let chain: [RoutedModel] = [muse]
}
