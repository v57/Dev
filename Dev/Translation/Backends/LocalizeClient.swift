//
//  LocalizeClient.swift
//  Dev
//

import Foundation

// MARK: - LocalizeServer

/// Where the node's localize service lives and how this app proves it is there.
///
/// The service is the node (`~/github/vijo/node`) — the store the Localize tool
/// reads from and writes to. It is NOT a database connection: every rule that
/// keeps the corpus consistent (revision bumps, the stale stamp, the legacy
/// dual-write, the render-cache invalidation, the socket broadcast) lives in the
/// node's own code, so a direct Mongo write from this app would bypass all of
/// them. The app therefore speaks the node's HTTP surface, POST + JSON, and
/// carries the shared key as a bearer token.
///
/// The key is read through `ProviderSecrets` (login keychain → process
/// environment → `~/.hermes/.env`), so no secret is ever in source. A missing
/// key is reported as "not configured", never as a crash and never as a silent
/// empty result — an unconfigured app must look unconfigured.
nonisolated enum LocalizeServer {
  /// The key's variable name, in the node's `.env` and in the keychain.
  static let keyName = "LOCALIZE_KEY"

  /// Dev default: the node on its normal port. `LOCALIZE_BASE_URL` overrides it
  /// (the test-mode node listens on 18080).
  static var base: URL {
    let configured = ProcessInfo.processInfo.environment["LOCALIZE_BASE_URL"]
    return URL(string: configured ?? "http://127.0.0.1:8080/") ?? URL(string: "http://127.0.0.1:8080/")!
  }

  /// The client, or nil when no key is configured anywhere we look.
  static var client: LocalizeClient? {
    guard let key = ProviderSecrets.value(named: keyName) else { return nil }
    return LocalizeClient(base: base, key: key)
  }

  /// What the app may say about the service without asking the user anything.
  static var isConfigured: Bool { client != nil }
}

// MARK: - LocalizeClient

/// One POST against the node's localize surface.
///
/// Every route there is POST + JSON behind `Authorization: Bearer <key>`; the
/// answer is `{ "data": … }` on success and `{ "error": { "code", "message" } }`
/// on any refusal. The codes worth naming rather than flattening into "network
/// failed": 401 = the key is missing or wrong (or, on the write routes, that the
/// caller has no key at all), 503 = the node itself has no `LOCALIZE_KEY`, 600 =
/// a localized error string.
nonisolated struct LocalizeClient: Sendable {
  let base: URL
  let key: String
  var timeout: TimeInterval = 30

  enum Error: Swift.Error, CustomStringConvertible {
    case notConfigured
    case http(Int, String)
    case malformed(String)
    case unreachable(String)

    var description: String {
      switch self {
      case .notConfigured: return "no \(LocalizeServer.keyName) configured"
      case .http(let code, let message):
        switch code {
        case 401: return "the node refused the key (401): \(message)"
        case 503: return "the node has no \(LocalizeServer.keyName) configured (503): \(message)"
        default: return "HTTP \(code): \(message)"
        }
      case .malformed(let what): return "\(what) answered a shape the app cannot read"
      case .unreachable(let detail): return "cannot reach the localize server: \(detail)"
      }
    }
  }

  /// The node's failure body.
  private struct Failure: Decodable {
    struct Inner: Decodable { let code: Int; let message: String }
    let error: Inner
  }

  /// `POST {route}` with `body`, decoded from the `data` field.
  func post<T: Decodable>(_ route: String, _ body: [String: Any], as type: T.Type) async throws -> T {
    var request = URLRequest(url: base.appendingPathComponent(route))
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    } catch {
      throw Error.malformed(route)
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw Error.unreachable("\(base.absoluteString) \(error.localizedDescription)")
    }

    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
        throw Error.http(failure.error.code, failure.error.message)
      }
      throw Error.http(status, String(data: data, encoding: .utf8) ?? "no body")
    }

    guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
      throw Error.malformed(route)
    }
    return envelope.data
  }
}

// MARK: - Wire shapes

nonisolated struct Envelope<T: Decodable>: Decodable { let data: T }

/// `POST localize/stats { locales? }` — the service's own tally, and the cheapest
/// thing to check a connection with: it touches no value and writes nothing.
nonisolated struct LocalizeStats: Decodable, Sendable {
  nonisolated struct Row: Decodable, Sendable {
    let locale: String
    let total: Int
    let machine: Int
    let gold: Int
    let missing: Int
    let stale: Int
  }
  let rows: [Row]
  let messages: Int
  let commented: Int
}

/// `POST localize/messages` — one page of the inventory: every sentence with its
/// comment, its namespace and each locale's state.
nonisolated struct LocalizeInventory: Decodable, Sendable {
  nonisolated struct LocaleState: Decodable, Sendable {
    let value: String
    let origin: String
    let stale: Bool
  }
  nonisolated struct Item: Decodable, Sendable {
    let source: String
    let comment: String?
    let namespace: String
    let revision: Int
    let locales: [String: LocaleState]
  }
  let items: [Item]
  let cursor: String?
  let more: Bool
}

/// `POST localize/worklist` — one page of what still needs work in a locale.
/// The server decides what "needs work" means (`filter`), and a client steps
/// `cursor` until `more` is false; the run reads page by page rather than
/// holding the whole corpus.
nonisolated struct LocalizeWorklist: Decodable, Sendable {
  nonisolated struct Item: Decodable, Sendable {
    let source: String
    let comment: String?
    let namespace: String
    let locale: String
    let revision: Int
    let value: String?
    let origin: String?
    /// `null`/absent means "not stale" on the wire.
    let stale: Bool?

    var isStale: Bool { stale ?? false }
  }
  let items: [Item]
  let cursor: String?
  let more: Bool
}

/// One row of `POST localize/values`: `gold` is a human's decision, `machine`
/// the model's, and the server never lets a machine value overwrite a gold one.
nonisolated struct LocalizeValueEntry: Sendable {
  var source: String
  var locale: String
  var value: String
  var origin: String = "machine"
  var model: String? = nil

  /// The node's wire shape for this row.
  var dictionary: [String: Any] {
    var entry: [String: Any] = ["source": source, "locale": locale, "value": value, "origin": origin]
    if let model { entry["model"] = model }
    return entry
  }
}

/// What a `localize/values` write reported: how many rows landed, how many the
/// server refused (a machine value against a gold one) and why.
nonisolated struct LocalizeWriteResult: Decodable, Sendable {
  let written: Int
  let skipped: Int
  let stale: Int?
  let reason: String?
}

extension LocalizeClient {
  /// One page of the worklist. `filter` is the server's own vocabulary:
  /// `empty` (no value in this locale), `stale` (a machine value marked for
  /// redo), `machine`, `all`.
  func worklist(
    locale: String,
    filter: String = "empty",
    limit: Int = 1000,
    cursor: String? = nil
  ) async throws -> LocalizeWorklist {
    var body: [String: Any] = ["locale": locale, "filter": filter, "limit": limit]
    if let cursor { body["cursor"] = cursor }
    return try await post("localize/worklist", body, as: LocalizeWorklist.self)
  }

  /// The worklist AS BATCHES, pulled on demand: a page is fetched only when the
  /// previous one has been consumed, so a run holds one batch instead of the
  /// whole corpus, and a run that stops early stops reading. The filters are
  /// walked in order, each to exhaustion, and no sentence is served twice.
  ///
  /// `Swift.Error`, not the nested `LocalizeClient.Error`: inside this type a
  /// bare `Error` names our own enum and would make the stream's failure type
  /// wrong.
  func worklistBatches(
    locale: String,
    filters: [String] = ["empty"],
    limit: Int = 1000
  ) -> AsyncThrowingStream<[LocalizeWorklist.Item], Swift.Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var seen = Set<String>()
          for filter in filters {
            var cursor: String? = nil
            var more = true
            while more {
              try Task.checkCancellation()
              let page = try await worklist(locale: locale, filter: filter, limit: limit, cursor: cursor)
              let fresh = page.items.filter { seen.insert($0.source).inserted }
              if !fresh.isEmpty { continuation.yield(fresh) }
              more = page.more
              cursor = page.cursor
              // A page that promises more but hands back no cursor would spin.
              if more && cursor == nil { more = false }
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Writes values (the server caps a chunk at 1000 rows).
  @discardableResult
  func writeValues(_ entries: [LocalizeValueEntry]) async throws -> LocalizeWriteResult {
    try await post(
      "localize/values", ["entries": entries.map(\.dictionary)], as: LocalizeWriteResult.self)
  }
}

extension LocalizeClient {
  /// What the sidebar's server row shows: configured or not, reachable or not,
  /// and the corpus' own size when it answered.
  enum Status: Sendable {
    case notConfigured
    case offline(String)
    case online(messages: Int, commented: Int)
  }

  static func status(locale: String? = nil) async -> Status {
    guard let client = LocalizeServer.client else { return .notConfigured }
    do {
      let stats = try await client.post(
        "localize/stats", locale.map { ["locales": [$0]] } ?? [:], as: LocalizeStats.self)
      return .online(messages: stats.messages, commented: stats.commented)
    } catch {
      return .offline("\(error)")
    }
  }
}
