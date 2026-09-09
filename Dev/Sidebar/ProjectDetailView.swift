//
//  ProjectDetailView.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import SwiftUI

/// Detail pane for a SELECTED sidebar project.
///
/// Transitional surface for card P20: an at-a-glance project panel so a
/// selection visibly drives the detail pane. Card P40 replaces this body
/// with the project-bound tools (Create Icon exporting into the project
/// root, Localization opening the project's catalog) — it reads the same
/// `SidebarSelection.project` from the shared view model.
struct ProjectDetailView: View {
  let row: SidebarProjectRow

  var body: some View {
    VStack(spacing: 14) {
      thumbnail
        .frame(width: 96, height: 96)
      Text(row.name)
        .font(.title2)
      VStack(alignment: .leading, spacing: 6) {
        pathLine(
          title: "Root",
          text: row.rootURL?.path ?? "—",
          icon: "folder")
        pathLine(
          title: "Catalog",
          text: row.catalogURL.path + (row.catalogExists ? "" : " (missing)"),
          icon: "doc.text")
        statusLine
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: 520)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var thumbnail: some View {
    if let icon = row.iconImage {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
    } else {
      Image(systemName: "folder")
        .font(.system(size: 56))
        .foregroundStyle(.tertiary)
    }
  }

  private func pathLine(title: String, text: String, icon: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: icon)
        .foregroundStyle(.tertiary)
        .frame(width: 16)
      Text(title + ":")
        .foregroundStyle(.secondary)
      Text(text)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  @ViewBuilder
  private var statusLine: some View {
    if row.hasRecords {
      Label(
        row.needsReviewKeyCount > 0
          ? "\(row.needsReviewKeyCount) keys need review of \(row.keyCount)"
          : "\(row.keyCount) keys — all reviewed",
        systemImage: row.needsReviewKeyCount > 0
          ? "exclamationmark.magnifyingglass"
          : "checkmark.circle")
        .foregroundStyle(row.needsReviewKeyCount > 0 ? Color.orange : Color.secondary)
    } else if row.catalogExists {
      Label("Catalog not opened yet", systemImage: "clock")
        .foregroundStyle(.secondary)
    } else {
      Label("No catalog file in this project", systemImage: "questionmark.circle")
        .foregroundStyle(.tertiary)
    }
  }
}
