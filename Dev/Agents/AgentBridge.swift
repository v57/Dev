//
//  AgentBridge.swift
//  Dev
//

import Foundation
import Observation
import SwiftUI

/// The app's end of the MCP server: it answers the requests the `Dev --mcp`
/// process cannot answer itself — starting a run, and every "Ask First" — and
/// reloads what an agent changed on disk, so the open tabs show it at once.
@Observable
final class AgentBridge {
  /// A request waiting for the reader.
  struct Pending: Identifiable {
    let id: String
    let client: String
    let summary: String
    let kind: String
    let payload: [String: String]
  }

  private(set) var pending: Pending?
  @ObservationIgnored private var queue: [Pending] = []
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored weak var workflows: WorkflowStore?
  @ObservationIgnored weak var screenshots: ScreenshotsStore?

  init() {
    // A screenshot or test launch beside the real app must not answer for it.
    guard !LaunchOptions.isScreenshotMode else { return }
    let center = DistributedNotificationCenter.default()
    observers.append(center.addObserver(forName: AgentChannel.request, object: nil, queue: .main) { [weak self] note in
      let info = note.userInfo as? [String: String] ?? [:]
      MainActor.assumeIsolated { self?.receive(info) }
    })
    observers.append(center.addObserver(forName: AgentChannel.changed, object: nil, queue: .main) { [weak self] note in
      guard let path = (note.userInfo as? [String: String])?["project"] else { return }
      MainActor.assumeIsolated {
        let root = URL(fileURLWithPath: path)
        self?.workflows?.reload(root)
        Task { await self?.screenshots?.refresh(root) }
      }
    })
  }

  private func receive(_ info: [String: String]) {
    guard let id = info["id"], let kind = info["kind"] else { return }
    let request = Pending(id: id, client: info["client"] ?? "An agent", summary: info["summary"] ?? "",
                          kind: kind, payload: info)
    if kind == "run", AgentPermissions.level(.run) == .allow {
      startRun(request)
      return
    }
    queue.append(request)
    if pending == nil { pending = queue.removeFirst() }
  }

  /// The reader's answer to the request on screen.
  func answer(_ approved: Bool) {
    guard let request = pending else { return }
    pending = nil
    if approved {
      if request.kind == "run" { startRun(request) } else { reply(request.id, "approved") }
    } else {
      reply(request.id, request.kind == "run" ? "error:The reader declined the run." : "denied")
    }
    if !queue.isEmpty { pending = queue.removeFirst() }
  }

  private func startRun(_ request: Pending) {
    guard let store = workflows, let path = request.payload["project"], let id = request.payload["workflow"] else {
      reply(request.id, "error:Dev has no window open to run in.")
      return
    }
    let root = URL(fileURLWithPath: path)
    store.reload(root)
    guard let workflow = store.workflows(for: root).first(where: { $0.id == id }) else {
      reply(request.id, "error:No workflow \(id).")
      return
    }
    guard !store.isRunning(root) else {
      reply(request.id, "error:\(root.lastPathComponent) already has a run in flight.")
      return
    }
    store.start(
      workflow, in: root, version: request.payload["version"], startedBy: request.client,
      confirmedPublishing: AgentPermissions.level(.publish) == .allow)
    reply(request.id, "Started \(workflow.name). Use get_runs to follow it; publishing steps "
      + (AgentPermissions.level(.publish) == .allow ? "run without asking." : "ask the reader first."))
  }

  private func reply(_ id: String, _ answer: String) {
    DistributedNotificationCenter.default().postNotificationName(
      AgentChannel.reply, object: nil, userInfo: ["id": id, "answer": answer], deliverImmediately: true)
  }
}

// MARK: - Settings ▸ Agents

/// Turning the MCP server on, the command that adds it to an agent, what
/// agents may do, and what they did lately.
struct AgentsSettingsView: View {
  @AppStorage(AgentPermissions.enabledKey) private var enabled = true
  @State private var levels: [AgentPermissions.Action: AgentPermissions.Level] = [:]
  @State private var log: [String] = []
  @State private var copied = false

  private var command: String {
    let path = Bundle.main.executablePath ?? "/Applications/Dev.app/Contents/MacOS/Dev"
    return "claude mcp add dev -- \"\(path)\" --mcp"
  }

  var body: some View {
    Form {
      Section("MCP Server") {
        Toggle(isOn: $enabled) {
          Text("Let agents use Dev")
          Text("Agents can set up screenshot framing and workflows, and run them.")
        }
        HStack(spacing: 8) {
          Circle().fill(statusColor).frame(width: 8, height: 8)
          Text(status)
        }
        HStack {
          Text(command)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(2)
          Spacer()
          Button(copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
          }
        }
      }
      Section("What Agents May Do") {
        ForEach(AgentPermissions.Action.allCases) { action in
          Picker(action.title, selection: Binding(
            get: { levels[action] ?? AgentPermissions.level(action) },
            set: { level in
              levels[action] = level
              UserDefaults.standard.set(level.rawValue, forKey: action.key)
            })
          ) {
            ForEach(AgentPermissions.Level.allCases) { Text($0.title).tag($0) }
          }
        }
        Text("Every change an agent makes shows on the screen it changed. Publishing steps always stop and ask unless set to Allow.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Section("Recent Agent Activity") {
        if log.isEmpty {
          Text("Nothing yet").foregroundStyle(.secondary)
        }
        ForEach(log.prefix(8), id: \.self) { line in
          Text(line).font(.callout)
        }
      }
    }
    .formStyle(.grouped)
    .frame(minHeight: 460)
    .disabled(false)
    .onAppear {
      log = UserDefaults.standard.stringArray(forKey: AgentPermissions.logKey) ?? []
    }
  }

  private var lastSeen: Date? { UserDefaults.standard.object(forKey: AgentPermissions.lastSeenKey) as? Date }

  private var status: String {
    guard enabled else { return "Off" }
    guard let lastSeen else { return "Ready · no agent has connected yet" }
    let client = UserDefaults.standard.string(forKey: AgentPermissions.lastClientKey) ?? "An agent"
    return "Ready · \(client) used Dev \(lastSeen.formatted(.relative(presentation: .named)))"
  }

  private var statusColor: Color {
    guard enabled else { return .secondary }
    if let lastSeen, Date().timeIntervalSince(lastSeen) < 600 { return .green }
    return .blue
  }
}
