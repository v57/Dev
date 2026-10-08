//
//  OpenCodeKeychain.swift
//  Dev
//

import Foundation
import Security

// MARK: - OpenCodeKeychain

/// Reads and writes the OpenCode Go API key (OPENCODE_GO_API_KEY).
///
/// Lookup order: login keychain → process environment → ~/.hermes/.env.
/// The key VALUE is never hardcoded in source — only the variable name is.
/// Every failure path returns nil / false (mock-first: an unconfigured
/// backend reports "not configured", it never crashes).
nonisolated enum OpenCodeKeychain {
  /// Name of the secret everywhere (keychain account, env var, .env line).
  static let envName = "OPENCODE_GO_API_KEY"
  /// kSecAttrService for the generic-password item.
  static let service = "opencode"
  /// kSecAttrAccount for the generic-password item.
  static let account = "OPENCODE_GO_API_KEY"
  /// The .env fallback location (Hermes' credential file).
  static let dotEnvURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".hermes")
    .appendingPathComponent(".env")

  // MARK: - lookup

  /// Returns the key, or nil when it is not configured anywhere.
  static func apiKey() -> String? {
    ProviderSecrets.value(named: envName, service: service)
  }

  // MARK: - keychain

  /// Upserts the key into the login keychain (used by the settings UI once
  /// it lands; keeping the write convention next to the read).
  @discardableResult
  static func save(_ apiKey: String) -> Bool {
    let data = Data(apiKey.utf8)
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let updateAttributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    let updateStatus = SecItemUpdate(base as CFDictionary, updateAttributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return true
    }
    guard updateStatus == errSecItemNotFound else {
      return false
    }
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  /// Removes the stored item; succeeds when there was nothing to remove.
  @discardableResult
  static func delete() -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}
