//
//  ModelRecommendations.swift
//  Dev
//

import Foundation

// MARK: - ModelRecommendations

/// The models each preset suggests for translating UI strings, with list prices in USD
/// per million tokens. Checked on providers' own pricing and model pages on
/// 2026-10-11 (generated from that research; prices and ids move, so the Settings
/// pane shows them as a guide and the model field stays free text).
nonisolated enum ModelRecommendations {
  /// By preset id. A regional twin (`alibaba-cn`) reads its sibling's list.
  static func forPreset(_ id: String) -> [ModelRecommendation] {
    byProvider[id] ?? byProvider[aliases[id] ?? ""] ?? []
  }

  private static let aliases = [
    "alibaba-cn": "alibaba", "kimi-coding-cn": "kimi-coding", "minimax-cn": "minimax",
  ]

  private static let byProvider: [String: [ModelRecommendation]] = [
    "commandcode": [
      .init(model: "google/gemini-3.8-flash", role: .best, input: 1.5, output: 7.5,
            reason: "Gemini leads 2026 translation evals; Google-hosted, not quantized"),
      .init(model: "deepseek/deepseek-v4.1-flash", role: .value, input: 0.15, output: 0.6,
            reason: "Matched GPT-5.4/Gemini Flash in M-GATE translation test; very cheap (off-peak price)"),
      .init(model: "inclusionai/ling-3.1-flash:free", role: .free, input: 0, output: 0,
            reason: "Free with no daily cap while it lasts; small flash model, so expect weaker quality"),
    ],
    "openrouter": [
      .init(model: "google/gemini-3.8-flash", role: .best, input: 0.75, output: 3.75,
            reason: "Strongest translation evidence; served only by Google. Promo price until 2026-12-31"),
      .init(model: "deepseek/deepseek-v4.1-flash", role: .value, input: 0.3, output: 1.2,
            reason: "Cheap and solid translator; pin provider DeepSeek to avoid fp4 hosts"),
      .init(model: "google/gemma-4-31b-it:free", role: .free, input: 0, output: 0,
            reason: "Free, served by Google AI Studio; Gemma is broadly multilingual and supports JSON mode"),
    ],
    "opencode-zen": [
      .init(model: "longcat-2.5-preview-free", role: .free, input: 0, output: 0,
            reason: "Free, zero-retention host; preview model, likely quantized, so expect weaker translations"),
      .init(model: "step-5-preview-free", role: .free, input: 0, output: 0,
            reason: "Free, zero-retention host; preview, quality may vary and it can disappear"),
    ],
    "opencode-go": [
      .init(model: "longcat-2.5-preview-free", role: .free, input: 0, output: 0,
            reason: "Free and unlimited for a limited time; zero retention, but expect lower quality"),
      .init(model: "step-5-preview-free", role: .free, input: 0, output: 0,
            reason: "Free and unlimited for a limited time; zero retention, but expect lower quality"),
    ],
    "openai": [
      .init(model: "gpt-6.1-sol", role: .best, input: 2, output: 10,
            reason: "OpenAI's current flagship tier; first-party, full quality"),
      .init(model: "gpt-6-luna", role: .value, input: 0.1, output: 0.5,
            reason: "Very cheap first-party small model; set reasoning effort none or low"),
    ],
    "anthropic": [
      .init(model: "claude-sonnet-5-5", role: .best, input: 2, output: 10,
            reason: "Claude ranks near the top of 2026 translation evals; natural phrasing"),
      .init(model: "claude-haiku-5-5", role: .value, input: 0.1, output: 0.5,
            reason: "Very cheap current Haiku; fine for short UI strings"),
    ],
    "gemini": [
      .init(model: "gemini-3.8-flash", role: .best, input: 0.75, output: 3.75,
            reason: "Best translation evidence in 2026 (Alconost index #1); price doubles in 2027"),
      .init(model: "gemini-3.1-flash-lite", role: .value, input: 0.25, output: 1.5,
            reason: "Cheap first-party Flash-Lite; good enough for short UI strings"),
      .init(model: "gemma-4-31b-it", role: .free, input: 0, output: 0,
            reason: "Gemma 4 is free of charge on the Gemini API; open model with broad language coverage"),
    ],
    "deepseek": [
      .init(model: "deepseek-v4-pro", role: .best, input: 0.66, output: 1.98,
            reason: "DeepSeek's larger model; strong multilingual quality at a low price (off-peak)"),
      .init(model: "deepseek-flash", role: .value, input: 0.15, output: 0.6,
            reason: "Tied with GPT-5.4 and Gemini Flash in a 2026 translation study; very cheap (off-peak)"),
    ],
    "meta-ai": [
      .init(model: "muse-spark-1.3", role: .best, input: 1.25, output: 4.25,
            reason: "Meta's current model; standard tier, so your data isn't used for training"),
      .init(model: "muse-spark-1.3-contributor", role: .value, input: 0.1, output: 0.2,
            reason: "Same model, very cheap, but Meta trains on your strings; 100 RPM"),
    ],
    "xai": [
      .init(model: "grok-4.7", role: .best, input: 2, output: 6,
            reason: "xAI's most capable model; first-party"),
      .init(model: "grok-4.3", role: .value, input: 1.25, output: 2.5,
            reason: "Cheaper Grok with 1M context; scored below the leaders in one translation study"),
    ],
    "zai": [
      .init(model: "glm-5.3", role: .best, input: 1.4, output: 4.4,
            reason: "Z.AI flagship; first-party, so not quantized by a reseller; strong zh/en"),
      .init(model: "glm-5.3-flash", role: .value, input: 0.15, output: 0.5,
            reason: "Cheap current GLM tier from the source"),
      .init(model: "glm-4.7-flash", role: .free, input: 0, output: 0,
            reason: "Free first-party model; older and smaller, so expect weaker quality"),
    ],
    "kimi-coding": [
      .init(model: "kimi-k3", role: .best, input: 3, output: 15,
            reason: "Moonshot flagship; first-party; set reasoning_effort low"),
      .init(model: "kimi-k2.6", role: .value, input: 0.95, output: 4,
            reason: "Cheaper Kimi; good general multilingual quality"),
    ],
    "alibaba": [
      .init(model: "qwen3.8-max", role: .best, input: 2, output: 6,
            reason: "Qwen flagship; very strong on CJK languages; first-party"),
      .init(model: "qwen3.8-flash", role: .value, input: 0.15, output: 0.47,
            reason: "Cheap current Qwen Flash, first-party"),
    ],
    "minimax": [
      .init(model: "MiniMax-M3", role: .value, input: 0.3, output: 1.2,
            reason: "Cheap first-party flagship with 1M context; strip <think> before parsing JSON"),
    ],
    "mistral": [
      .init(model: "mistral-large-4", role: .best, input: 1.36, output: 4.18,
            reason: "Mistral flagship; very good on European languages (preview)"),
      .init(model: "mistral-small-latest", role: .value, input: 0.15, output: 0.6,
            reason: "Cheap, solid for EU languages; Small 4 (2603)"),
    ],
    "groq": [
      .init(model: "qwen/qwen3.8-27b", role: .best, input: 0.8, output: 4,
            reason: "Best multilingual model on Groq (preview)"),
      .init(model: "openai/gpt-oss-120b", role: .value, input: 0.15, output: 0.6,
            reason: "Cheap and fast; translation is OK for major languages"),
    ],
    "fireworks": [
      .init(model: "accounts/fireworks/models/glm-5p3", role: .best, input: 1.4, output: 4.4,
            reason: "Top open-weight model on a reputable host"),
      .init(model: "accounts/fireworks/models/deepseek-v4p1-flash", role: .value, input: 0.3, output: 1.2,
            reason: "Cheap, solid translator on a reputable host"),
    ],
    "deepinfra": [
      .init(model: "Qwen/Qwen3.8-Max", role: .best, input: 1.65, output: 4.951,
            reason: "Qwen flagship (partner-hosted), cheaper than Alibaba Singapore"),
      .init(model: "deepseek-ai/DeepSeek-V4.1-Flash", role: .value, input: 0.2, output: 0.6,
            reason: "Cheap, fp8 (mild quantization)"),
    ],
    "together": [
      .init(model: "zai-org/GLM-5.3", role: .best, input: 1.4, output: 4.4,
            reason: "Top open-weight model on a reputable host"),
      .init(model: "deepseek-ai/DeepSeek-V4.1-Flash", role: .value, input: 0.3, output: 1.2,
            reason: "Cheap, solid translator"),
    ],
    "ollama-cloud": [
      .init(model: "glm-5.3", role: .best, input: 1.4, output: 4.4,
            reason: "Top open-weight model with zero data retention"),
      .init(model: "deepseek-v4.1-flash", role: .value, input: 0.3, output: 1.2,
            reason: "Cheap; half price off-peak ($0.15/$0.60)"),
    ],
    "ollama": [
      .init(model: "gemma4:12b", role: .free, input: 0, output: 0,
            reason: "For 16 GB Macs: ~8 GB, Gemma is trained on many languages"),
      .init(model: "qwen3.8:27b", role: .free, input: 0, output: 0,
            reason: "For 32 GB Macs: 18 GB; strongest local pick for CJK; turn thinking off"),
      .init(model: "gemma4:31b", role: .free, input: 0, output: 0,
            reason: "For 32 GB+ Macs: 19-20 GB; best local Gemma for broad language coverage"),
    ],
    "lmstudio": [
      .init(model: "google/gemma-4-12b", role: .free, input: 0, output: 0,
            reason: "For 16 GB Macs: 7.4 GB download; broad language coverage"),
      .init(model: "qwen/qwen3.8-27b", role: .free, input: 0, output: 0,
            reason: "For 32 GB Macs: 16.1 GB; strong on CJK; turn thinking off"),
      .init(model: "google/gemma-4-31b", role: .free, input: 0, output: 0,
            reason: "For 32 GB+ Macs: 19 GB; best local Gemma"),
    ],
  ]
}

