//
//  AgentBridge.swift
//  Dev
//

import Foundation
import Observation
import PlatformBroadcast
import ComponentKit
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
    /// For a run: the content hash of the workflow the question showed.
    var shown: String?
  }

  private(set) var pending: Pending?
  @ObservationIgnored private var queue: [Pending] = []
  @ObservationIgnored private var observers: [Broadcast.Observation] = []
  @ObservationIgnored weak var workflows: WorkflowStore?
  @ObservationIgnored weak var screenshots: ScreenshotsStore?

  init() {
    // A screenshot or test launch beside the real app must not answer for it.
    guard !LaunchOptions.isScreenshotMode else { return }
    observers.append(Broadcast.observe(AgentChannel.request) { [weak self] info in
      MainActor.assumeIsolated { self?.receive(info) }
    })
    observers.append(Broadcast.observe(AgentChannel.changed) { [weak self] info in
      guard let path = info["project"] else { return }
      MainActor.assumeIsolated {
        let root = URL(fileURLWithPath: path)
        self?.workflows?.reload(root)
        Task { await self?.screenshots?.refresh(root) }
      }
    })
  }

  private func receive(_ info: [String: String]) {
    guard let id = info["id"], let kind = info["kind"] else { return }
    guard AgentPermissions.isEnabled else {
      reply(id, kind == "run" ? "error:Agents are turned off in Dev ▸ Settings ▸ Agents." : "denied")
      return
    }
    var request = Pending(id: id, client: info["client"] ?? "An agent", summary: info["summary"] ?? "",
                          kind: kind, payload: info)
    if kind == "run" {
      // The question names what would actually run, read from the project here, not the request's own text; and
      // a workflow nobody approved in the app runs only once the reader approves its steps (security audit H6, M16).
      guard let (root, workflow) = runTarget(request) else { return }
      let approved = WorkflowApprovals.isApproved(workflow, in: root)
      let steps = WorkflowApprovals.summary(of: workflow)
      request = Pending(
        id: id, client: request.client,
        summary: approved
          ? String(localized: "run \(workflow.name) in \(root.lastPathComponent): \(steps)")
          : String(localized: "run \(workflow.name) in \(root.lastPathComponent), which you haven't approved yet. Allowing approves its steps: \(steps)"),
        kind: kind, payload: info, shown: WorkflowApprovals.hash(workflow))
      if approved, AgentPermissions.level(.run) == .allow {
        startRun(request)
        return
      }
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

  /// The sidebar project and the workflow a run request names, as on disk now; nil after replying why not.
  private func runTarget(_ request: Pending) -> (URL, Workflow)? {
    guard let store = workflows, let path = request.payload["project"], let id = request.payload["workflow"] else {
      reply(request.id, "error:Dev has no window open to run in.")
      return nil
    }
    let root = URL(fileURLWithPath: path).standardizedFileURL
    // Only a project in Dev's sidebar: a forged request can't point Dev at another folder's workflows.
    guard let known = store.watchedRoots.first(where: { $0.standardizedFileURL.path == root.path }) else {
      reply(request.id, "error:\(root.lastPathComponent) isn't a project in Dev's sidebar.")
      return nil
    }
    store.reload(known)
    guard let workflow = store.workflows(for: known).first(where: { $0.id == id }) else {
      reply(request.id, "error:No workflow \(id).")
      return nil
    }
    return (known, workflow)
  }

  private func startRun(_ request: Pending) {
    guard let store = workflows, let (root, workflow) = runTarget(request) else { return }
    // Allowed on screen: the reader saw these steps (re-read now, so a file changed meanwhile isn't run).
    if !WorkflowApprovals.isApproved(workflow, in: root) {
      guard request.shown == WorkflowApprovals.hash(workflow) else {
        reply(request.id, "error:\(workflow.name) changed while waiting. Ask again.")
        return
      }
      store.approve(workflow, in: root)
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
    Broadcast.post(AgentChannel.reply, ["id": id, "answer": answer])
  }
}

// MARK: - Settings ▸ Agents

/// Turning the MCP server on, the command that adds it to an agent, what
/// agents may do, and what they did lately.
struct AgentsSettingsView: View {
  @State private var enabled = AgentPermissions.isEnabled
  @State private var levels: [AgentPermissions.Action: AgentPermissions.Level] = [:]
  @State private var log: [String] = []

  private var command: String {
    let path = Bundle.main.executablePath ?? "/Applications/Dev.app/Contents/MacOS/Dev"
    return "claude mcp add dev -- \"\(path)\" --mcp"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      FormCard("MCP Server") {
        FormRow(
          "Let agents use Dev", help: "Agents can set up screenshot framing and workflows, and run them.",
          systemImage: "powerplug", hue: .indigo
        ) {
          Toggle("Let agents use Dev", isOn: Binding(
            get: { enabled },
            set: { enabled = $0; AgentPermissions.setEnabled($0) }
          )).labelsHidden().toggleStyle(.kitSwitch)
        }
        FormRow("Status", help: status, systemImage: "dot.radiowaves.left.and.right", hue: statusHue)
        FormRow("Add Dev to Claude Code", systemImage: "terminal", hue: .gray, field: HStack {
          Text(command)
            .kitFont(.mono)
            .textSelection(.enabled)
            .lineLimit(2)
          Spacer()
          KitCopyButton(value: command).buttonStyle(.kitPlain)
        })
      }
      FormCard(
        "What Agents May Do",
        footer: "Every change an agent makes shows on the screen it changed. Publishing steps always stop and ask unless set to Allow."
      ) {
        ForEach(AgentPermissions.Action.allCases) { action in
          FormRow(action.title, systemImage: "checkmark.shield", hue: .gray) {
            KitPicker(
              action.title,
              selection: Binding(
                get: { levels[action] ?? AgentPermissions.level(action) },
                set: { level in
                  levels[action] = level
                  AgentPermissions.setLevel(level, for: action)
                }),
              options: AgentPermissions.Level.allCases.map { ($0.title, $0) })
          }
        }
      }
      FormCard("Recent Agent Activity") {
        if log.isEmpty {
          FormRow("Nothing yet", systemImage: "clock", hue: .gray)
        }
        ForEach(log.prefix(8), id: \.self) { line in
          FormRow(line, systemImage: "clock", hue: .gray)
        }
      }
    }
    .onAppear {
      log = UserDefaults.standard.stringArray(forKey: AgentPermissions.logKey) ?? []
    }
  }

  private var lastSeen: Date? { UserDefaults.standard.object(forKey: AgentPermissions.lastSeenKey) as? Date }

  private var status: LocalizedStringKey {
    guard enabled else { return "Off" }
    guard let lastSeen else { return "Ready · no agent has connected yet" }
    let when = lastSeen.formatted(.relative(presentation: .named))
    guard let client = UserDefaults.standard.string(forKey: AgentPermissions.lastClientKey) else {
      return "Ready · An agent used Dev \(when)"
    }
    return "Ready · \(client) used Dev \(when)"
  }

  private var statusHue: Hue {
    guard enabled else { return .gray }
    if let lastSeen, Date().timeIntervalSince(lastSeen) < 600 { return .green }
    return .blue
  }
}
