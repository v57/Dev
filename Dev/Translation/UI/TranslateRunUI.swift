//
//  TranslateRunUI.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import SwiftUI

// MARK: - TranslationState (colors)

extension TranslationState {
  /// State-dot color: machine output orange, human-confirmed green. Empty
  /// carries no dot (the accessory renders nothing for it).
  var dotColor: Color {
    switch self {
    case .empty: return .clear
    case .needs_review: return .orange
    case .reviewed: return .green
    }
  }
}

// MARK: - CellStatusAccessory

/// Per-cell leading indicator: a small spinner while the record's
/// translation is in flight, otherwise the DB-state dot (needs_review
/// orange, reviewed green, empty none). Reads the live SwiftData record so
/// it updates the moment the pipeline writes the cell.
struct CellStatusAccessory: View {
  let record: TranslationRecord?
  let isInFlight: Bool

  var body: some View {
    if isInFlight {
      ProgressView()
        .controlSize(.small)
        .help("Translating…")
    } else if let state = record?.state, state != .empty {
      Circle()
        .fill(state.dotColor)
        .frame(width: 6, height: 6)
        .help(state.displayName)
    }
  }
}

// MARK: - TranslationMemoryBadge

/// "Resolved from cache" glyph: shown when a value was copied from the
/// translation memory instead of being produced by this run's stages.
struct TranslationMemoryBadge: View {
  let record: TranslationRecord

  var body: some View {
    Image(systemName: "clock.arrow.circlepath")
      .font(.system(size: 9))
      .foregroundStyle(.secondary)
      .help(record.state == .reviewed
        ? "Resolved from translation memory — human-confirmed copy (gold)"
        : "Resolved from translation memory — machine hint")
  }
}

// MARK: - AutoReviewedBadge

/// "auto" badge shown on cells whose value came from the imported
/// translation DB (record.state .reviewed + autoReviewed). ONE CLICK is the
/// human confirm: the badge calls back, the store clears the auto marker
/// (value now counts as human-reviewed) and upserts the TM gold entry.
struct AutoReviewedBadge: View {
  let confirm: () -> Void

  var body: some View {
    Button(action: confirm) {
      Text("auto")
        .font(.system(size: 8, weight: .semibold))
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Color.green.opacity(0.14), in: Capsule())
        .foregroundStyle(.green)
    }
    .buttonStyle(.plain)
    .help("Imported translation DB — automatically reviewed. Click to confirm as human-reviewed.")
  }
}

// MARK: - TranslateRunStatus

/// The footer's right-hand run surface: live stage progress + Cancel while
/// a run is active, then a one-line summary of the last run. Attach the log
/// tail as a tooltip so failures stay inspectable without a log panel.
struct TranslateRunStatus: View {
  let controller: TranslateRunController

  var body: some View {
    Group {
      if controller.isRunning {
        runningView
      } else if let summary = controller.summary {
        doneView(summary)
      }
    }
  }

  private var runningView: some View {
    HStack(spacing: 6) {
      let progress = controller.progress
      ProgressView(
        value: Double(progress.completed),
        total: Double(max(progress.total, 1)))
        .controlSize(.small)
        .frame(width: 80)
      Text("\(progress.stage.label) \(progress.completed)/\(progress.total)")
        .foregroundStyle(.secondary)
      if progress.failed > 0 {
        Text("· \(progress.failed) failed")
          .foregroundStyle(.orange)
      }
      Button("Cancel") {
        controller.cancel()
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .help("Stop after the current batch")
    }
    .help(controller.progress.log.suffix(12).joined(separator: "\n"))
  }

  private func doneView(_ summary: PipelineRunSummary) -> some View {
    HStack(spacing: 6) {
      Image(systemName: summary.cancelled
        ? "stop.circle"
        : summary.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
        .foregroundStyle(summary.cancelled || !summary.failures.isEmpty
          ? Color.orange : Color.green)
      Text("Last run — \(summaryLine(summary))")
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .help(failureHelp(summary))
  }

  private func summaryLine(_ summary: PipelineRunSummary) -> String {
    var parts: [String] = []
    if summary.cancelled {
      parts.append("cancelled")
    }
    if summary.recordsTouched > 0 {
      parts.append("\(summary.recordsTouched) touched")
    }
    if !summary.failures.isEmpty {
      parts.append("\(summary.failures.count) failed")
    }
    if parts.isEmpty {
      return "nothing to translate"
    }
    return parts.joined(separator: " · ")
  }

  private func failureHelp(_ summary: PipelineRunSummary) -> String {
    guard !summary.failures.isEmpty else { return "" }
    return summary.failures.prefix(15).joined(separator: "\n")
  }
}
