//
//  SidebarView.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import SwiftUI

/// Sidebar column of the split view: the 'Projects' section (P20) on top —
/// one row per imported project, with drag-and-drop directory/catalog
/// import — plus the projectless tool rows at the bottom.
///
/// The bottom section is the seam card P30 fills with the live 'Current
/// (no project)' mini-status (app-icon thumbnail + open-catalog summary).
/// Until P30 lands, the two plain rows below keep the tools reachable and
/// carry the same `.tool` selection values P30's live rows will use.
struct SidebarView: View {
  let model: SidebarViewModel

  var body: some View {
    @Bindable var model = model
    List(selection: $model.selection) {
      Section("Projects") {
        if model.projects.isEmpty {
          dropHintRow
        } else {
          ForEach(model.projects) { row in
            NavigationLink(value: SidebarSelection.project(row.id)) {
              ProjectRow(row: row)
            }
          }
        }
      }
      Section("Current (no project)") {
        ForEach(SidebarTool.allCases) { tool in
          NavigationLink(value: SidebarSelection.tool(tool)) {
            Label(tool.title, systemImage: tool.systemImage)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .dropDestination(for: URL.self) { urls, _ in
      let firstID = model.importDroppedURLs(urls)
      if let firstID {
        model.selection = .project(firstID)
      }
      return true
    } isTargeted: {
      model.isDropTargeted = $0
    }
    .overlay {
      if model.isDropTargeted {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
          .padding(6)
          .allowsHitTesting(false)
      }
    }
    .alert("Import failed", isPresented: Binding(
      get: { model.importError != nil },
      set: { if !$0 { model.importError = nil } }
    )) {
      Button("OK") { model.importError = nil }
    } message: {
      Text(model.importError ?? "")
    }
    .task { model.refresh() }
    .onChange(of: model.selection) {
      // A selection usually precedes a reconcile (catalog open); refresh so
      // badges track the record state the interaction just changed.
      model.refresh()
    }
  }

  /// Empty Projects section: still a drop target, so the hint invites the
  /// one gesture that fills it.
  private var dropHintRow: some View {
    HStack(spacing: 8) {
      Image(systemName: "folder.badge.plus")
        .foregroundStyle(.tertiary)
      Text("Drag a project folder here")
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Project row

/// One project row: icon thumbnail + display name + compact translation
/// badge (needs-review keys / total keys from the reconciled records).
private struct ProjectRow: View {
  let row: SidebarProjectRow

  var body: some View {
    HStack(spacing: 8) {
      thumbnail
        .frame(width: 26, height: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.name)
          .lineLimit(1)
        badge
      }
    }
    .padding(.vertical, 1)
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
        .font(.system(size: 15))
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private var badge: some View {
    if row.hasRecords {
      Text("\(row.needsReviewKeyCount) needs review · \(row.keyCount) keys")
        .font(.caption)
        .foregroundStyle(row.needsReviewKeyCount > 0 ? Color.orange : Color.secondary)
    } else if row.catalogExists {
      Text("Not opened yet")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Text("No catalog")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}
