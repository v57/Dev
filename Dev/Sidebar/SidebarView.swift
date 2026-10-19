//
//  SidebarView.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import ComponentKit
import SwiftUI
import VaultKit

/// Sidebar column of the split view, in the order the reader uses it:
///  - Projects: one row per imported project (drag a folder in, or + ▸ Add Project…),
///    with the count of strings waiting for review;
///  - Tools: what works without a project (Storage, Virtual Machines);
///  - Localization Servers.
/// Each section is a kit card; the + in a section's header and the + menu in the bottom bar
/// add a project or a server, so nothing depends on dragging. Each row writes the one
/// selection the detail pane routes.
struct SidebarView: View {
  let model: SidebarViewModel

  /// The shared open-catalog store: the context menu asks it before removing
  /// a project whose catalog it is showing (unsaved edits / a run in flight
  /// refuse the removal, and an idle open catalog is closed with the row).
  @Environment(LocalizationStore.self) private var localization
  /// The Localization Servers this app works against, and their last check.
  @Environment(ServerStore.self) private var servers
  /// The Storage tool's last scan: the Tools section sums it up.
  @Environment(StorageStore.self) private var storage
  /// Which server the form sheet is adding or editing (nil = no sheet). Owned
  /// here so the + menu, the empty-state row and a row's Edit… all open the
  /// SAME sheet.
  @State private var serverSheet: ServerSheet?
  /// The bottom bar's search: it narrows the Projects section by name.
  @State private var search = ""
  /// The bottom bar's + menu is open.
  @State private var showsAddMenu = false
  /// The project groups closed in the Projects section (vault group ids).
  @AppStorage("CollapsedProjectGroups") private var collapsedGroups = CollapsedGroups()

  var body: some View {
    @Bindable var model = model
    KitSidebar(selection: $model.selection, searchText: $search, searchPrompt: "Search Projects") {
      projectsSection
      KitSection("Tools", meta: storage.sidebarStatus, systemImage: "wrench.and.screwdriver", hue: .orange) {
        StorageSidebarRow()
        VMsSidebarRow()
      }
      ServersSidebarSection(
        store: servers,
        selection: $model.selection) { sheet in
          serverSheet = sheet
        }
    } bottomBar: {
      Button("Add", systemImage: "plus") { showsAddMenu = true }
        .kitMenu(isPresented: $showsAddMenu) {
          Button("Add Project…", systemImage: "folder.badge.plus") { model.addProjectsFromPanel() }.kitMenuHint("⇧⌘O")
          Button("Add Localization Server…", systemImage: "server.rack") { serverSheet = .add }
        }
        .help("Add a project or a Localization Server")
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
    .kitDropTarget(model.isDropTargeted, cornerRadius: KitMetrics.radiusCard)
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

  /// The Projects card: the projects (narrowed by the search) in the vault's groups, which open and close, or the
  /// drop hint.
  private var projectsSection: some View {
    let layout = ProjectGroupsLayout(
      projects: model.projects, tree: Vault.shared.projectTree, collapsed: collapsedGroups.ids, search: search)
    return KitSection("Projects", meta: projectsMeta, systemImage: "folder", hue: .blue) {
      if model.projects.isEmpty {
        dropHintRow
      } else {
        ForEach(layout.rows) { row in
          Group {
            switch row.item {
            case .group(let group, let projects):
              ProjectGroupRow(
                group: group, projects: projects, isExpanded: groupIsExpanded(group.id), isSearching: !search.isEmpty,
                holdsSelection: projects.contains { model.selection == .project($0.id) })
            case .project(let project):
              projectRow(project, reservesDisclosure: layout.hasGroups)
            }
          }
          .kitRowIndent(row.depth)
        }
      }
    } accessory: {
      Button("Add Project…", systemImage: "plus") { model.addProjectsFromPanel() }
        .buttonStyle(.kitIcon)
        .help("Add a project folder")
    }
    .animation(.kit, value: layout.rows.map(\.id))
  }

  private func projectRow(_ row: SidebarProjectRow, reservesDisclosure: Bool) -> some View {
    ProjectRow(row: row, reservesDisclosure: reservesDisclosure)
      .kitContextMenu {
        if let root = row.rootURL {
          Button("Open in \(ProjectOpener.appName)", systemImage: "arrow.up.forward.app") { ProjectOpener.open(root) }
          Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
          Divider()
        }
        Button("Remove Project", systemImage: "trash", role: .destructive) {
          model.removeProject(id: row.id, localization: localization)
        }
      }
  }

  /// Whether a group is open, as Dev keeps it.
  private func groupIsExpanded(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !collapsedGroups.ids.contains(id) },
      set: { isOpen in
        if isOpen { collapsedGroups.ids.remove(id) } else { collapsedGroups.ids.insert(id) }
      })
  }

  /// "1 project · DemoApp": how many, and which one is open.
  private var projectsMeta: [String] {
    let count = model.projects.count
    guard count > 0 else { return ["Drop a folder here"] }
    var parts = ["\(count) project\(count == 1 ? "" : "s")"]
    if case .project(let id) = model.selection, let row = model.projectRow(id: id) { parts.append(row.name) }
    return parts
  }

  /// Empty Projects section: still a drop target, so the hint invites the
  /// one gesture that fills it, and the + offers the panel.
  private var dropHintRow: some View {
    VStack(spacing: 6) {
      Image(systemName: "folder.badge.plus")
        .font(.title3)
        .foregroundStyle(.kitSecondary)
      Text("Drop project folders here")
        .kitFont(.callout)
        .foregroundStyle(.kitSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .overlay(
      RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous)
        .strokeBorder(.kitBorder, style: StrokeStyle(lineWidth: 1.5, dash: [5])))
  }
}

// MARK: - Project group row

/// A group of projects (made in Git, shared through the vault): its folder, its name, and while closed how many
/// strings wait for review in the projects inside it. A click opens or closes it; closed, it stands in for the open
/// project inside it as the current row.
private struct ProjectGroupRow: View {
  let group: VaultProjectGroup
  let projects: [SidebarProjectRow]
  @Binding var isExpanded: Bool
  /// A search opens every group, so the chevron can't close it.
  let isSearching: Bool
  /// The open project is in it.
  let holdsSelection: Bool
  @AppStorage(SidebarPreferences.showReviewBadge) private var showsReviewBadge = true

  var body: some View {
    let isOpen = isExpanded || isSearching
    let needsReview = projects.reduce(0) { $0 + $1.needsReview }
    SidebarRow(group.name, subtitle: group.note?.isEmpty == false ? group.note : nil) {
      RowTile(systemImage: isOpen ? "folder.fill" : "folder", hue: StableHue.pick(group.name))
    } trailing: {
      if showsReviewBadge, !isOpen, needsReview > 0 {
        Count(needsReview.formatted(.number.notation(.compactName)), .attention)
          .help("\(needsReview) strings need review")
      }
    }
    .disclosure(isExpanded: isSearching ? .constant(true) : $isExpanded)
    .isCurrent(holdsSelection && !isOpen)
    .action { if !isSearching { withAnimation(.kit) { isExpanded.toggle() } } }
    .help(projects.count == 1 ? "1 project" : "\(projects.count) projects")
    .accessibilityHint(isOpen ? "Collapses the group" : "Expands the group")
  }
}

// MARK: - Project row

/// One project row: its app icon, its name, and how many strings wait for review.
private struct ProjectRow: View {
  let row: SidebarProjectRow
  /// Keeps the chevron's slot, so the icon lines up with the groups' beside it.
  var reservesDisclosure = false
  @AppStorage(SidebarPreferences.showReviewBadge) private var showsReviewBadge = true

  var body: some View {
    SidebarRow(value: SidebarSelection.project(row.id), row.name) {
      thumbnail
    } trailing: {
      if showsReviewBadge, row.needsReview > 0 {
        Count(row.needsReview.formatted(.number.notation(.compactName)), .attention)
          .help("\(row.needsReview) strings need review")
      }
    }
    .disclosureSlot(reservesDisclosure)
  }

  @ViewBuilder
  private var thumbnail: some View {
    if let icon = row.iconImage {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(width: 18, height: 18)
    } else {
      RowTile(systemImage: "folder", hue: .blue)
    }
  }
}
