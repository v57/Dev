import Foundation
import Testing

@testable import DevApp

/// Workflow files written by hand load with only a name and steps (each step its id, name, kind and command): the
/// file name is the id (SSH's Publish libssh2 had no `id`, and Dev listed only the default workflows).
struct WorkflowFileTests {
  @Test func loadsAFileWithoutIDOrTrigger() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "dev-workflow-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = Workflow.folder(in: root)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let json = #"{"name": "Publish libssh2", "steps": [{"id": "release", "name": "Pack", "kind": "command", "command": "Scripts/release-libssh2.sh"}]}"#
    try Data(json.utf8).write(to: folder.appending(path: "libssh2.json"))
    let workflows = Workflow.load(in: root)
    #expect(workflows.map(\.id) == ["libssh2"])
    #expect(workflows.first?.trigger.isSet == false)
    #expect(workflows.first?.steps.first?.command == "Scripts/release-libssh2.sh")
  }

  /// An `ssh:` runner is a build machine over SSH (the x86_64 Linux container): its release step passes the host as
  /// it is, port included; a VM runner still names its UTM machine.
  @Test func sshRunnerNamesItsHost() {
    var step = Workflow.Step(
      id: "archive-linux-x64", name: "Archive · Linux x64", kind: .release, releaseStep: "archive", platform: "linux",
      runner: "ssh:v57@127.0.0.1:2225")
    #expect(step.sshHost == "v57@127.0.0.1:2225")
    #expect(step.vmName == nil)
    #expect(step.commandLine == "release.sh --platform linux --host v57@127.0.0.1:2225 archive")
    step.runner = "vm:Ubuntu"
    #expect(step.sshHost == nil)
    #expect(step.vmName == "Ubuntu")
    step.runner = "ssh:"
    #expect(step.sshHost == nil)
  }
}
