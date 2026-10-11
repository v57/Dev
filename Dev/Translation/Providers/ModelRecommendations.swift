//
//  ModelRecommendations.swift
//  Dev
//

import Foundation

// MARK: - ModelRecommendations

/// The models each preset suggests for translating UI strings, with their list
/// prices in USD per million tokens. Checked 2026-10-11; prices move, so the
/// Settings pane shows them as a guide and the model field stays free text.
nonisolated enum ModelRecommendations {
  static let commandcode: [ModelRecommendation] = [
    .init(model: "deepseek/deepseek-v4-pro", role: .best,
          reason: "Strong multilingual model at full precision"),
    .init(model: "deepseek/deepseek-v4-flash", role: .value,
          reason: "Fast and cheap, good for large catalogs"),
  ]

  static let openrouter: [ModelRecommendation] = [
    .init(model: "anthropic/claude-sonnet-5.5", role: .best, input: 2, output: 10,
          reason: "Careful with tone, placeholders and plural forms"),
    .init(model: "anthropic/claude-haiku-5.5", role: .value, input: 0.1, output: 0.5,
          reason: "Very cheap and reliable for short UI strings"),
  ]

  static let opencodeZen: [ModelRecommendation] = [
    .init(model: "claude-haiku-5-5", role: .value, input: 0.1, output: 0.5,
          reason: "Full-precision Claude, cheap"),
    .init(model: "claude-sonnet-5-5", role: .best, input: 2, output: 10,
          reason: "Best quality on Zen"),
  ]

  static let opencodeGo: [ModelRecommendation] = [
    .init(model: "claude-haiku-5-5", role: .value, input: 0.1, output: 0.5,
          reason: "Full-precision Claude in the Go plan"),
  ]

  static let openai: [ModelRecommendation] = [
    .init(model: "gpt-6.1-sol", role: .best, input: 2, output: 10,
          reason: "OpenAI's current general model"),
    .init(model: "gpt-6-luna", role: .value, input: 0.1, output: 0.5,
          reason: "Small, fast and cheap"),
  ]

  static let anthropic: [ModelRecommendation] = [
    .init(model: "claude-sonnet-5-5", role: .best, input: 2, output: 10,
          reason: "Careful with tone, placeholders and plural forms"),
    .init(model: "claude-haiku-5-5", role: .value, input: 0.1, output: 0.5,
          reason: "Very cheap and reliable for short UI strings"),
  ]

  static let gemini: [ModelRecommendation] = [
    .init(model: "gemini-3.8-flash", role: .best, input: 0.75, output: 3.75,
          reason: "Broad language coverage"),
    .init(model: "gemini-3.5-flash-lite", role: .value, input: 0.3, output: 2.5,
          reason: "Cheaper Flash for big catalogs"),
  ]

  static let deepseek: [ModelRecommendation] = [
    .init(model: "deepseek-v4-pro", role: .best, input: 0.66, output: 1.98,
          reason: "Strong quality for the price"),
    .init(model: "deepseek-v4-flash", role: .value, input: 0.15, output: 0.6,
          reason: "Fast and very cheap"),
  ]

  static let xai: [ModelRecommendation] = [
    .init(model: "grok-4.7", role: .best, input: 2, output: 6,
          reason: "xAI's current model"),
  ]

  static let meta: [ModelRecommendation] = [
    .init(model: "muse-spark-1.3", role: .best, input: 1.25, output: 4.25,
          reason: "Full tier; your strings are not used for training"),
    .init(model: "muse-spark-1.3-contributor", role: .value, input: 0.1, output: 0.2,
          reason: "Very cheap, but Meta may train on your strings"),
  ]

  static let alibaba: [ModelRecommendation] = [
    .init(model: "qwen3.8-max", role: .best, input: 2, output: 6,
          reason: "Qwen's strongest model; excellent for CJK"),
    .init(model: "qwen3.8-flash", role: .value, input: 0.15, output: 0.47,
          reason: "Cheap and fast"),
  ]

  static let moonshot: [ModelRecommendation] = [
    .init(model: "kimi-k3", role: .best, input: 3, output: 15,
          reason: "Moonshot's flagship"),
  ]

  static let minimax: [ModelRecommendation] = [
    .init(model: "MiniMax-M3", role: .value, input: 0.3, output: 1.2,
          reason: "Cheap, long context"),
  ]

  static let zai: [ModelRecommendation] = [
    .init(model: "glm-5.3", role: .best, input: 1.4, output: 4.4,
          reason: "GLM's flagship"),
    .init(model: "glm-5.3-flash", role: .value, input: 0.15, output: 0.5,
          reason: "Cheap and fast"),
  ]

  static let ollama: [ModelRecommendation] = [
    .init(model: "qwen3:30b", role: .free,
          reason: "Good multilingual quality on a 32 GB Mac"),
    .init(model: "gpt-oss:20b", role: .free,
          reason: "Runs on a 16 GB Mac"),
  ]

  static let lmstudio: [ModelRecommendation] = [
    .init(model: "qwen/qwen3-30b-a3b-2507", role: .free,
          reason: "Good multilingual quality on a 32 GB Mac"),
    .init(model: "openai/gpt-oss-20b", role: .free,
          reason: "Runs on a 16 GB Mac"),
  ]
}
