//
//  WorkflowApprovals.swift
//  Dev
//

import CryptoKit
import Foundation
import Synchronization

/// The workflows the reader approved, by content: a trigger or an agent starts a run only when the workflow's
/// file is exactly what was approved in the app (security audit H6). A workflow comes from the repository
/// (`.dev/workflows/*.json`), so a pulled commit, a cloned project or an agent's `set_workflow` can add or change
/// one; until the reader looks at its steps and approves it, it runs only from the Run button.
///
/// Kept in Dev's keychain item, one per project folder, not in UserDefaults or the project, where the same
/// commit or a `defaults write` could approve itself.
nonisolated enum WorkflowApprovals {
  static let service = "dev.v57.dev.workflow-approvals"

  /// The workflow's content hash: every field, ids and triggers included, in a stable encoding.
  static func hash(_ workflow: Workflow) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(workflow)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func isApproved(_ workflow: Workflow, in root: URL) -> Bool {
    approved(in: root)[workflow.id] == hash(workflow)
  }

  /// Records the workflow as it is now; a later change to its file needs approving again.
  static func approve(_ workflow: Workflow, in root: URL) {
    var all = approved(in: root)
    let hash = hash(workflow)
    guard all[workflow.id] != hash else { return }
    all[workflow.id] = hash
    save(all, in: root)
  }

  /// Drops the approval of a deleted workflow, so a new file with the same id isn't approved by accident.
  static func forget(_ id: String, in root: URL) {
    var all = approved(in: root)
    guard all.removeValue(forKey: id) != nil else { return }
    save(all, in: root)
  }

  /// Workflow id → approved hash, for one project folder.
  static func approved(in root: URL) -> [String: String] {
    let account = account(for: root)
    if let cached = cache.withLock({ $0[account] }) { return cached }
    let stored = DevKeychain.read(service: service, account: account)
      .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
    cache.withLock { $0[account] = stored }
    return stored
  }

  private static func save(_ approved: [String: String], in root: URL) {
    let account = account(for: root)
    cache.withLock { $0[account] = approved }
    guard let data = try? JSONEncoder().encode(approved), let text = String(data: data, encoding: .utf8) else { return }
    _ = DevKeychain.write(text, service: service, account: account, label: "Dev: approved workflows")
  }

  /// What the keychain held per folder, for this process's life: the Workflows tab asks on every redraw.
  /// Only `save` writes, and it updates this.
  private static let cache = Mutex([String: [String: String]]())

  private static func account(for root: URL) -> String {
    let path = root.standardizedFileURL.path
    return SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  /// The commands a workflow would run, one line per step, for the approval questions.
  static func summary(of workflow: Workflow) -> String {
    workflow.steps.map { step in
      let runner = (step.vmName ?? step.sshHost).map { " (on \($0))" } ?? ""
      return "\(step.name): \(step.commandLine)\(runner)"
    }.joined(separator: "; ")
  }
}
