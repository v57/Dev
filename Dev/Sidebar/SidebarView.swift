//
//  SidebarView.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import SwiftUI

/// Sidebar column of the split view, in the order the reader uses it:
///  - Projects: one row per imported project (drag a folder in, or + ▸ Add Project…),
///    with the count of strings waiting for review;
///  - Tools: what works without a project (Storage, Virtual Machines);
///  - Localization Servers.
/// The + menu at the foot adds a project or a server, so nothing depends on
/// dragging. Each row writes the one selection the detail pane routes.
struct SidebarView: View {
  let model: SidebarViewModel

  /// The shared open-catalog store: the context menu asks it before removing
  /// a project whose catalog it is showing (unsaved edits / a run in flight
  /// refuse the removal, and an idle open catalog is closed with the row).
  @Environment(LocalizationStore.self) private var localization
  /// The Localization Servers this app works against, and their last check.
  @Environment(ServerStore.self) private var servers
  /// Which server the form sheet is adding or editing (nil = no sheet). Owned
  /// here so the + menu, the empty-state row and a row's Edit… all open the
  /// SAME sheet.
  @State private var serverSheet: ServerSheet?

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
              if let root = row.rootURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                Divider()
              }
              Button("Remove Project", role: .destructive) {
                model.removeProject(id: row.id, localization: localization)
              }
            }
          }
        }
      }
      Section("Tools") {
        NavigationLink(value: SidebarSelection.storage) {
          StorageSidebarRow()
        }
        NavigationLink(value: SidebarSelection.vms) {
          VMsSidebarRow()
        }
      }
      ServersSidebarSection(
        store: servers,
        selection: $model.selection) { sheet in
          serverSheet = sheet
        }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      bottomBar
    }
    .sheet(item: $serverSheet) { sheet in
      switch sheet {
      case .add:
        ServerFormView { name, endpoint, key in
          // The id the new server gets is not needed here: the sheet closes and
          // the row appears in the list. An untouched key field arrives as nil
          // and means the shared key, i.e. no own keychain item.
          _ = servers.add(name: name, endpoint: endpoint, key: key ?? "")
        }
      case .edit(let id):
        ServerFormView(editing: servers.connection(id: id)) { name, endpoint, key in
          servers.update(id: id, name: name, endpoint: endpoint, key: key)
        }
      }
    }
    // First sight of the sidebar: build the rows, then ask every server how it
    // is doing. Nothing polls after this — a check is a reader action.
    .task {
      servers.refresh()
      await servers.checkAll()
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
    .sheet(isPresented: Binding(
      get: { !model.importSuggestions.isEmpty },
      set: { if !$0 { model.importSuggestions = [] } }
    )) {
      ImportSuggestionsSheet(suggestions: model.importSuggestions) { urls in
        Task {
          if let firstID = await model.addSuggestedDirectories(urls) {
            model.selection = .project(firstID)
          }
        }
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

  /// The foot of the sidebar: one + menu for everything the sidebar lists.
  private var bottomBar: some View {
    HStack(spacing: 4) {
      Menu {
        Button("Add Project…") { model.addProjectsFromPanel() }
        Button("Add Localization Server…") { serverSheet = .add }
      } label: {
        Image(systemName: "plus")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.visible)
      .fixedSize()
      .help("Add a project or a Localization Server")
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  /// Empty Projects section: still a drop target, so the hint invites the
  /// one gesture that fills it, and the + menu offers the panel.
  private var dropHintRow: some View {
    VStack(spacing: 6) {
      Image(systemName: "folder.badge.plus")
        .font(.title3)
        .foregroundStyle(.secondary)
      Text("Drop project folders here")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1.5, dash: [5])))
  }
}

// MARK: - Project row

/// One project row: its app icon, its name, and how many strings wait for review.
private struct ProjectRow: View {
  let row: SidebarProjectRow
  @AppStorage(SidebarPreferences.showReviewBadge) private var showsReviewBadge = true

  var body: some View {
    HStack(spacing: 8) {
      thumbnail
        .frame(width: 20, height: 20)
      Text(row.name)
        .lineLimit(1)
      Spacer(minLength: 4)
      if showsReviewBadge, row.needsReview > 0 {
        Text(row.needsReview, format: .number.notation(.compactName))
          .font(.caption.weight(.semibold))
          .monospacedDigit()
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(Color.orange.opacity(0.18), in: Capsule())
          .foregroundStyle(Color.orange)
          .help("\(row.needsReview) strings need review")
      }
    }
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
        .foregroundStyle(.secondary)
    }
  }
}

