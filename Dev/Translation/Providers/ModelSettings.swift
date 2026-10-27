//
//  ModelSettings.swift
//  Dev
//

import Foundation
import Synchronization
import VaultKit

// MARK: - ModelSettings

/// Which model translation runs on: the user's choice, read wherever a call goes
/// out. Nothing is chosen until the user picks a provider in Settings, so an
/// unconfigured app says so instead of calling anyone.
///
/// The choice lives in UserDefaults and the key in the login keychain. Both are
/// read without the main actor because the HTTP path is `nonisolated`; the
/// Settings pane writes through `ModelSettingsModel`, which reads back from here.
nonisolated enum ModelSettings {
  enum Key {
    static let provider = "translation.provider"
    static let model = "translation.model"
    static let baseURL = "translation.baseURL"
    static let wire = "translation.wire"
  }

  static var providerID: String? { UserDefaults.standard.string(forKey: Key.provider) }
  static var model: String? { nonEmpty(UserDefaults.standard.string(forKey: Key.model)) }
  /// The user's base URL: required by a preset without one, an override otherwise.
  static var baseURL: String? { nonEmpty(UserDefaults.standard.string(forKey: Key.baseURL)) }
  /// The user's wire, honoured for Custom only; presets know their own.
  static var wire: Wire? { UserDefaults.standard.string(forKey: Key.wire).flatMap(Wire.init) }

  static var preset: ProviderPreset? { providerID.flatMap(ProviderPreset.preset(id:)) }

  /// The configured model, or nil when no provider, model or base URL is set.
  /// The key may still be missing: see `RoutedModel.isUsable`.
  static func resolved() -> RoutedModel? {
    guard let preset, let model else { return nil }
    let root = baseURL ?? preset.baseURL
    guard let url = URL(string: root), url.scheme != nil else { return nil }
    return RoutedModel(
      providerID: preset.id,
      providerName: preset.name,
      baseURL: url,
      wire: preset.id == ProviderPreset.custom.id ? (wire ?? preset.wire) : preset.wire(for: model),
      model: model,
      apiKey: ProviderKeychain.key(for: preset),
      needsKey: preset.needsKey,
      headers: preset.headers,
      requestsPerMinute: preset.requestsPerMinute)
  }

  /// Why `resolved()` cannot run a call, in the reader's words, or nil when it can.
  static var problem: String? {
    guard let preset else { return "Choose a model provider in Settings (⌘,)." }
    if preset.asksForBaseURL, baseURL == nil, preset.baseURL.isEmpty {
      return "Enter \(preset.name)'s base URL in Settings (⌘,)."
    }
    guard model != nil else { return "Choose a model for \(preset.name) in Settings (⌘,)." }
    if preset.needsKey, ProviderKeychain.key(for: preset) == nil {
      return "Add your \(preset.name) API key in Settings (⌘,)."
    }
    return nil
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }
}

// MARK: - ProviderKeychain

/// API keys, one login-keychain item per provider. The key never lands in
/// UserDefaults, a file or a log.
nonisolated enum ProviderKeychain {
  static let service = "dev.v57.dev.provider-key"

  /// The stored key, else the first of the preset's environment variables that is
  /// set (a developer who launches Dev from a shell with keys exported).
  static func key(for preset: ProviderPreset) -> String? {
    if let stored = read(account: preset.id) { return stored }
    let environment = ProcessInfo.processInfo.environment
    for name in preset.keyNames {
      if let value = environment[name], !value.isEmpty { return value }
    }
    return nil
  }

  static func hasStoredKey(for preset: ProviderPreset) -> Bool {
    read(account: preset.id) != nil
  }

  /// What the keychain answered per account, kept for the life of the app: the start buttons
  /// and the run's pages ask whether a model is configured on every redraw, and a keychain read
  /// is a trip to `securityd`. `save` and `delete` are the only writers, and they update it.
  private static let cache = Mutex([String: String?]())

  static func read(account: String) -> String? {
    if let cached = cache.withLock({ $0[account] }) { return cached }
    let value = readKeychain(account: account)
    cache.withLock { $0[account] = .some(value) }
    return value
  }

  private static func readKeychain(account: String) -> String? {
    DevKeychain.read(service: service, account: account)
  }

  /// Saves (or replaces) the key; an empty key removes it.
  @discardableResult
  static func save(_ key: String, account: String) -> Bool {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return delete(account: account) }
    defer { cache.withLock { $0[account] = nil } }
    return DevKeychain.write(key, service: service, account: account, label: "Dev: \(account) API key")
  }

  @discardableResult
  static func delete(account: String) -> Bool {
    defer { cache.withLock { $0[account] = nil } }
    return DevKeychain.delete(service: service, account: account)
  }

  // MARK: - import

  /// Keys found for presets that have none stored yet: in the process environment
  /// and in the `.env` files of tools that keep provider keys (Hermes). Read only
  /// when the user asks for an import.
  static func importable() -> [(preset: ProviderPreset, source: String, key: String)] {
    let environment = ProcessInfo.processInfo.environment
    let files = dotEnvFiles.map { ($0, DotEnv.read($0)) }
    var found: [(ProviderPreset, String, String)] = []
    for preset in ProviderPreset.all where !preset.keyNames.isEmpty && !hasStoredKey(for: preset) {
      search: for name in preset.keyNames {
        if let value = environment[name], !value.isEmpty {
          found.append((preset, "the environment ($\(name))", value))
          break search
        }
        for (url, values) in files {
          if let value = values[name], !value.isEmpty {
            let path = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            found.append((preset, "\(path) (\(name))", value))
            break search
          }
        }
      }
    }
    return found
  }

  static let dotEnvFiles: [URL] = [
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/.env")
  ]
}

// MARK: - DotEnv

/// `KEY=value` lines, tolerating blank lines, `#` comments, an `export ` prefix
/// and surrounding quotes.
nonisolated enum DotEnv {
  static func read(_ url: URL) -> [String: String] {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var values: [String: String] = [:]
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
      guard let equals = line.firstIndex(of: "=") else { continue }
      let name = line[..<equals].trimmingCharacters(in: .whitespaces)
      var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
      let quoted = (value.hasPrefix("\"") && value.hasSuffix("\""))
        || (value.hasPrefix("'") && value.hasSuffix("'"))
      if quoted, value.count >= 2 { value = String(value.dropFirst().dropLast()) }
      if values[name] == nil, !value.isEmpty { values[name] = value }
    }
    return values
  }
}
