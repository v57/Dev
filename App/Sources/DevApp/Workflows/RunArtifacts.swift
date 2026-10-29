//
//  RunArtifacts.swift
//  Dev
//

import ComponentKit
import Foundation
import SwiftUI

/// The files a workflow run made, by platform, under the run's steps in the Workflows tab: each opens, shows in
/// Finder, or goes to the Trash; the run's result archive exports to wherever the reader picks (made first when
/// the workflow had no Result Archive step), and the whole run goes to the Trash with its folder.
struct RunArtifacts: View {
  let run: WorkflowRun
  let root: URL
  /// The run went: the tab picks another.
  var onDelete: () -> Void = {}

  @Environment(WorkflowStore.self) private var store
  @State private var deleting: WorkflowRun.Artifact?
  @State private var deletingRun = false
  @State private var isExporting = false

  private var isFinished: Bool { run.state != .running }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("Files")
          .kitFont(.headline)
        Count(run.files.count)
        if run.totalSize > 0 {
          Text(run.totalSize.byteString)
            .kitFont(.caption)
            .foregroundStyle(.kitSecondary)
        }
        Spacer()
        if let output = run.output {
          Button("Show Folder") { KitDesktop.reveal([URL(fileURLWithPath: output)]) }
            .disabled(!FileManager.default.fileExists(atPath: output))
        }
        Button(isExporting ? "Exporting…" : "Export…") { Task { await export() } }
          .disabled(!isFinished || isExporting || run.files.isEmpty)
          .help("Saves the result archive: every platform's files and a manifest in one zip")
        if isFinished {
          Button("Delete Run…", role: .destructive) { deletingRun = true }
            .help("Moves the run's folder to the Trash and removes the run")
        }
      }
      .buttonStyle(.kit)
      ForEach(groups, id: \.title) { group in
        FormCard(group.title) {
          ForEach(group.files) { file in row(file) }
        }
      }
      if let output = run.output {
        Text(output.replacingOccurrences(of: root.path + "/", with: ""))
          .kitFont(.monoSmall)
          .foregroundStyle(.kitSecondary)
          .textSelection(.enabled)
      }
    }
    .kitConfirmation(
      "Move \(deleting?.name ?? "") to the Trash?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      message: "It leaves this run's files.", systemImage: "trash", confirm: "Move to Trash"
    ) {
      guard let file = deleting else { return }
      do { try store.deleteArtifact(file, of: run.id, in: root) } catch { store.notice = error.localizedDescription }
    }
    .kitConfirmation(
      "Delete this run?", isPresented: $deletingRun,
      message: "Its folder and every file in it (\(run.totalSize.byteString)) go to the Trash, and the run leaves the history.",
      systemImage: "trash", confirm: "Delete Run"
    ) {
      do {
        try store.deleteRun(run.id, in: root)
        onDelete()
      } catch {
        store.notice = error.localizedDescription
      }
    }
  }

  /// The files by platform in release order, the result archive and its manifest last.
  private var groups: [(title: String, files: [WorkflowRun.Artifact])] {
    var groups = ReleasePlatform.allCases.compactMap { platform -> (String, [WorkflowRun.Artifact])? in
      let files = run.files.filter { $0.platform == platform.rawValue }
      return files.isEmpty ? nil : (platform.title, files)
    }
    let all = run.files.filter { ReleasePlatform(rawValue: $0.platform) == nil }
    if !all.isEmpty { groups.append(("Result archive", all)) }
    return groups
  }

  private func row(_ file: WorkflowRun.Artifact) -> some View {
    let exists = FileManager.default.fileExists(atPath: file.path)
    return GroupRow {
      HStack(spacing: 8) {
        KitFileCell(file.name, isFolder: file.isFolder, systemImage: Self.systemImage(for: file))
        Chip(Self.kindTitle(file.kind), style: .quiet)
      }
      .opacity(exists ? 1 : 0.5)
    } trailing: {
      HStack(spacing: 4) {
        Text(exists ? (file.size?.byteString ?? "") : "Missing")
          .kitFont(.caption)
          .monospacedDigit()
          .foregroundStyle(.kitSecondary)
        Button("Open", systemImage: "arrow.up.forward.app") { KitDesktop.open(file.url) }
          .help("Open \(file.name)")
          .disabled(!exists)
        Button("Show in Finder", systemImage: "folder") { KitDesktop.reveal([file.url]) }
          .help("Show in Finder")
          .disabled(!exists)
        if WorkflowStore.canDelete(file, of: run) {
          Button("Move to Trash", systemImage: "trash", role: .destructive) { deleting = file }
            .help("Move \(file.name) to the Trash")
            .disabled(!isFinished)
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.kitPlain)
    }
    .kitContextMenu {
      Button("Open", systemImage: "arrow.up.forward.app") { KitDesktop.open(file.url) }
      Button("Show in Finder", systemImage: "folder") { KitDesktop.reveal([file.url]) }
      Button("Copy Path", systemImage: "doc.on.doc") { KitPasteboard.copy(file.path) }
      if WorkflowStore.canDelete(file, of: run), isFinished {
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { deleting = file }
      }
    }
  }

  static func kindTitle(_ kind: String) -> String {
    switch kind {
    case "archive": return "Archive"
    case "package": return "Download"
    case "bundle": return "Result archive"
    case "manifest": return "Manifest"
    case "tests": return "Test results"
    case "screenshots": return "Screenshots"
    default: return kind.capitalized
    }
  }

  static func systemImage(for file: WorkflowRun.Artifact) -> String? {
    switch file.kind {
    case "archive": return "archivebox"
    case "bundle": return "shippingbox"
    case "manifest": return "list.bullet.rectangle"
    case "tests": return "checkmark.seal"
    case "screenshots": return "photo.on.rectangle"
    default: return nil
    }
  }

  /// Saves the result archive where the reader picks.
  private func export() async {
    isExporting = true
    defer { isExporting = false }
    guard let bundle = await store.makeBundle(for: run.id, in: root),
          let target = await KitDesktop.chooseSaveLocation(
            title: "Export Result Archive", prompt: "Export", name: bundle.name)
    else { return }
    let source = bundle.url
    let error: String? = await Task.detached(priority: .userInitiated) {
      do {
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
        return nil
      } catch {
        return error.localizedDescription
      }
    }.value
    if let error { store.notice = error } else { KitDesktop.reveal([target]) }
  }
}
