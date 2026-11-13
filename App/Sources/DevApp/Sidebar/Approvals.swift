//
//  Approvals.swift
//  Dev
//

import ComponentKit
import SwiftUI

/// The sidebar's Approvals button: how many things wait for the reader, and the list that answers them. Three kinds
/// wait: an agent's request over MCP, a run about to publish, and a workflow from the project's files whose trigger is
/// off until the reader approves it. The first two also ask on screen, but only one at a time, and a run's question
/// only in its project's Workflows tab; the list shows them all, wherever the reader is.
struct ApprovalsButton: View {
  let model: SidebarViewModel
  let workflows: WorkflowStore
  let agents: AgentBridge
  @State private var isOpen = false

  var body: some View {
    let count = Self.count(workflows: workflows, agents: agents)
    Button {
      // Workflow files changed in git or by an agent since the last look.
      workflows.reloadWorkflowFiles()
      isOpen = true
    } label: {
      // The count beside the shield, as the kit's toolbar buttons show theirs (Git's Push 2).
      Label {
        Text("Approvals")
      } icon: {
        HStack(spacing: 3) {
          Image(systemName: count > 0 ? "checkmark.shield.fill" : "checkmark.shield")
          if count > 0 { Count(count, .attention).transition(.opacity) }
        }
        .animation(.kit, value: count)
      }
    }
    .kitPopover(isPresented: $isOpen, edge: .top) {
      ApprovalsList(model: model, workflows: workflows, agents: agents)
        .frame(width: 380)
    }
    .kitHelp(
      "Approvals", meta: count == 0 ? "Nothing waits for your approval" : "\(count) waiting for your approval",
      systemImage: "checkmark.shield")
  }

  static func count(workflows: WorkflowStore, agents: AgentBridge) -> Int {
    agents.waiting.count + (workflows.confirmation == nil ? 0 : 1) + workflows.unapproved.count
  }
}

/// Everything waiting for the reader: agents' requests, a run about to publish, then workflows to approve.
struct ApprovalsList: View {
  let model: SidebarViewModel
  let workflows: WorkflowStore
  let agents: AgentBridge
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    let requests = agents.waiting
    let publishing = workflows.confirmation
    let unapproved = workflows.unapproved
    VStack(alignment: .leading, spacing: 12) {
      Text("Approvals").font(.headline)
      if requests.isEmpty, publishing == nil, unapproved.isEmpty {
        Text("Nothing waits for your approval.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(requests) { request in
              ApprovalRow(
                systemImage: "powerplug", title: "\(request.client) wants to \(request.summary)",
                detail: "Over Dev's MCP server. Settings ▸ Agents sets what agents may do without asking."
              ) {
                Button("Deny") { agents.answer(request.id, false) }.buttonStyle(.kit)
                Button("Allow") { agents.answer(request.id, true) }.buttonStyle(.kitPrimary)
              }
            }
            if let publishing {
              ApprovalRow(
                systemImage: "paperplane",
                title: "\(publishing.workflowName) in \(publishing.root.lastPathComponent) wants to publish",
                detail: "Started by \(publishing.startedBy). Next: \(publishing.steps.joined(separator: ", "))."
              ) {
                Button("Don't Publish") { workflows.answer(publishing, false) }.buttonStyle(.kit)
                Button("Publish") { workflows.answer(publishing, true) }.buttonStyle(.kitPrimary)
              }
            }
            ForEach(unapproved, id: \.workflow.id.self) { item in
              ApprovalRow(
                systemImage: "arrow.triangle.branch",
                title: "\(item.workflow.name) in \(item.root.lastPathComponent)",
                detail: "\(item.workflow.trigger.summary) is off until you approve it. \(WorkflowApprovals.summary(of: item.workflow))"
              ) {
                Button("Show") { show(item.root) }.buttonStyle(.kit)
                Button("Approve") { workflows.approve(item.workflow, in: item.root) }.buttonStyle(.kitPrimary)
              }
            }
          }
        }
        .frame(maxHeight: 460)
      }
    }
    .padding(16)
  }

  /// Opens the project's Workflows tab, where the workflow's steps are laid out.
  private func show(_ root: URL) {
    let path = root.standardizedFileURL.path
    guard let row = model.projects.first(where: { $0.rootURL?.standardizedFileURL.path == path }) else { return }
    model.selection = .project(row.id)
    model.projectTool = .workflows
    dismiss()
  }
}

/// One thing waiting: what asks and what it would do, and the buttons that answer it.
private struct ApprovalRow<Buttons: View>: View {
  let systemImage: String
  let title: String
  let detail: String
  @ViewBuilder let buttons: Buttons

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(.tint)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          buttons
        }
        .controlSize(.small)
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: KitMetrics.radiusCard))
  }
}
