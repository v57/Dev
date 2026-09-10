//
//  Scan Strings UI.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import AppKit
import SwiftUI

/// The Scan Strings report sheet: live progress while the scan runs, then
/// the report and the merge it proposes. Nothing is written to the catalog
/// until the user merges.
struct ScanStringsView: View {
  let store: LocalizationStore

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .frame(minWidth: 800, minHeight: 560)
  }

  // MARK: - header

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "text.magnifyingglass")
        .font(.title3)
      VStack(alignment: .leading, spacing: 2) {
        Text("Scan Strings")
          .font(.headline)
        Text("Every Swift package and Xcode target under the scan root, merged into this catalog.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let root = store.scan.root {
          Text(root.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
        }
      }
      Spacer()
      Button("Choose Folder…") { store.scan.chooseRoot() }
        .disabled(store.scan.isRunning)
        .help("Scan a different folder — a catalog can live deep inside the repo")
    }
    .padding(12)
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
        ProgressView()
          .controlSize(.small)
        Text(store.scan.phase)
          .font(.callout)
          .lineLimit(1)
        Spacer()
        if store.scan.progressTotal > 0 {
          Text("\(store.scan.progressDone)/\(store.scan.progressTotal)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if store.scan.progressTotal > 0 {
        ProgressView(
          value: Double(store.scan.progressDone),
          total: Double(max(store.scan.progressTotal, 1)))
      }
      logView
    }
    .padding(12)
  }

  private var logView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(store.scan.log.enumerated()), id: \.offset) { index, line in
            Text(line)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .id(index)
          }
        }
        .padding(8)
      }
      .background(Color(nsColor: .textBackgroundColor))
      .onChange(of: store.scan.log.count) { _, _ in
        if let last = store.scan.log.indices.last {
          proxy.scrollTo(last, anchor: .bottom)
        }
      }
    }
  }

  private func reportView(_ report: ScanReport) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let message = store.scan.errorMessage {
          banner(message)
        }
        summary(report)
        if let plan = store.scan.plan, !plan.added.isEmpty {
          newKeysSection(plan)
        }
        moduleSection(report)
        if !report.warnings.isEmpty {
          warningsSection(report)
        }
      }
      .padding(12)
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
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: 150, alignment: .leading)
      Text(value)
        .font(.callout)
        .textSelection(.enabled)
    }
  }

  private func banner(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.orange)
      Text(message)
        .font(.callout)
      Spacer()
    }
    .padding(10)
    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
  }

  private func sectionTitle(_ title: String, _ detail: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func newKeysSection(_ plan: ScanMergePlan) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("New keys", "\(plan.addedCount) to add")
      LazyVStack(alignment: .leading, spacing: 4) {
        ForEach(plan.added) { entry in
          VStack(alignment: .leading, spacing: 1) {
            Text(entry.key)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
              .lineLimit(3)
            HStack(spacing: 6) {
              Text(entry.modules.isEmpty ? "—" : entry.modules.joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
              if let comment = entry.comment {
                Text(comment)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
          }
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
  }

  private func moduleSection(_ report: ScanReport) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("Modules", "\(report.modules.count)")
      LazyVStack(alignment: .leading, spacing: 3) {
        ForEach(report.modules) { module in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(module.origin == .packageTarget ? "package" : "project")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .frame(width: 52, alignment: .leading)
            Text(module.module)
              .font(.system(.caption, design: .monospaced))
              .frame(width: 180, alignment: .leading)
              .lineLimit(1)
            if module.failed {
              Text("failed — \(module.detail)")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
            } else {
              Text("\(module.keyCount) keys")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !module.skippedFiles.isEmpty {
              Label("\(module.skippedFiles.count) skipped", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help("Dropped from the compile because they do not typecheck:\n" + module.skippedFiles.joined(separator: "\n"))
            }
            Spacer()
            Text("\(module.fileCount) files")
              .font(.caption2)
              .foregroundStyle(.tertiary)
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
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private func idleView(message: String) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "text.magnifyingglass")
        .font(.system(size: 40))
        .foregroundStyle(.tertiary)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Choose Folder…") { store.scan.chooseRoot() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  // MARK: - footer

  private var footer: some View {
    HStack(spacing: 10) {
      Button {
        store.scan.copyReport()
      } label: {
        Label("Copy Report", systemImage: "doc.on.doc")
      }
      .disabled(store.scan.report == nil)

      if let applied = store.scan.appliedCount {
        Label(
          applied == 0
            ? "Nothing new to merge"
            : "Merged \(applied) new key\(applied == 1 ? "" : "s") into the catalog",
          systemImage: applied == 0 ? "info.circle" : "checkmark.circle")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else if let plan = store.scan.plan {
        Text("\(plan.addedCount) new · \(plan.existingKeyCount) already present")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if store.scan.isRunning {
        Button("Cancel") { store.scan.cancel() }
      } else {
        Button("Scan Again") { store.scan.rescan() }
          .disabled(store.scan.root == nil)
        Button {
          store.applyScan()
        } label: {
          Label(mergeLabel, systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(mergeDisabled)
        Button("Close") { store.scan.dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(12)
  }

  private var mergeLabel: String {
    let count = store.scan.plan?.addedCount ?? 0
    return count == 0 ? "Merge" : "Merge \(count) New Key\(count == 1 ? "" : "s")"
  }

  private var mergeDisabled: Bool {
    store.scan.appliedCount != nil
      || (store.scan.plan?.addedCount ?? 0) == 0
      || (store.scan.report?.cancelled ?? true)
  }
}

#Preview {
  ScanStringsView(store: LocalizationStore())
    .frame(width: 900, height: 600)
}
