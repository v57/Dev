//
//  AgentPermissions.swift
//  Dev
//

import Foundation
import Synchronization

/// What agents may do through Dev's MCP server, set in Settings ▸ Agents and
/// read by both the app and the `Dev --mcp` process (the same signed binary).
/// The levels and the on switch live in Dev's keychain item, not in
/// UserDefaults: `defaults write dev.v57.dev …` from any process (an agent's
/// shell among them) must not be able to grant itself `run` (security audit M16).
nonisolated enum AgentPermissions {
  enum Level: String, CaseIterable, Identifiable, Sendable {
    case allow, ask, never
    var id: String { rawValue }
    var title: String {
      switch self {
      case .allow: String(localized: "Allow")
      case .ask: String(localized: "Ask First")
      case .never: String(localized: "Never")
      }
    }
  }

  enum Action: String, CaseIterable, Identifiable, Sendable {
    /// Read projects, screenshot framing, workflows, screenshots, store text and runs.
    case read
    /// Change screenshot framing, workflows and store text, render screenshots.
    case edit
    /// Start workflow runs.
    case run
    /// Let a run sign, notarize, upload and publish without asking.
    case publish

    var id: String { rawValue }

    var title: String {
      switch self {
      case .read: String(localized: "Read projects, runs, screenshots and store text")
      case .edit: String(localized: "Change screenshot framing, workflows and store text")
      case .run: String(localized: "Start workflow runs")
      case .publish: String(localized: "Sign, notarize, upload and publish")
      }
    }

    var defaultLevel: Level {
      switch self {
      case .read, .edit: .allow
      case .run, .publish: .ask
      }
    }
  }

  static let lastClientKey = "agents.lastClient"
  static let lastSeenKey = "agents.lastSeen"
  static let logKey = "agents.log"

  static var isEnabled: Bool { Stored.load().enabled ?? true }

  static func setEnabled(_ enabled: Bool) {
    var stored = Stored.load()
    stored.enabled = enabled
    stored.save()
  }

  static func level(_ action: Action) -> Level {
    Stored.load().levels[action.rawValue].flatMap(Level.init) ?? action.defaultLevel
  }

  static func setLevel(_ level: Level, for action: Action) {
    var stored = Stored.load()
    stored.levels[action.rawValue] = level.rawValue
    stored.save()
  }

  /// The settings as kept in the keychain (one item, JSON). Levels an earlier Dev wrote to UserDefaults are
  /// dropped, not adopted: anyone could have written them.
  struct Stored: Codable, Equatable {
    var enabled: Bool?
    var levels: [String: String] = [:]

    static let service = "dev.v57.dev.agents"
    static let account = "permissions"

    static func load() -> Stored {
      forgetDefaults()
      guard let text = DevKeychain.read(service: service, account: account),
            let stored = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8))
      else { return Stored() }
      return stored
    }

    func save() {
      guard let data = try? JSONEncoder().encode(self), let text = String(data: data, encoding: .utf8) else { return }
      _ = DevKeychain.write(text, service: Self.service, account: Self.account, label: "Dev: agent permissions")
    }

    private static let forgotten = Mutex(false)

    private static func forgetDefaults() {
      guard !forgotten.withLock({ let was = $0; $0 = true; return was }) else { return }
      let defaults = UserDefaults.standard
      defaults.removeObject(forKey: "agents.enabled")
      for action in Action.allCases { defaults.removeObject(forKey: "agents.permission." + action.rawValue) }
    }
  }

  /// One line in the agent activity list, newest first, 50 kept.
  static func log(_ line: String) {
    let defaults = UserDefaults.standard
    var lines = defaults.stringArray(forKey: logKey) ?? []
    let stamp = Date().formatted(date: .abbreviated, time: .shortened)
    lines.insert("\(stamp) · \(line)", at: 0)
    defaults.set(Array(lines.prefix(50)), forKey: logKey)
  }

  /// The name an agent's changes carry: "Claude Code through MCP".
  static var authorName: String {
    let client = UserDefaults.standard.string(forKey: lastClientKey) ?? "An agent"
    return "\(client) through MCP"
  }
}

/// The distributed notifications the MCP process and the app talk over.
nonisolated enum AgentChannel {
  static let request = "dev.v57.dev.agent.request"
  static let reply = "dev.v57.dev.agent.reply"
  /// Posted after the MCP process wrote a file the app shows (the screenshots file, a workflow).
  static let changed = "dev.v57.dev.agent.changed"
}

/// The project folders the app knows, written by the app for the MCP process.
nonisolated enum KnownProjects {
  static var url: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.v57.dev", isDirectory: true)
      .appendingPathComponent("projects.json")
  }

  struct Entry: Codable, Sendable {
    var name: String
    var root: String
  }

  static func write(_ entries: [Entry]) {
    guard let url else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
  }

  /// Tests' own list instead of the file; nil reads the file.
  static let override = Mutex<[Entry]?>(nil)

  static func read() -> [Entry] {
    if let entries = override.withLock({ $0 }) { return entries }
    guard let url, let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }
}
