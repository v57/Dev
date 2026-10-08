//
//  ServerConnection.swift
//  Dev
//

import Foundation
import Security
import SwiftData

// MARK: - ServerConnection

/// One localize server the app talks to.
///
/// A server is NOT a database connection, even though it looks like one in the
/// sidebar. The corpus lives in Mongo behind the node (`~/github/vijo/node`),
/// and every rule that keeps it consistent — revision bumps, the stale stamp,
/// the legacy dual-write, the render-cache invalidation, the socket broadcast —
/// is enforced by the node's own code. So each row here is an HTTP endpoint
/// plus a key, and the app speaks the node's API rather than Mongo.
///
/// The KEY is never stored in SwiftData: the row keeps only the keychain
/// ACCOUNT (`keyAccount`) to look it up under, exactly like `OpenCodeKeychain`
/// keeps the provider secret out of source and out of the store. A server with
/// no own key falls back to the shared `LOCALIZE_KEY`, which is what makes a
/// fresh local server work with no setup at all.
@Model
final class ServerConnection {
  /// Stable identity: the sidebar selection, the status map and the keychain
  /// account are all keyed by it, so renaming or re-pointing a server never
  /// orphans its key or its status.
  @Attribute(.unique) var id: String

  /// What the sidebar shows. Free text; duplicates are allowed.
  var name: String

  /// The service root as typed, e.g. `http://127.0.0.1:8080/`.
  var endpoint: String

  var addedAt: Date

  /// `kSecAttrAccount` of this server's own key item.
  var keyAccount: String

  init(id: String = UUID().uuidString, name: String, endpoint: String, addedAt: Date = Date()) {
    self.id = id
    self.name = name
    self.endpoint = endpoint
    self.addedAt = addedAt
    self.keyAccount = id
  }

  // MARK: - derived

  /// The parsed root, or nil when the text is not a usable http(s) URL. A row
  /// whose endpoint cannot be parsed reports that rather than failing later.
  var base: URL? {
    guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host?.isEmpty == false else {
      return nil
    }
    // A base without its trailing slash would drop the last path component
    // when routes are appended.
    return url.path.hasSuffix("/") ? url : url.appendingPathComponent("")
  }

  /// `host:port` for the sidebar's subtitle.
  var hostLabel: String {
    guard let base, let host = base.host else { return endpoint }
    if let port = base.port { return "\(host):\(port)" }
    return host
  }

  /// This server's own key, typed in the form, when it has one.
  var ownKey: String? { ServerKeychain.key(account: keyAccount) }

  /// The key the app will actually send, and where it came from.
  var keySource: KeySource {
    if ownKey != nil { return .server }
    if ProviderSecrets.value(named: ServerKeychain.sharedKeyName) != nil { return .shared }
    return .missing
  }

  enum KeySource: Hashable {
    /// The key typed into this server's form (its own keychain item).
    case server
    /// The shared `LOCALIZE_KEY` (keychain, environment or ~/.hermes/.env).
    case shared
    /// Nothing configured: calls will be refused with 401/503.
    case missing

    var label: String {
      switch self {
      case .server: return "key: this server's own"
      case .shared: return "key: \(ServerKeychain.sharedKeyName)"
      case .missing: return "key: not configured"
      }
    }
  }

  /// The key to send, if any.
  var resolvedKey: String? {
    ownKey ?? ProviderSecrets.value(named: ServerKeychain.sharedKeyName)
  }

  /// The signed-in client for this server, or nil when its endpoint or key is
  /// unusable — both reported by `keySource`/`base` rather than thrown here.
  var client: LocalizeClient? {
    guard let base, let key = resolvedKey else { return nil }
    return LocalizeClient(base: base, key: key)
  }
}

// MARK: - ServerKeychain

/// The per-server key store.
///
/// Same convention as `OpenCodeKeychain`: the login keychain holds the value
/// under a service/account pair, only variable NAMES live in source, and every
/// failure path returns nil instead of throwing. The shared fallback key keeps
/// its own name (`LOCALIZE_KEY`) so the node's `.env` and the app agree on what
/// to look for.
nonisolated enum ServerKeychain {
  /// kSecAttrService for every server key; the account distinguishes them.
  static let service = "dev.localize.server"
  /// The shared key every server falls back to when it has none of its own.
  static let sharedKeyName = "LOCALIZE_KEY"

  static func key(account: String) -> String? {
    ServerKeychain.read(service: service, account: account)
  }

  @discardableResult
  static func save(_ key: String, account: String) -> Bool {
    let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return delete(account: account) }
    return ServerKeychain.write(service: service, account: account, value: value)
  }

  @discardableResult
  static func delete(account: String) -> Bool {
    ServerKeychain.remove(service: service, account: account)
  }

  // MARK: - generic password items

  /// Reads a generic-password item. Shared with `ProviderSecrets`' shape on
  /// purpose: one item per (service, account), the value in `kSecValueData`.
  static func read(service: String, account: String) -> String? {
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
          !value.isEmpty else { return nil }
    return value
  }

  @discardableResult
  static func write(service: String, account: String, value: String) -> Bool {
    let data = Data(value.utf8)
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    let updated = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
    if updated == errSecSuccess { return true }
    guard updated == errSecItemNotFound else { return false }
    var insert = base
    insert.merge(attributes) { _, new in new }
    return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
  }

  @discardableResult
  static func remove(service: String, account: String) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}
