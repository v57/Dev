//
//  RoutedModel.swift
//  Dev
//

import Foundation

// MARK: - RoutedModel

/// The model a translation call goes to: the provider and model the user chose in
/// Settings, resolved into an endpoint, a wire and a key (`ModelSettings`).
///
/// Nothing here names a provider. Users bring their own key; the presets in
/// `ProviderPreset` only fill the form.
nonisolated struct RoutedModel: Sendable, Identifiable {
  let providerID: String
  let providerName: String
  /// Root of the provider's OpenAI-compatible surface.
  let baseURL: URL
  /// Which OpenAI wire protocol the provider speaks for this model.
  var wire: Wire = .chatCompletions
  /// Provider-side model id.
  let model: String
  /// The key, or nil when none is stored or exported.
  let apiKey: String?
  /// False for local servers, which answer without a key.
  var needsKey = true
  /// Provider-specific headers (OpenCode's session id); the user agent is added
  /// to every call.
  var headers: [String: String] = [:]
  /// Conservative client-side pacing, so a burst cannot turn into error retries.
  var requestsPerMinute = 30

  var id: String { "\(providerID):\(model)" }

  /// The label a translated value's `lastEditor` and the status bar carry.
  var name: String { model }

  /// The full URL this model's calls go to — the provider root plus the wire's path.
  var endpoint: URL { baseURL.appendingPathComponent(wire.path) }

  /// True when a call can go out: a key is there, or the provider needs none.
  var isUsable: Bool { !needsKey || apiKey != nil }

  /// What the Authorization header carries; empty means no header.
  var bearer: String { apiKey ?? "" }

  /// Every header a call sends besides the auth and content type.
  var allHeaders: [String: String] {
    headers.merging(["User-Agent": Self.userAgent]) { own, _ in own }
  }

  /// The name the app calls itself by on the wire.
  static let userAgent: String = {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return "Dev/\(version ?? "1.0")"
  }()

  /// One session id per process, for providers that route and cache by it.
  static let sessionID = "ses_dev_" + UUID().uuidString.lowercased()

  /// The model the user configured, or nil when Settings is incomplete.
  static var current: RoutedModel? { ModelSettings.resolved() }

  /// The candidates a call may go to, in order. One: the user's choice.
  static var chain: [RoutedModel] {
    guard let current, current.isUsable else { return [] }
    return [current]
  }
}
