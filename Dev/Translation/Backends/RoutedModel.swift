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
  static let muse = RoutedModel(
    provider: .commandCode,
    model: "meta/muse-spark-1.3",
    name: "Muse Spark 1.3",
    isFree: false)

  /// Routing order, best-quality-first, paid destination last.
  ///
  /// Smoke-tested live 2026-09-10 with a one-string translation:
  /// `[ok]` answered correctly, `[~]` transient provider error (429/503 —
  /// worth retrying later), `[x]` hard-unavailable right now. Anything that
  /// fails is cooled down by the router and skipped, so a dead candidate
  /// costs one call per cooldown window, not one per record.
  static let chain: [RoutedModel] = [
    // OpenCode Zen free tier. Currently unreachable: the free ids answer
    // "Model is unavailable" until the workspace enables them, and the Go
    // tier needs credits or the contributor data-policy opt-in. Kept at the
    // head because these are the only free ids in Muse's own model family.
    RoutedModel(provider: .openCode, model: "deepseek-v4-flash-free",
                name: "DeepSeek V4 Flash (free)", isFree: true),           // [x]
    RoutedModel(provider: .openCode, model: "muse-spark-1.3-contributor-free",
                name: "Muse Spark 1.3 (free)", isFree: true),              // [x]
    RoutedModel(provider: .openCode, model: "muse-spark-1.2-contributor-free",
                name: "Muse Spark 1.2 (free)", isFree: true),              // [x]
    // Command Code free ids — same provider and key as the paid destination.
    RoutedModel(provider: .commandCode, model: "meituan/LongCat-2.0:free",
                name: "LongCat 2.0 (free)", isFree: true),                 // [ok]
    RoutedModel(provider: .commandCode, model: "inclusionai/ling-3.0-flash-sante:free",
                name: "Ling 3.0 Flash Sante (free)", isFree: true),        // [ok]
    RoutedModel(provider: .commandCode, model: "poolside/laguna-s-2.1-free",
                name: "Laguna S 2.1 (free)", isFree: true),                // [~] 503
    // OpenRouter free ids.
    RoutedModel(provider: .openRouter, model: "nvidia/nemotron-3-super-120b-a12b:free",
                name: "Nemotron 3 Super (free)", isFree: true),            // [ok]
    RoutedModel(provider: .openRouter, model: "nex-agi/nex-n2.5-pro:free",
                name: "Nex N2.5 Pro (free)", isFree: true),                // [ok]
    RoutedModel(provider: .openRouter, model: "google/gemma-4-31b-it:free",
                name: "Gemma 4 31B (free)", isFree: true),                 // [~] 429
    // Paid destination.
    muse,                                                                  // [ok]
  ]

  /// Just the free tiers, in order (the router's preferred path).
  static var freeChain: [RoutedModel] { chain.filter(\.isFree) }
}
