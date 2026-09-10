//
//  ProviderSecrets.swift
//  Dev
//

import Foundation
import Security

// MARK: - ProviderSecrets

/// Read-only secret lookup shared by every hosted model provider.
///
/// Lookup order: login keychain → process environment → ~/.hermes/.env.
/// Only variable NAMES live in source — never values. Every failure path
/// returns nil, so an unconfigured provider degrades instead of crashing.
nonisolated enum ProviderSecrets {
  /// The shared credential file (Hermes') used as the last-resort fallback.
  static let dotEnvURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".hermes")
    .appendingPathComponent(".env")

  /// Reads the secret whose environment-variable name is `name`. The login
  /// keychain item is looked up under `service` (default: lowercased name)
  /// with `name` as its account.
  static func value(named name: String, service: String? = nil) -> String? {
    if let fromKeychain = readKeychain(account: name, service: service ?? name.lowercased()) {
      return fromKeychain
    }
    if let fromEnvironment = ProcessInfo.processInfo.environment[name],
       !fromEnvironment.isEmpty {
      return fromEnvironment
    }
    return readDotEnv(name: name)
  }

  /// True when the secret resolves to a non-empty value.
  static func isConfigured(_ name: String, service: String? = nil) -> Bool {
    value(named: name, service: service) != nil
  }

  // MARK: - keychain

  private static func readKeychain(account: String, service: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let value = String(data: data, encoding: .utf8),
          !value.isEmpty else {
      return nil
    }
    return value
  }

  // MARK: - .env fallback

  /// Parses `KEY=value` lines, tolerating blank lines, `#` comments, an
  /// optional `export ` prefix and surrounding quotes.
  static func readDotEnv(name: String) -> String? {
    guard let contents = try? String(contentsOf: dotEnvURL, encoding: .utf8) else {
      return nil
    }
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      if line.hasPrefix("export ") {
        line = String(line.dropFirst("export ".count))
      }
      guard let equals = line.firstIndex(of: "=") else { continue }
      guard line[..<equals].trimmingCharacters(in: .whitespaces) == name else { continue }
      var value = String(line[line.index(after: equals)...])
        .trimmingCharacters(in: .whitespaces)
      let isQuoted =
        (value.hasPrefix("\"") && value.hasSuffix("\""))
        || (value.hasPrefix("'") && value.hasSuffix("'"))
      if isQuoted, value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }
      return value.isEmpty ? nil : value
    }
    return nil
  }
}
