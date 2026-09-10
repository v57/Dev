//
//  RowInspectorView.swift
//  Dev
//

import Foundation
import SwiftUI

// MARK: - RowInspectorView

/// Overlay for a single-row test. Shows, step by step, which model served the
/// request, what the deterministic stages decided, and — in learning mode —
/// the ContextDoc before and after the fold.
struct RowInspectorView: View {
  let store: LocalizationStore
  @Environment(\.dismiss) private var dismiss

  private var trace: TranslationTrace { store.trace }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .frame(minWidth: 660, idealWidth: 780, minHeight: 480, idealHeight: 640)
  }

  // MARK: header

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: trace.mode == .learning ? "graduationcap" : "translate")
          .foregroundStyle(.secondary)
        Text(trace.key.isEmpty ? "Row inspection" : trace.key)
          .font(.headline)
          .lineLimit(1)
          .textSelection(.enabled)
        Text(trace.mode.rawValue)
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.accentColor.opacity(0.16)))
        if trace.isRunning {
          ProgressView().controlSize(.small)
        }
        Spacer(minLength: 12)
        Button {
          let key = trace.key
          store.trace.reset()
          store.inspect(key)
        } label: {
          Label("Re-run", systemImage: "arrow.clockwise")
        }
        .disabled(trace.isRunning || trace.key.isEmpty)
      }
      if !modelChips.isEmpty || trace.duration != nil {
        HStack(spacing: 6) {
          Text("Models:")
            .font(.caption)
            .foregroundStyle(.tertiary)
          ForEach(modelChips, id: \.model) { chip in
            modelChip(chip.model, isPaid: chip.isPaid)
          }
          if let duration = trace.duration {
            Text(String(format: "· %.1fs", duration))
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          Spacer(minLength: 0)
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }

  // MARK: body

  @ViewBuilder
  private var content: some View {
    if trace.steps.isEmpty {
      VStack(spacing: 10) {
        Image(systemName: trace.isRunning ? "hourglass" : "text.magnifyingglass")
          .font(.system(size: 34))
          .foregroundStyle(.tertiary)
        Text(trace.isRunning ? "Running…" : "No steps recorded")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(trace.steps) { step in
            stepRow(step)
          }
        }
        .padding(20)
      }
    }
  }

  private func stepRow(_ step: TranslationTrace.Step) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Image(systemName: step.kind.symbol)
          .foregroundStyle(step.isFailure ? Color.orange : Color.secondary)
          .frame(width: 18)
        Text(step.kind.label)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 62, alignment: .leading)
        Text(step.title)
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        if let model = step.model {
          modelChip(model, isPaid: step.isPaid ?? false, compact: true)
        }
      }
      if let input = step.input { detailBox("in", input, tint: .secondary) }
      if let output = step.output { detailBox("out", output, tint: step.isFailure ? .orange : .primary) }
      if step.hasDocumentDelta { documentDelta(step) }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.secondary.opacity(step.isFailure ? 0.14 : 0.06)))
  }

  /// Before/after ContextDoc, with the changed lines called out.
  private func documentDelta(_ step: TranslationTrace.Step) -> some View {
    let before = step.before ?? ""
    let after = step.after ?? ""
    let diff = TranslationTrace.lineDiff(before: before, after: after)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("ContextDoc")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        if diff.added.isEmpty, diff.removed.isEmpty {
          Text("unchanged")
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else {
          Text("+\(diff.added.count) −\(diff.removed.count) line(s)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      HStack(alignment: .top, spacing: 10) {
        documentPane(title: "before", text: before, lines: diff.removed, tint: .red)
        documentPane(title: "after", text: after, lines: diff.added, tint: .green)
      }
    }
  }

  private func documentPane(title: String, text: String, lines: [String], tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          if text.isEmpty {
            Text("(empty)")
              .font(.caption.monospaced())
              .foregroundStyle(.tertiary)
          } else {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
              let line = String(raw)
              Text(line)
                .font(.caption.monospaced())
                .foregroundStyle(lines.contains(line) ? tint : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        .padding(6)
      }
      .frame(maxHeight: 190)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
    }
  }

  private func detailBox(_ label: String, _ text: String, tint: Color) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(label)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .frame(width: 20, alignment: .leading)
      Text(text)
        .font(.caption.monospaced())
        .foregroundStyle(tint)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: footer

  private var footer: some View {
    HStack(spacing: 10) {
      Image(systemName: trace.isRunning
        ? "hourglass"
        : trace.failureCount == 0 ? "checkmark.circle" : "exclamationmark.triangle")
        .foregroundStyle(trace.isRunning
          ? Color.secondary
          : trace.failureCount == 0 ? Color.green : Color.orange)
      Text(TranslationRouter.shared.telemetrySummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(TranslationRouter.shared.lastError ?? "Routing telemetry for this session")
      Spacer(minLength: 12)
      Button("Close") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  // MARK: chips & helpers

  private var modelChips: [(model: String, isPaid: Bool)] {
    var out: [(model: String, isPaid: Bool)] = []
    for step in trace.steps {
      guard let model = step.model else { continue }
      if out.contains(where: { $0.model == model }) { continue }
      out.append((model, step.isPaid ?? false))
    }
    return out
  }

  private func modelChip(_ model: String, isPaid: Bool, compact: Bool = false) -> some View {
    HStack(spacing: 4) {
      Image(systemName: isPaid ? "creditcard" : "leaf")
        .font(.caption2)
      Text(model)
        .font(.caption2.weight(.medium))
        .lineLimit(1)
    }
    .padding(.horizontal, compact ? 6 : 7)
    .padding(.vertical, 2)
    .background(
      Capsule().fill(isPaid ? Color.orange.opacity(0.16) : Color.green.opacity(0.16)))
    .foregroundStyle(isPaid ? Color.orange : Color.green)
    .help(isPaid ? "Paid model" : "Free tier")
  }
}
