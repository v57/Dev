//
//  RoutedModel.swift
//  Dev
//

import Foundation

// MARK: - RoutedModel

/// One model the translation router may call.
///
/// The ORDER of `RoutedModel.chain` IS the routing policy: free tiers first,
/// the paid destination last. Editing the chain is the only change needed to
/// add, drop or reorder a provider.
///
/// Verified live on 2026-09-10 against each provider's `/models` endpoint —
/// free ids drift, so re-check the listing when a candidate starts 404ing.
nonisolated struct RoutedModel: Sendable, Identifiable {
  /// Hosted provider. All three speak OpenAI-compatible chat completions.
  enum Provider: String, Sendable, CaseIterable {
    case openCode
    case commandCode
    case openRouter

    /// Full chat-completions URL.
    var chatEndpoint: URL {
      switch self {
      case .openCode:
        return URL(string: "https://opencode.ai/zen/v1/chat/completions")!
      case .commandCode:
        return URL(string: "https://api.commandcode.ai/provider/v1/chat/completions")!
      case .openRouter:
        return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
      }
    }

    /// Environment-variable name / keychain account holding the API key.
    var keyName: String {
      switch self {
      case .openCode: return "OPENCODE_GO_API_KEY"
      case .commandCode: return "COMMANDCODE_API_KEY"
      case .openRouter: return "OPENROUTER_API_KEY"
      }
    }

    /// Keychain service for the login-keychain item.
    var keychainService: String {
      switch self {
      case .openCode: return "opencode"
      case .commandCode: return "commandcode"
      case .openRouter: return "openrouter"
      }
    }

    var displayName: String {
      switch self {
      case .openCode: return "OpenCode"
      case .commandCode: return "Command Code"
      case .openRouter: return "OpenRouter"
      }
    }

    /// Conservative client-side pacing budget. Kept low deliberately: a
    /// free tier exhausted by a burst returns 429s for every later record,
    /// which is far more expensive than waiting a few seconds up front.
    var requestsPerMinute: Int {
      switch self {
      case .openCode: return 30
      case .commandCode: return 60
      case .openRouter: return 20
      }
    }
  }

  let provider: Provider
  /// Provider-side model id.
  let model: String
  /// Status-bar label.
  let name: String
  /// False only for the paid destination.
  let isFree: Bool

  var id: String { "\(provider.rawValue):\(model)" }

  /// The provider key, or nil when this provider is not configured — a
  /// candidate without a key is skipped, never failed.
  var apiKey: String? {
    ProviderSecrets.value(named: provider.keyName, service: provider.keychainService)
  }

  /// Provider-specific headers.
  var headers: [String: String] {
    switch provider {
    case .openRouter:
      // OpenRouter attributes traffic by these; harmless elsewhere.
      return ["HTTP-Referer": "https://commandcode.ai", "X-Title": "Dev"]
    case .openCode, .commandCode:
      return [:]
    }
  }
}

// MARK: - The chain

nonisolated extension RoutedModel {
  /// The paid destination: the model every free tier falls back to.
  ///
  /// This is the single place the paid model is named — swap it here and the
  /// fallback, the status-bar label and the Stage-0 learn client all follow.
  ///
  /// Runs the **contributor** tier: Meta's cost-efficient variant of the same
  /// model, roughly an order of magnitude cheaper per token than the full
  /// tier. The price is the data policy — contributor prompts and outputs may
  /// be used to improve Meta's products — so this is a deliberate trade for a
  /// batch translation workload, and it is the one thing to revisit if user
  /// catalog content must never leave for training.
  static let muse = RoutedModel(
    provider: .commandCode,
    model: "meta/muse-spark-1.3-contributor",
    name: "Muse Spark 1.3 Contributor",
    isFree: false)

  /// Routing order, set by measurement rather than model family.
  ///
  /// A bake-off on this project's own catalog strings (6 UI strings × de/ja/ru,
  /// judged MQM-lite) ranked: `deepseek-v4-flash` 9.76, `meituan/LongCat-2.0`
  /// 9.56, `muse-spark-1.3` 8.63, `inclusionai/ling-3.0-flash` 6.44. Three
  /// conclusions shaped this order:
  ///
  ///  - **Muse is an availability fallback, not a quality tier.** It did not
  ///    win; it is last because it is the model we always have.
  ///  - **Provider reliability dominates model choice.** Every OpenRouter
  ///    `:free` id returned HTTP 429 on 18/18 calls at concurrency 16, so
  ///    they sit at the tail as a last resort rather than mid-chain.
  ///  - **The 8.63 belongs to the full tier, not the one we now ship.** The
  ///    bake-off ran `muse-spark-1.3`; the paid slot now names the contributor
  ///    variant, which was never scored. Re-run the bake-off before treating
  ///    the paid slot's quality as measured — the cost saving is verified, the
  ///    translation quality of the contributor tier is not.
  ///
  /// `[ok]` answered correctly, `[~]` transient failure, `[x]` hard-unavailable
  /// (2026-09-10 smoke test). A failing candidate is cooled down by the
  /// router, so a dead id costs one call per window, not one per record.
  static let chain: [RoutedModel] = [
    // Command Code free ids — same account and key as the paid fallback, and
    // the only free tier that both works and scored well.
    RoutedModel(provider: .commandCode, model: "meituan/LongCat-2.0:free",
                name: "LongCat 2.0 (free)", isFree: true),                 // [ok] 9.56
    RoutedModel(provider: .commandCode, model: "inclusionai/ling-3.0-flash-sante:free",
                name: "Ling 3.0 Flash Sante (free)", isFree: true),        // [ok] 6.44 — weakest tested
    RoutedModel(provider: .commandCode, model: "poolside/laguna-s-2.1-free",
                name: "Laguna S 2.1 (free)", isFree: true),                // [~] 503
    // OpenCode Zen free tier: Muse's own model family, currently dead until
    // the workspace enables the free ids or opts into the contributor data
    // policy. The paid slot now runs the contributor tier, so that policy is
    // effectively accepted — re-probe these two, they may be live again, and a
    // live free contributor id is strictly better than paying for it.
    RoutedModel(provider: .openCode, model: "deepseek-v4-flash-free",
                name: "DeepSeek V4 Flash (free)", isFree: true),           // [x]
    RoutedModel(provider: .openCode, model: "muse-spark-1.3-contributor-free",
                name: "Muse Spark 1.3 Contributor (free)", isFree: true),  // [x]
    // OpenRouter free ids — LAST free resort: single calls work, bulk runs
    // get 429 on every request.
    RoutedModel(provider: .openRouter, model: "nvidia/nemotron-3-super-120b-a12b:free",
                name: "Nemotron 3 Super (free)", isFree: true),            // [~] always 429 under load
    RoutedModel(provider: .openRouter, model: "nex-agi/nex-n2.5-pro:free",
                name: "Nex N2.5 Pro (free)", isFree: true),                // [~] always 429 under load
    // Paid destination — availability, not superiority. Contributor tier: the
    // score was earned by the full tier, so this slot's quality is unmeasured.
    muse,                                                                  // [ok] 8.63 (full tier)
  ]

  /// Just the free tiers, in order (the router's preferred path).
  static var freeChain: [RoutedModel] { chain.filter(\.isFree) }
}
