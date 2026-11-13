import Foundation
import Testing

@testable import DevApp

/// The sidebar's Approvals list: every agent request waiting, answerable in any order, and the workflow files whose
/// triggers wait for approval.
@MainActor
struct ApprovalsTests {
  @Test func answersAQueuedRequestAndKeepsTheOneOnScreen() {
    let agents = AgentBridge()
    let first = AgentBridge.Pending(id: "approvals-test-1", client: "Agent", summary: "edit", kind: "ask", payload: [:])
    let second = AgentBridge.Pending(id: "approvals-test-2", client: "Agent", summary: "edit", kind: "ask", payload: [:])
    let third = AgentBridge.Pending(id: "approvals-test-3", client: "Agent", summary: "edit", kind: "ask", payload: [:])
    agents.enqueue(first)
    agents.enqueue(second)
    agents.enqueue(third)
    #expect(agents.waiting.map(\.id) == [first.id, second.id, third.id])
    agents.answer(second.id, false)
    #expect(agents.pending?.id == first.id)
    #expect(agents.waiting.map(\.id) == [first.id, third.id])
    agents.answer(first.id, false)
    #expect(agents.pending?.id == third.id)
    agents.answer("unknown", true)
    #expect(agents.waiting.map(\.id) == [third.id])
  }

  @Test func listsWorkflowFilesWithATriggerNobodyApproved() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "dev-approvals-\(UUID().uuidString)")
    let bare = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "dev-approvals-bare-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: bare)
    }
    let folder = Workflow.folder(in: root)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
    let triggered = #"{"name": "Nightly", "trigger": {"daily": "02:00"}, "steps": [{"id": "b", "name": "Build", "kind": "command", "command": "make"}]}"#
    let manual = #"{"name": "By Hand", "steps": [{"id": "b", "name": "Build", "kind": "command", "command": "make"}]}"#
    try Data(triggered.utf8).write(to: folder.appending(path: "nightly.json"))
    try Data(manual.utf8).write(to: folder.appending(path: "manual.json"))
    // A project without workflow files shows Dev's defaults (with triggers), which nobody wrote: not listed.
    let loaded = [root: Workflow.load(in: root), bare: Workflow.load(in: bare)]
    #expect(loaded[bare]?.contains { $0.trigger.isSet } == true)
    #expect(WorkflowStore.unapproved(in: loaded, roots: [root, bare]).map(\.workflow.id) == ["nightly"])
    // A project the sidebar no longer lists drops out.
    #expect(WorkflowStore.unapproved(in: loaded, roots: [bare]).isEmpty)
  }
}
