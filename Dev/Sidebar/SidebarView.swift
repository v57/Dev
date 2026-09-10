//
//  SidebarView.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import SwiftUI

/// Sidebar column of the split view: the 'Projects' section (P20) — one row
/// per imported project, with drag-and-drop directory/catalog import — plus
/// the PROJECTLESS tools pinned to the bottom safe area.
///
/// The bottom bar carries the two tools that are NOT bound to a project,
/// with LIVE mini-status: an app-icon thumbnail mirroring the shared
/// CreateIcon settings/result and the open-catalog key/needs-review summary
/// from the shared LocalizationStore. Both observables are injected by
/// ContentView at the split level, so the rows update as the tools edit
/// their state. Each row writes the same `.tool` selection the detail pane
/// routes — one source of truth for what is open.
struct SidebarView: View {
  let model: SidebarViewModel

  /// The shared open-catalog store: the context menu asks it before removing
  /// a project whose catalog it is showing (unsaved edits / a run in flight
  /// refuse the removal, and an idle open catalog is closed with the row).
  @Environment(LocalizationStore.self) private var localization

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
            .contextMenu {
              Button("Remove Project", role: .destructive) {
                model.removeProject(id: row.id, localization: localization)
              }
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    // Projectless tools live here, not in the toolbar picker: the picker is
    // project-bound and only exists while a project is open.
    .safeAreaBar(edge: .bottom) {
      ProjectlessBar(model: model)
    }
    .dropDestination(for: URL.self) { urls, _ in
      // Import searches a dropped directory for its catalog, so it is async.
      // Return true immediately — the drop is accepted — and let the row and
      // its selection land when the walk finishes.
      Task {
        if let firstID = await model.importDroppedURLs(urls) {
          model.selection = .project(firstID)
        }
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
    .alert(model.alert?.title ?? "", isPresented: Binding(
      get: { model.alert != nil },
      set: { if !$0 { model.alert = nil } }
    )) {
      Button("OK") { model.alert = nil }
    } message: {
      Text(model.alert?.message ?? "")
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

// MARK: - Projectless tools (bottom bar)

/// The sidebar's bottom bar: the two PROJECTLESS tools, always reachable
/// while no project is open. Selecting a row routes the detail pane through
/// the same shared selection the project rows use.
private struct ProjectlessBar: View {
  let model: SidebarViewModel

  var body: some View {
    VStack(spacing: 2) {
      ForEach(DevTool.allCases) { tool in
        ProjectlessRow(tool: tool, isSelected: model.currentTool == tool) {
          model.selection = .tool(tool)
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
  }
}

/// One projectless tool row: live mini-status + selection highlight.
private struct ProjectlessRow: View {
  let tool: DevTool
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        ProjectlessThumbnail(tool: tool)
          .frame(width: 24, height: 24)
        VStack(alignment: .leading, spacing: 1) {
          Text(tool.title)
            .lineLimit(1)
          status
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear))
    .help("Open the projectless \(tool.title) tool")
  }

  /// Same at-a-glance status the old list rows carried.
  @ViewBuilder
  private var status: some View {
    switch tool {
    case .icon:
      CreateIconStatus()
    case .localization:
      LocalizationStatus()
    }
  }
}

/// Live summary of the shared CreateIcon settings/result.
private struct CreateIconStatus: View {
  @Environment(CreateIcon.self) private var create

  var body: some View {
    Text(create.settings.preview ? "Rendered PNG" : "Live preview")
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }
}

/// Live summary of the shared LocalizationStore's open catalog.
private struct LocalizationStatus: View {
  @Environment(LocalizationStore.self) private var store

  var body: some View {
    Group {
      if store.isLoaded {
        let needsReview = store.needsReviewKeyCount
        Text("\(store.totalKeyCount) keys, \(needsReview) needs review")
          .foregroundStyle(needsReview > 0 ? Color.orange : Color.secondary)
      } else {
        Text("No catalog open")
          .foregroundStyle(.tertiary)
      }
    }
    .font(.caption)
    .lineLimit(1)
  }
}

/// Mini thumbnail: the shared CreateIcon render for the icon tool, the SF
/// glyph for localization. Never re-runs generation.
private struct ProjectlessThumbnail: View {
  let tool: DevTool
  @Environment(CreateIcon.self) private var create

  var body: some View {
    switch tool {
    case .icon:
      iconThumbnail
    case .localization:
      Image(systemName: DevTool.localization.systemImage)
        .font(.system(size: 15))
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private var iconThumbnail: some View {
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
    .clipShape(RoundedRectangle(cornerRadius: 6))
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
