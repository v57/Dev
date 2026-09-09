//
//  SidebarView.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import SwiftUI

/// Sidebar column of the split view: the 'Projects' section (P20) on top —
/// one row per imported project, with drag-and-drop directory/catalog
/// import — plus the projectless tool mini-status at the bottom.
///
/// The bottom 'Current (no project)' section carries LIVE mini-status rows
/// (P30): an app-icon thumbnail mirroring the shared CreateIcon
/// settings/result and the open-catalog key/needs-review summary from the
/// shared LocalizationStore. Both observables are injected by ContentView at
/// the split level, so these rows update as the tools edit their state.
/// Each row is a NavigationLink onto the same `.tool` selection values the
/// detail pane routes — one source of truth for what is open.
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
        NavigationLink(value: SidebarSelection.tool(.icon)) {
          CurrentIconRow()
        }
        NavigationLink(value: SidebarSelection.tool(.localization)) {
          CurrentLocalizationRow()
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

// MARK: - Current (no project) rows

/// Live mini-status row for the projectless Create Icon tool: a thumbnail
/// mirroring the CURRENT shared CreateIcon settings/result — the same
/// observable the tool edits — so it tracks the editor live. Tap opens the
/// tool via the shared `.tool(.icon)` selection.
private struct CurrentIconRow: View {
  @Environment(CreateIcon.self) private var create

  var body: some View {
    HStack(spacing: 8) {
      CurrentIconThumbnail()
        .frame(width: 26, height: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(SidebarTool.icon.title)
          .lineLimit(1)
        Text(create.settings.preview ? "Rendered PNG" : "Live preview")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 1)
  }
}

/// Mini app-icon thumbnail: mirrors CreateIconView's preview-pane logic —
/// the quantized result PNG when preview mode is on (and one exists), else
/// a live settings render. Reads the shared CreateIcon observable; never
/// re-runs generation.
private struct CurrentIconThumbnail: View {
  @Environment(CreateIcon.self) private var create

  var body: some View {
    Group {
      if create.settings.preview, let result = create.result {
        Image(nsImage: result)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
      } else {
        liveRender
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 6.5))
  }

  /// Tiny live icon: rounded background (flat/gradient) + the SF glyph at
  /// the same proportional size CreateIconView's preview uses.
  private var liveRender: some View {
    GeometryReader { view in
      ZStack {
        if create.settings.gradient {
          LinearGradient(
            colors: [create.settings.primary, create.settings.secondary],
            startPoint: .top, endPoint: .bottom)
        } else {
          create.settings.primary
        }
        Image(systemName: create.settings.symbol)
          .font(.system(size: view.size.width * 0.5 * create.settings.scale))
          .foregroundStyle(create.settings.glyph.opacity(0.8))
      }
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

/// Live mini-status row for the projectless Localization tool: key /
/// needs-review summary of the currently-open catalog from the shared
/// LocalizationStore, or 'No catalog open'. Tap opens the tool via the
/// shared `.tool(.localization)` selection.
private struct CurrentLocalizationRow: View {
  @Environment(LocalizationStore.self) private var localization

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: SidebarTool.localization.systemImage)
        .font(.system(size: 15))
        .foregroundStyle(.tertiary)
        .frame(width: 26, height: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(SidebarTool.localization.title)
          .lineLimit(1)
        summary
      }
    }
    .padding(.vertical, 1)
  }

  @ViewBuilder
  private var summary: some View {
    if localization.isLoaded {
      let needsReview = localization.needsReviewKeyCount
      Text("\(localization.totalKeyCount) keys, \(needsReview) needs review")
        .font(.caption)
        .foregroundStyle(needsReview > 0 ? Color.orange : Color.secondary)
    } else {
      Text("No catalog open")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}
