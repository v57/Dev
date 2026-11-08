//
//  Scan Strings UI.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import ComponentKit
import Foundation
import SwiftUI

/// The Scan Strings report sheet: live progress while the scan runs, then
/// the report and the merge it proposes. Nothing is written to the catalog
/// until the user merges.
struct ScanStringsView: View {
  let store: LocalizationStore

  var body: some View {
    KitSheet(
      title: String(localized: "Scan Strings"),
      meta: String(localized: "Every Swift package and Xcode target under the scan root, merged into this catalog.")
        + (store.scan.root.map { "\n" + $0.path } ?? ""),
      systemImage: "text.magnifyingglass", status: scanStatus, width: 800
    ) {
      content
        .frame(height: 460)
    } footer: {
      footer
    }
  }

  /// The scan's state on the sheet's tile: the share of modules done while it runs.
  private var scanStatus: WorkStatus {
    if store.scan.isRunning {
      return .working(progress: store.scan.progressTotal > 0
        ? Double(store.scan.progressDone) / Double(store.scan.progressTotal) : nil)
    }
    if store.scan.isCommenting { return .working }
    return store.scan.report == nil ? .idle : .done
  }

  // MARK: - content

  @ViewBuilder
  private var content: some View {
    if store.scan.isRunning {
      progressView
    } else if let report = store.scan.report {
      reportView(report)
    } else if let message = store.scan.errorMessage {
      idleView(message: message)
    } else {
      idleView(message: "Picking the scan root…")
    }
  }

  private var progressView: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(store.scan.phase)
          .kitFont(.callout)
          .lineLimit(1)
        Spacer()
        if store.scan.progressTotal > 0 {
          Text("\(store.scan.progressDone)/\(store.scan.progressTotal)")
            .kitFont(.caption)
            .monospacedDigit()
        }
      }
      if store.scan.progressTotal > 0 {
        KitProgressBar(value: Double(store.scan.progressDone) / Double(max(store.scan.progressTotal, 1)))
      }
      KitCodeBlock(lines: store.scan.log, maxHeight: .infinity, followsEnd: true, font: .monoSmall)
    }
    .padding(.horizontal, KitMetrics.gutter)
  }

  private func reportView(_ report: ScanReport) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let message = store.scan.errorMessage {
          banner(message)
        }
        summary(report)
        commentSection
        if let plan = store.scan.plan, !plan.added.isEmpty {
          newKeysSection(plan)
        }
        moduleSection(report)
        if !report.warnings.isEmpty {
          warningsSection(report)
        }
      }
      .padding(.horizontal, KitMetrics.gutter)
    }
  }

  private func summary(_ report: ScanReport) -> some View {
    let projectModules = report.modules.filter { $0.origin == .projectTarget }
    let packageModules = report.modules.filter { $0.origin == .packageTarget }
    return VStack(alignment: .leading, spacing: 4) {
      row("Scan root", report.root.path)
      row("Duration", ScanController.durationText(report.duration))
      row("Packages", "\(report.packages.count) · \(packageModules.count) module(s)")
      row("Xcode targets", "\(projectModules.count) module(s)")
      row("Modules extracted", "\(report.modules.count) (\(report.failedModules.count) failed)")
      row("Keys extracted", "\(report.extractedKeyCount) unique · \(report.totalKeysAcrossModules) key-hits")
      if report.skippedTableKeys > 0 {
        row("Other tables", "\(report.skippedTableKeys) key(s) in non-Localizable tables, skipped")
      }
      if let plan = store.scan.plan {
        row("Merge", "\(plan.addedCount) new · \(plan.existingKeyCount) already in the catalog")
        row("Catalog size", "\(plan.catalogKeyCount) → \(plan.totalAfterMerge) keys")
      }
      if let comments = store.scan.comments, comments.didRun {
        row("Comments", "\(comments.generatedCount) generated · \(comments.skippedCount) skipped"
          + String(format: " · %.2fs each", comments.secondsPerComment))
      }
    }
  }

  // MARK: - comments

  /// The on-device comment pass: what it generated, why it skipped the rest,
  /// and its own control. Nothing here writes the file — a generated comment
  /// is an app-side edit until the user saves (5.8).
  @ViewBuilder
  private var commentSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("Comments", "on-device, from the scan's own source files")
      if store.scan.isCommenting {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text("\(store.scan.commentDone)/\(store.scan.commentTotal) — \(store.scan.commentKey)")
              .kitFont(.callout)
              .lineLimit(1)
            Spacer()
            Button("Stop") { store.scan.cancelCommentPass() }
              .buttonStyle(.kit)
              .help("Stops after the comment in flight; everything already generated stays")
          }
          KitProgressBar(status: .working(progress: Double(store.scan.commentDone) / Double(max(store.scan.commentTotal, 1))))
        }
      } else if let comments = store.scan.comments {
        commentOutcome(comments)
      } else {
        Text("Not run yet.")
          .kitFont(.callout)
          .foregroundStyle(.kitSecondary)
      }
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Button("Generate Comments") { store.scan.startCommentPass() }
          .buttonStyle(.kit)
          .disabled(!canGenerateComments)
        Text("Only keys without a comment are touched; a generated comment lands in the catalog's own comment field (the toolbar's comment toggle shows it under the row) and reaches the file only on Save.")
          .kitFont(.caption)
          .foregroundStyle(.kitSecondary)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .kitSurface(.card)
  }

  private var canGenerateComments: Bool {
    store.scan.report?.cancelled == false
      && !store.scan.isRunning
      && !store.scan.isCommenting
  }

  @ViewBuilder
  private func commentOutcome(_ comments: CommentPassOutcome) -> some View {
    if let reason = comments.unavailableReason {
      VStack(alignment: .leading, spacing: 2) {
        Text("Skipped — \(reason).")
          .kitFont(.callout)
        Text("The scan is unaffected: no comment was generated and nothing was changed.")
          .kitFont(.caption)
          .foregroundStyle(.kitSecondary)
      }
    } else {
      VStack(alignment: .leading, spacing: 3) {
        Text("\(comments.targetCount) key(s) had no comment · \(comments.generatedCount) generated · \(comments.skippedCount) skipped"
          + (comments.cancelled ? " · cancelled" : "")
          + String(format: " · %.2fs per comment", comments.secondsPerComment))
          .kitFont(.callout)
        ForEach(Array(comments.skipLines.enumerated()), id: \.offset) { _, line in
          Text("skipped — \(line.reason.label): \(line.count)")
            .kitFont(.caption)
            .foregroundStyle(.kitSecondary)
        }
        if comments.unlocatedCount > 0 {
          Text("no call site at all — the scan never located \(comments.unlocatedCount) comment-less key(s)")
            .kitFont(.caption)
            .foregroundStyle(.kitSecondary)
        }
        if !comments.generated.isEmpty {
          generatedComments(comments)
        }
      }
    }
  }

  private func generatedComments(_ comments: CommentPassOutcome) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Generated (\(comments.generatedCount))")
        .kitFont(.caption)
        .foregroundStyle(.kitSecondary)
      ForEach(comments.generated.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
        VStack(alignment: .leading, spacing: 1) {
          Text(entry.key)
            .kitFont(.monoSmall)
            .textSelection(.enabled)
            .lineLimit(2)
          Text(entry.value)
            .kitFont(.caption)
            .foregroundStyle(.kitSecondary)
            .textSelection(.enabled)
        }
      }
    }
    .padding(.top, 2)
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label)
        .kitFont(.callout)
        .foregroundStyle(.kitSecondary)
        .frame(width: 150, alignment: .leading)
      Text(value)
        .kitFont(.callout)
        .textSelection(.enabled)
    }
  }

  private func banner(_ message: String) -> some View {
    Banner(message, systemImage: "exclamationmark.triangle", hue: .orange)
  }

  private func sectionTitle(_ title: String, _ detail: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .kitFont(.headline)
      Text(detail)
        .kitFont(.caption)
        .foregroundStyle(.kitSecondary)
    }
  }

  private func newKeysSection(_ plan: ScanMergePlan) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("New keys", "\(plan.addedCount) to add")
      LazyVStack(alignment: .leading, spacing: 4) {
        ForEach(plan.added) { entry in
          VStack(alignment: .leading, spacing: 1) {
            Text(entry.key)
              .kitFont(.mono)
              .textSelection(.enabled)
              .lineLimit(3)
            HStack(spacing: 6) {
              Text(entry.modules.isEmpty ? "—" : entry.modules.joined(separator: ", "))
                .kitFont(.caption)
                .foregroundStyle(.kitTertiary)
              if let comment = entry.comment {
                Text(comment)
                  .kitFont(.caption)
                  .foregroundStyle(.kitSecondary)
                  .lineLimit(2)
              }
            }
          }
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .kitSurface(.card)
    }
  }

  private func moduleSection(_ report: ScanReport) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("Modules", "\(report.modules.count)")
      LazyVStack(alignment: .leading, spacing: 3) {
        ForEach(report.modules) { module in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(module.origin == .packageTarget ? "package" : "project")
              .kitFont(.caption)
              .foregroundStyle(.kitSecondary)
              .frame(width: 52, alignment: .leading)
            Text(module.module)
              .kitFont(.monoSmall)
              .frame(width: 180, alignment: .leading)
              .lineLimit(1)
            if module.failed {
              Text("failed — \(module.detail)")
                .kitFont(.caption)
                .foregroundStyle(Hue.orange.text)
                .lineLimit(2)
            } else {
              Text("\(module.keyCount) keys")
                .kitFont(.caption)
                .foregroundStyle(.kitSecondary)
            }
            if !module.skippedFiles.isEmpty {
              Label("\(module.skippedFiles.count) skipped", systemImage: "exclamationmark.triangle")
                .kitFont(.caption)
                .foregroundStyle(Hue.orange.text)
                .help("Dropped from the compile because they do not typecheck:\n" + module.skippedFiles.joined(separator: "\n"))
            }
            Spacer()
            Text("\(module.fileCount) files")
              .kitFont(.caption)
              .foregroundStyle(.kitTertiary)
          }
          .help(module.directory)
        }
      }
    }
  }

  private func warningsSection(_ report: ScanReport) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("Warnings", "\(report.warnings.count)")
      LazyVStack(alignment: .leading, spacing: 4) {
        ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
          Text(warning)
            .kitFont(.caption)
            .foregroundStyle(.kitSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private func idleView(message: String) -> some View {
    EmptyState(systemImage: "text.magnifyingglass", title: "Scan Strings", message: message) {
      Button("Choose Folder…") { store.scan.chooseRoot() }
        .buttonStyle(.kit)
    }
  }

  // MARK: - footer

  @ViewBuilder
  private var footer: some View {
    if let applied = store.scan.appliedCount {
      SheetStatus(
        applied == 0
          ? "Nothing new to merge"
          : "Merged \(applied) new key\(applied == 1 ? "" : "s") into the catalog",
        systemImage: applied == 0 ? "info.circle" : "checkmark", hue: applied == 0 ? .gray : .green,
        status: applied == 0 ? .idle : .done)
    } else if let plan = store.scan.plan {
      SheetStatus(
        "\(plan.addedCount) new · \(plan.existingKeyCount) already present", systemImage: "text.magnifyingglass")
    } else {
      SheetStatus(store.scan.isRunning ? store.scan.phase : "", systemImage: "text.magnifyingglass", status: scanStatus)
    }
    Button("Copy Report", systemImage: "doc.on.doc") {
      store.scan.copyReport()
    }
    .disabled(store.scan.report == nil)
    Button("Choose Folder…") { store.scan.chooseRoot() }
      .disabled(store.scan.isRunning)
      .kitHelp("Choose Folder", meta: "Scan a different folder — a catalog can live deep inside the repo")
    if store.scan.isRunning || store.scan.isCommenting {
      Button("Cancel") { store.scan.cancel() }
        .keyboardShortcut(.cancelAction)
    } else {
      Button("Scan Again") { store.scan.rescan() }
        .disabled(store.scan.root == nil)
      Button("Close") { store.scan.dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(mergeLabel, systemImage: "square.and.arrow.down") {
        store.applyScan()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(mergeDisabled)
    }
  }

  private var mergeLabel: String {
    let count = store.scan.plan?.addedCount ?? 0
    return count == 0 ? String(localized: "Merge") : String(localized: "Merge \(count) New Key\(count == 1 ? "" : "s")")
  }

  private var mergeDisabled: Bool {
    store.scan.isCommenting
      || store.scan.appliedCount != nil
      || (store.scan.plan?.addedCount ?? 0) == 0
      || (store.scan.report?.cancelled ?? true)
  }
}

#Preview {
  ScanStringsView(store: LocalizationStore())
    .frame(width: 900, height: 600)
}
