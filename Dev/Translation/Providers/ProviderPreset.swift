//
//  ProviderPreset.swift
//  Dev
//

import Foundation

// MARK: - ProviderPreset

/// A model provider the Settings picker offers: where its OpenAI-compatible API
/// lives, which wire it speaks, where its key comes from, and the models worth
/// starting with for translation.
///
/// The list follows the providers the Hermes agent ships (its API-key profiles,
/// base URLs and key variables), plus OpenAI, Mistral, Groq, Together, local Ollama
/// and a Custom entry.
/// Every provider is spoken to over an OpenAI wire: Anthropic, Gemini and MiniMax
/// through their OpenAI-compatible endpoints. OpenCode is the exception: it serves
/// some models only on the Responses or Anthropic Messages wire (`modelWires`).
nonisolated struct ProviderPreset: Identifiable, Sendable, Hashable {
  enum Group: String, Sendable, CaseIterable {
    case recommended = "Recommended"
    case popular = "Popular"
    case more = "More Providers"
    case local = "On This Mac"
    case custom = "Custom"
  }

  let id: String
  let name: String
  let group: Group
  /// The API root; requests go to `<baseURL>/chat/completions` or `/responses`.
  /// Empty when the user has to supply it (Custom, Azure, Tencent).
  let baseURL: String
  let wire: Wire
  /// Models served on another wire than `wire`, for a provider that routes each
  /// model to its own protocol; the first match wins.
  var modelWires: [ModelWire] = []
  /// Environment variables that may hold the key, in Hermes' order. Read from the
  /// process environment as a fallback and by "Import Keys".
  let keyNames: [String]
  /// False for local servers, which take any key or none.
  var needsKey = true
  /// Where to create a key.
  var keysURL: String? = nil
  /// One line shown under the picker: what the provider is good for, or its catch.
  var note: String? = nil
  /// Extra headers the provider asks clients to send.
  var headers: [String: String] = [:]
  /// Client-side pacing; local servers are not paced.
  var requestsPerMinute = 30

  /// The models worth starting with, researched per provider (`ModelRecommendations`).
  var recommendations: [ModelRecommendation] { ModelRecommendations.forPreset(id) }

  /// The wire `model` is spoken to on.
  func wire(for model: String) -> Wire {
    modelWires.first { $0.matches(model) }?.wire ?? wire
  }

  /// The user types the base URL for this provider.
  var asksForBaseURL: Bool { baseURL.isEmpty || group == .local }
}

/// The wire one model, or a family of them, is served on.
nonisolated struct ModelWire: Sendable, Hashable {
  /// A model id, or an id prefix ending in `*`.
  let pattern: String
  let wire: Wire

  init(_ pattern: String, _ wire: Wire) {
    self.pattern = pattern
    self.wire = wire
  }

  func matches(_ model: String) -> Bool {
    pattern.hasSuffix("*") ? model.hasPrefix(pattern.dropLast()) : model == pattern
  }
}

/// A model worth starting with, and what it costs.
nonisolated struct ModelRecommendation: Sendable, Hashable, Identifiable {
  enum Role: String, Sendable {
    case best = "Best"
    case value = "Value"
    case free = "Free"
  }

  let model: String
  let role: Role
  /// USD per million tokens; nil when unknown. Zero for a free model.
  var input: Double? = nil
  var output: Double? = nil
  let reason: String

  var id: String { model }

  /// "$0.10 / $0.50 per 1M tokens", "Free", or nil when the price is unknown.
  var priceLabel: String? {
    if role == .free || (input == 0 && output == 0) { return "Free" }
    guard let input, let output else { return nil }
    let style = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(2...3))
    return "\(input.formatted(style)) in / \(output.formatted(style)) out per 1M tokens"
  }
}

// MARK: - The presets

nonisolated extension ProviderPreset {
  static func preset(id: String) -> ProviderPreset? {
    all.first { $0.id == id }
  }

  /// OpenCode asks its clients to name themselves and to keep one session id per
  /// process for routing and prompt-cache affinity.
  private static let openCodeHeaders = ["x-opencode-session": RoutedModel.sessionID]

  /// OpenCode serves each model on its own upstream's protocol and refuses the
  /// others ("ModelProtocolUnsupported"), so every model not on the chat wire is
  /// listed, after the endpoint tables in opencode.ai/docs/zen and /docs/go.
  /// Gemini (Google's own protocol) and Jev are not spoken here.
  private static let openCodeZenWires: [ModelWire] = [
    .init("gpt-*", .responses), .init("grok-*", .responses), .init("muse-*", .responses),
    .init("claude-*", .anthropicMessages),
    .init("qwen3.8-max", .chatCompletions), .init("qwen*", .anthropicMessages),
  ]
  private static let openCodeGoWires: [ModelWire] = [
    .init("gpt-*", .responses), .init("grok-*", .responses), .init("muse-*", .responses),
    .init("claude-*", .anthropicMessages), .init("qwen*", .anthropicMessages),
    .init("minimax-m3", .anthropicMessages),
  ]

  static let all: [ProviderPreset] = recommended + popular + more + local + [custom]

  static let recommended: [ProviderPreset] = [
    ProviderPreset(
      id: "commandcode", name: "CommandCode", group: .recommended,
      baseURL: "https://api.commandcode.ai/provider/v1", wire: .chatCompletions,
      keyNames: ["COMMANDCODE_API_KEY"], keysURL: "https://commandcode.ai/settings/keys",
      note: "Full-quality models at upstream prices: the best default. API access needs a paid plan (Provider, $15/mo)."),
    ProviderPreset(
      id: "openrouter", name: "OpenRouter", group: .recommended,
      baseURL: "https://openrouter.ai/api/v1", wire: .chatCompletions,
      keyNames: ["OPENROUTER_API_KEY"], keysURL: "https://openrouter.ai/keys",
      note: "One key for hundreds of models. Free models: 20 requests/min, 50/day (1000/day after buying credits), and may log prompts."),
    ProviderPreset(
      id: "opencode-zen", name: "OpenCode Zen", group: .recommended,
      baseURL: "https://opencode.ai/zen/v1", wire: .chatCompletions, modelWires: openCodeZenWires,
      keyNames: ["OPENCODE_ZEN_API_KEY", "OPENCODE_API_KEY"], keysURL: "https://opencode.ai/auth",
      note: "Free preview models, but open models run on heavily quantized hosts, so quality drops: review more.",
      headers: openCodeHeaders),
    ProviderPreset(
      id: "opencode-go", name: "OpenCode Go", group: .recommended,
      baseURL: "https://opencode.ai/zen/go/v1", wire: .chatCompletions, modelWires: openCodeGoWires,
      keyNames: ["OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"], keysURL: "https://opencode.ai/auth",
      note: "A flat subscription with free models. Open models run on heavily quantized hosts, so quality drops: review more.",
      headers: openCodeHeaders),
  ]

  static let popular: [ProviderPreset] = [
    ProviderPreset(
      id: "openai", name: "OpenAI", group: .popular,
      baseURL: "https://api.openai.com/v1", wire: .responses,
      keyNames: ["OPENAI_API_KEY"], keysURL: "https://platform.openai.com/api-keys"),
    ProviderPreset(
      id: "anthropic", name: "Anthropic", group: .popular,
      baseURL: "https://api.anthropic.com/v1", wire: .chatCompletions,
      keyNames: ["ANTHROPIC_API_KEY"], keysURL: "https://platform.claude.com/settings/keys",
      note: "Through Anthropic's OpenAI-compatible endpoint (no prompt caching there)."),
    ProviderPreset(
      id: "gemini", name: "Google Gemini", group: .popular,
      baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", wire: .chatCompletions,
      keyNames: ["GEMINI_API_KEY", "GOOGLE_API_KEY"], keysURL: "https://aistudio.google.com/apikey",
      note: "The free tier covers Flash, but Google may use free-tier prompts to improve its products."),
    ProviderPreset(
      id: "deepseek", name: "DeepSeek", group: .popular,
      baseURL: "https://api.deepseek.com", wire: .chatCompletions,
      keyNames: ["DEEPSEEK_API_KEY"], keysURL: "https://platform.deepseek.com/api_keys",
      note: "First-party, full-precision DeepSeek. Prices double at peak hours; the service runs in China."),
    ProviderPreset(
      id: "xai", name: "xAI", group: .popular,
      baseURL: "https://api.x.ai/v1", wire: .responses,
      keyNames: ["XAI_API_KEY"], keysURL: "https://console.x.ai/",
      note: "Responses are stored for 30 days on xAI's side."),
    ProviderPreset(
      id: "meta-ai", name: "Meta Model API", group: .popular,
      baseURL: "https://api.meta.ai/v1", wire: .chatCompletions,
      keyNames: ["META_MODEL_API_KEY", "META_API_KEY", "MODEL_API_KEY"],
      keysURL: "https://dev.meta.ai/platform",
      note: "Muse Spark. The cheap \"contributor\" tier lets Meta train on your strings."),
  ]

  static let more: [ProviderPreset] = [
    ProviderPreset(
      id: "actual", name: "Actual Computer", group: .more,
      baseURL: "https://api.actual.inc/v1", wire: .chatCompletions,
      keyNames: ["ACTUAL_API_KEY"], keysURL: "https://actual.inc"),
    ProviderPreset(
      id: "ai-gateway", name: "Vercel AI Gateway", group: .more,
      baseURL: "https://ai-gateway.vercel.sh/v1", wire: .chatCompletions,
      keyNames: ["AI_GATEWAY_API_KEY"], keysURL: "https://vercel.com/ai-gateway"),
    ProviderPreset(
      id: "alibaba", name: "Alibaba Cloud (Qwen)", group: .more,
      baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", wire: .chatCompletions,
      keyNames: ["DASHSCOPE_API_KEY"], keysURL: "https://modelstudio.console.alibabacloud.com/"),
    ProviderPreset(
      id: "alibaba-cn", name: "Alibaba Cloud (China)", group: .more,
      baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", wire: .chatCompletions,
      keyNames: ["DASHSCOPE_API_KEY"], keysURL: "https://modelstudio.console.alibabacloud.com/"),
    ProviderPreset(
      id: "alibaba-token-plan", name: "Alibaba Cloud Token Plan", group: .more,
      baseURL: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
      wire: .chatCompletions, keyNames: ["ALIBABA_TOKEN_PLAN_API_KEY"],
      keysURL: "https://help.aliyun.com/zh/model-studio/"),
    ProviderPreset(
      id: "alibaba-coding-plan", name: "Alibaba Cloud Coding Plan", group: .more,
      baseURL: "https://coding-intl.dashscope.aliyuncs.com/v1", wire: .chatCompletions,
      keyNames: ["ALIBABA_CODING_PLAN_API_KEY", "DASHSCOPE_API_KEY"],
      keysURL: "https://help.aliyun.com/zh/model-studio/"),
    ProviderPreset(
      id: "arcee", name: "Arcee", group: .more,
      baseURL: "https://api.arcee.ai/api/v1", wire: .chatCompletions,
      keyNames: ["ARCEEAI_API_KEY"]),
    ProviderPreset(
      id: "azure-foundry", name: "Azure AI Foundry", group: .more,
      baseURL: "", wire: .chatCompletions,
      keyNames: ["AZURE_FOUNDRY_API_KEY"], keysURL: "https://ai.azure.com/",
      note: "Paste your deployment's OpenAI-compatible endpoint as the base URL."),
    ProviderPreset(
      id: "deepinfra", name: "DeepInfra", group: .more,
      baseURL: "https://api.deepinfra.com/v1/openai", wire: .chatCompletions,
      keyNames: ["DEEPINFRA_API_KEY"], keysURL: "https://deepinfra.com/dash/api_keys",
      note: "Shows each model's precision; avoid fp4 builds for translation."),
    ProviderPreset(
      id: "fireworks", name: "Fireworks AI", group: .more,
      baseURL: "https://api.fireworks.ai/inference/v1", wire: .chatCompletions,
      keyNames: ["FIREWORKS_API_KEY"], keysURL: "https://app.fireworks.ai/settings/users/api-keys"),
    ProviderPreset(
      id: "groq", name: "Groq", group: .more,
      baseURL: "https://api.groq.com/openai/v1", wire: .chatCompletions,
      keyNames: ["GROQ_API_KEY"], keysURL: "https://console.groq.com/keys",
      note: "Very fast, with a small choice of models."),
    ProviderPreset(
      id: "gmi", name: "GMI Cloud", group: .more,
      baseURL: "https://api.gmi-serving.com/v1", wire: .chatCompletions,
      keyNames: ["GMI_API_KEY"], keysURL: "https://www.gmicloud.ai/"),
    ProviderPreset(
      id: "huggingface", name: "Hugging Face", group: .more,
      baseURL: "https://router.huggingface.co/v1", wire: .chatCompletions,
      keyNames: ["HF_TOKEN"], keysURL: "https://huggingface.co/settings/tokens"),
    ProviderPreset(
      id: "kilocode", name: "Kilo Code Gateway", group: .more,
      baseURL: "https://api.kilo.ai/api/gateway", wire: .chatCompletions,
      keyNames: ["KILOCODE_API_KEY"]),
    ProviderPreset(
      id: "kimi-coding", name: "Moonshot (Kimi)", group: .more,
      baseURL: "https://api.moonshot.ai/v1", wire: .chatCompletions,
      keyNames: ["KIMI_API_KEY", "MOONSHOT_API_KEY"],
      keysURL: "https://platform.moonshot.ai/console/api-keys",
      note: "kimi-k3 thinks at maximum effort by default, which costs output tokens."),
    ProviderPreset(
      id: "kimi-coding-cn", name: "Moonshot (China)", group: .more,
      baseURL: "https://api.moonshot.cn/v1", wire: .chatCompletions,
      keyNames: ["KIMI_CN_API_KEY"]),
    ProviderPreset(
      id: "minimax", name: "MiniMax", group: .more,
      baseURL: "https://api.minimax.io/v1", wire: .chatCompletions,
      keyNames: ["MINIMAX_API_KEY"], keysURL: "https://platform.minimax.io",
      note: "Replies may start with the model's <think> reasoning before the answer."),
    ProviderPreset(
      id: "minimax-cn", name: "MiniMax (China)", group: .more,
      baseURL: "https://api.minimaxi.com/v1", wire: .chatCompletions,
      keyNames: ["MINIMAX_CN_API_KEY"]),
    ProviderPreset(
      id: "mistral", name: "Mistral", group: .more,
      baseURL: "https://api.mistral.ai/v1", wire: .chatCompletions,
      keyNames: ["MISTRAL_API_KEY"], keysURL: "https://console.mistral.ai/api-keys",
      note: "Strong on European languages."),
    ProviderPreset(
      id: "nebius-token-factory", name: "Nebius Token Factory", group: .more,
      baseURL: "https://api.tokenfactory.nebius.com/v1", wire: .chatCompletions,
      keyNames: ["NEBIUS_API_KEY"], keysURL: "https://tokenfactory.nebius.com/"),
    ProviderPreset(
      id: "novita", name: "NovitaAI", group: .more,
      baseURL: "https://api.novita.ai/openai/v1", wire: .chatCompletions,
      keyNames: ["NOVITA_API_KEY"], keysURL: "https://novita.ai/settings/key-management"),
    ProviderPreset(
      id: "nvidia", name: "NVIDIA NIM", group: .more,
      baseURL: "https://integrate.api.nvidia.com/v1", wire: .chatCompletions,
      keyNames: ["NVIDIA_API_KEY"], keysURL: "https://build.nvidia.com/"),
    ProviderPreset(
      id: "ollama-cloud", name: "Ollama Cloud", group: .more,
      baseURL: "https://ollama.com/v1", wire: .chatCompletions,
      keyNames: ["OLLAMA_API_KEY"], keysURL: "https://ollama.com/settings/keys",
      note: "Zero data retention; billed from plan credits, cheaper off-peak."),
    ProviderPreset(
      id: "router", name: "Ramp Router", group: .more,
      baseURL: "https://api.router.com/v1", wire: .responses,
      keyNames: ["RAMP_ROUTER_API_KEY", "ROUTER_API_KEY"], keysURL: "https://app.router.com/keys"),
    ProviderPreset(
      id: "stepfun", name: "StepFun", group: .more,
      baseURL: "https://api.stepfun.ai/step_plan/v1", wire: .chatCompletions,
      keyNames: ["STEPFUN_API_KEY"]),
    ProviderPreset(
      id: "tencent-tokenhub", name: "Tencent TokenHub", group: .more,
      baseURL: "", wire: .chatCompletions, keyNames: ["TOKENHUB_API_KEY"],
      note: "Paste your TokenHub endpoint as the base URL."),
    ProviderPreset(
      id: "together", name: "Together AI", group: .more,
      baseURL: "https://api.together.xyz/v1", wire: .chatCompletions,
      keyNames: ["TOGETHER_API_KEY"], keysURL: "https://api.together.ai/settings/api-keys"),
    ProviderPreset(
      id: "upstage", name: "Upstage Solar", group: .more,
      baseURL: "https://api.upstage.ai/v1", wire: .chatCompletions,
      keyNames: ["UPSTAGE_API_KEY"], keysURL: "https://console.upstage.ai/api-keys"),
    ProviderPreset(
      id: "xiaomi", name: "Xiaomi MiMo", group: .more,
      baseURL: "https://api.xiaomimimo.com/v1", wire: .chatCompletions,
      keyNames: ["XIAOMI_API_KEY"]),
    ProviderPreset(
      id: "zai", name: "Z.AI (GLM)", group: .more,
      baseURL: "https://api.z.ai/api/paas/v4", wire: .chatCompletions,
      keyNames: ["GLM_API_KEY", "ZAI_API_KEY", "Z_AI_API_KEY", "ZHIPU_API_KEY"],
      keysURL: "https://z.ai/manage-apikey/apikey-list",
      note: "GLM reasons by default, which costs output tokens."),
  ]

  static let local: [ProviderPreset] = [
    ProviderPreset(
      id: "ollama", name: "Ollama", group: .local,
      baseURL: "http://localhost:11434/v1", wire: .chatCompletions,
      keyNames: [], needsKey: false, keysURL: "https://ollama.com/download",
      note: "Free and private. Pull a model first (ollama pull gemma4:12b) and raise its context length for long batches.",
      requestsPerMinute: 600),
    ProviderPreset(
      id: "lmstudio", name: "LM Studio", group: .local,
      baseURL: "http://localhost:1234/v1", wire: .chatCompletions,
      keyNames: ["LM_API_KEY"], needsKey: false, keysURL: "https://lmstudio.ai/",
      note: "Free and private. Start the server in the Developer tab; prefer MLX builds and set a long context.",
      requestsPerMinute: 600),
  ]

  static let custom = ProviderPreset(
    id: "custom", name: "Custom (OpenAI-compatible)", group: .custom,
    baseURL: "", wire: .chatCompletions, keyNames: [], needsKey: false,
    note: "Any server with an OpenAI-compatible /chat/completions or /responses endpoint.")
}
