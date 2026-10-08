//
//  CellBadges.swift
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

/// Per-cell leading indicator: the DB-state dot (needs_review orange,
/// reviewed green, empty none). Reads the live SwiftData record so it updates
/// the moment a run writes the cell.
struct CellStatusAccessory: View {
  let record: TranslationRecord?

  var body: some View {
    if let state = record?.state, state != .empty {
      Circle()
        .fill(state.dotColor)
        .frame(width: 6, height: 6)
        .help(state.displayName)
    }
  }
}

// MARK: - TranslationMemoryBadge

/// "Resolved from cache" glyph: shown when a value was copied from the
/// translation memory instead of being produced by a model.
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
