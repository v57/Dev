//
//  AgentPermissions.swift
//  Dev
//

import Foundation

/// What agents may do through Dev's MCP server, set in Settings ▸ Agents and
/// read by both the app and the `Dev --mcp` process (they share the app's
/// defaults: the same bundle identifier).
nonisolated enum AgentPermissions {
  enum Level: String, CaseIterable, Identifiable, Sendable {
    case allow, ask, never
    var id: String { rawValue }
    var title: String {
      switch self {
      case .allow: "Allow"
      case .ask: "Ask First"
      case .never: "Never"
      }
    }
  }

  enum Action: String, CaseIterable, Identifiable, Sendable {
    /// Read projects, recipes, workflows, screenshots and runs.
    case read
    /// Change screenshot recipes and workflows, render screenshots.
    case edit
    /// Start workflow runs.
    case run
    /// Let a run sign, notarize, upload and publish without asking.
    case publish

    var id: String { rawValue }

    var title: String {
      switch self {
      case .read: "Read projects, runs and screenshots"
      case .edit: "Change screenshot recipes and workflows"
      case .run: "Start workflow runs"
      case .publish: "Sign, notarize, upload and publish"
      }
    }

    var defaultLevel: Level {
      switch self {
      case .read, .edit: .allow
      case .run, .publish: .ask
      }
    }

    var key: String { "agents.permission." + rawValue }
  }

  static let enabledKey = "agents.enabled"
  static let lastClientKey = "agents.lastClient"
  static let lastSeenKey = "agents.lastSeen"
  static let logKey = "agents.log"

  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
  }

  static func level(_ action: Action) -> Level {
    UserDefaults.standard.string(forKey: action.key).flatMap(Level.init) ?? action.defaultLevel
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
  static let request = Notification.Name("dev.v57.dev.agent.request")
  static let reply = Notification.Name("dev.v57.dev.agent.reply")
  /// Posted after the MCP process wrote a file the app shows (a recipe, a workflow).
  static let changed = Notification.Name("dev.v57.dev.agent.changed")
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

  static func read() -> [Entry] {
    guard let url, let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }
}
