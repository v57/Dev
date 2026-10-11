//
//  ServerStore.swift
//  Dev
//

import Foundation
import SwiftData

// MARK: - Row value

/// Immutable per-server row data, computed once per `refresh()` so row bodies
/// never hit the keychain (a `ServerConnection.keySource` lookup is a syscall)
/// or re-parse the endpoint on every render.
struct ServerRow: Identifiable, Hashable {
  let id: String
  let name: String
  let endpoint: String
  let hostLabel: String
  let base: URL?
  let keySource: ServerConnection.KeySource
}

// MARK: - Status

/// What the last check found. `unknown` is the launch state; `checking` keeps a
/// slow server from looking offline while it answers.
enum ServerStatus: Hashable {
  case unknown
  case checking
  case online(messages: Int, commented: Int)
  case offline(String)
  case notConfigured(String)

  /// The sidebar dot.
  var isOnline: Bool {
    if case .online = self { return true }
    return false
  }

  var short: String {
    switch self {
    case .unknown: return "not checked"
    case .checking: return "checking…"
    case .online(let messages, let commented): return "\(messages) sentences, \(commented) commented"
    case .offline(let detail): return detail
    case .notConfigured(let detail): return detail
    }
  }
}

// MARK: - Store

/// The sidebar's servers: the persisted rows plus each one's last check.
///
/// Owned once by ContentView and shared with the sidebar and the detail pane,
/// the same way `SidebarViewModel` owns the project list — one source of truth
/// for 'which servers exist' and 'what did the last check find'.
///
/// Nothing here polls: a check runs when the app appears, when a server is
/// added or edited, and when the reader asks for one. A dot that refreshed on a
/// timer would put background traffic on every configured server for no gain.
@Observable
final class ServerStore {
  /// Fresh rows, rebuilt by `refresh()`.
  private(set) var servers: [ServerRow] = []

  /// Last check per server id.
  private(set) var statuses: [String: ServerStatus] = [:]

  /// When each server was last checked (the detail pane says how stale a dot is).
  private(set) var checkedAt: [String: Date] = [:]

  /// Set when a write fails, so the sidebar can report it instead of silently
  /// losing an edit.
  var alert: String?

  private var context: ModelContext { TranslationStore.shared.context }

  // MARK: - reading

  func row(id: String) -> ServerRow? { servers.first { $0.id == id } }

  func connection(id: String) -> ServerConnection? {
    ((try? context.fetch(FetchDescriptor<ServerConnection>())) ?? [])
      .first { $0.id == id }
  }

  func refresh() {
    let fetched = (try? context.fetch(FetchDescriptor<ServerConnection>())) ?? []
    alert = nil
    servers = fetched
      .sorted {
        $0.addedAt == $1.addedAt
          ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
          : $0.addedAt < $1.addedAt
      }
      .map { server in
        ServerRow(
          id: server.id,
          name: server.name,
          endpoint: server.endpoint,
          hostLabel: server.hostLabel,
          base: server.base,
          keySource: server.keySource)
      }
  }

  // MARK: - writing

  /// Creates a server. A non-empty key becomes its own keychain item; an empty
  /// one leaves the server on the shared `LOCALIZE_KEY`, which is how a local
  /// development server works with no setup.
  @discardableResult
  func add(name: String, endpoint: String, key: String) -> String? {
    let server = ServerConnection(name: name, endpoint: endpoint)
    context.insert(server)
    if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      ServerKeychain.save(key, account: server.keyAccount)
    }
    guard save() else { return nil }
    refresh()
    Task { await check(id: server.id) }
    return server.id
  }

  /// Edits a server in place. `key == nil` leaves its own key untouched (the
  /// form only sends it when the field was edited); an empty string clears it,
  /// which puts the server back on the shared key.
  func update(id: String, name: String, endpoint: String, key: String?) {
    guard let server = connection(id: id) else { return }
    server.name = name
    server.endpoint = endpoint
    if let key {
      ServerKeychain.save(key, account: server.keyAccount)
      if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        ServerKeychain.delete(account: server.keyAccount)
      }
    }
    guard save() else { return }
    refresh()
    Task { await check(id: id) }
  }

  /// Removes a server and its own key. The status goes with it, so a later
  /// server that reuses the id (it cannot: ids are UUIDs) would not inherit a
  /// stale dot.
  func remove(id: String) {
    guard let server = connection(id: id) else { return }
    ServerKeychain.delete(account: server.keyAccount)
    context.delete(server)
    guard save() else { return }
    statuses[id] = nil
    checkedAt[id] = nil
    refresh()
  }

  private func save() -> Bool {
    do {
      try context.save()
      return true
    } catch {
      alert = "Couldn't save the server list: \(error.localizedDescription)"
      return false
    }
  }

  // MARK: - checks

  /// Asks one server for its own tally (`localize/stats` — a read that writes
  /// nothing) and records the outcome. The reasons a check can fail are kept
  /// distinct: a missing key, an unusable endpoint and an unreachable host are
  /// three different fixes.
  func check(id: String) async {
    guard let server = connection(id: id) else { return }
    statuses[id] = .checking
    guard let base = server.base else {
      statuses[id] = .notConfigured("the endpoint is not a usable http(s) URL")
      checkedAt[id] = Date()
      return
    }
    guard let key = server.resolvedKey else {
      statuses[id] = .notConfigured(
        "no key: add one to this server, or set \(ServerKeychain.sharedKeyName)")
      checkedAt[id] = Date()
      return
    }
    let client = LocalizeClient(base: base, key: key)
    do {
      let stats = try await client.post("localize/stats", [:], as: LocalizeStats.self)
      statuses[id] = .online(messages: stats.messages, commented: stats.commented)
    } catch {
      // The client's own message already names the code that matters (401 key
      // refused, 503 server unconfigured), so the dot carries the fix, not just a
      // failure.
      let detail = (error as? LocalizeClient.Error)?.description ?? "\(error)"
      statuses[id] = .offline(detail)
    }
    checkedAt[id] = Date()
  }

  /// Checks every configured server — the launch pass and the sidebar's
  /// "Check All" affordance. Concurrent on purpose: the rows are independent
  /// and one slow host must not hold up the others.
  func checkAll() async {
    let ids = servers.map(\.id)
    await withTaskGroup(of: Void.self) { group in
      for id in ids {
        group.addTask { @MainActor in await self.check(id: id) }
      }
    }
  }
}
