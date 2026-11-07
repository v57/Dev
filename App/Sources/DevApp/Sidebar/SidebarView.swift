//
//  SidebarView.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import CodeActions
import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

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
  /// The projects' app installs: the rows' Install buttons and their queue.
  private let installs = AppInstalls.shared
  /// The bottom bar's + menu is open.
  @State private var showsAddMenu = false
  /// The projects a removal asks about (nil: no question).
  @State private var removal: [SidebarProjectRow]?
  /// The project groups closed in the Projects section (vault group ids).
  @AppStorage("CollapsedProjectGroups") private var collapsedGroups = KitIDSet()
  /// Settings ▸ General: the projects that aren't Xcode projects leave the list.
  @AppStorage(SidebarPreferences.onlyXcodeProjects) private var onlyXcodeProjects = true

  var body: some View {
    @Bindable var model = model
    KitSidebar(selection: $model.selection, searchText: $search, searchPrompt: "Search Projects") {
      // The window's account (hidden while Personal is the only one).
      VaultAccountPicker(meta: "\(model.projects.count) project\(model.projects.count == 1 ? "" : "s")")
      // A long Projects list keeps its title in view (the section does it), and the sections it pushes off wait as
      // titles at the bottom.
      projectsSection
      KitSection("Tools", meta: storage.sidebarStatus, systemImage: "wrench.and.screwdriver", hue: .orange) {
        StorageSidebarRow()
        VMsSidebarRow()
        LocalizationsSidebarRow()
      }
      .kitSticky(bottom: .title)
      ServersSidebarSection(
        store: servers,
        selection: $model.selection) { sheet in
          serverSheet = sheet
        }
        .kitSticky(bottom: .title)
    } bottomBar: {
      Button("Add", systemImage: "plus") { showsAddMenu = true }
        .kitMenu(isPresented: $showsAddMenu) {
          Button("Add Project…", systemImage: "folder.badge.plus") { model.addProjectsFromPanel() }.kitMenuHint("⇧⌘O")
          Button("Add Localization Server…", systemImage: "server.rack") { serverSheet = .add }
        }
        .kitHelp("Add", meta: "Add a project or a Localization Server", systemImage: "plus")
    }
    .kitSheet(item: $serverSheet) { sheet in
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
      await TranslationData.shared.start()
      servers.refresh()
      // Design checks: the Add Connection sheet.
      if LaunchOptions.isScreenshotMode, LaunchOptions.open == "addServer" { serverSheet = .add }
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
    .kitSheet(item: $model.importOffer) { offer in
      // The sheet adds them to the vault; Dev lists the folders too.
      VaultImportSheet(offer, vault: model.vaultProjects.vault, app: "Dev") { urls in
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        Task {
          if let firstID = await model.addSuggestedDirectories(folders, publishing: false) {
            model.selection = .project(firstID)
          }
        }
      }
    }
    // An install reached a running copy of its app: quitting it is the user's call.
    .kitConfirmation(
      installs.question ?? "",
      isPresented: Binding(get: { installs.question != nil }, set: { if !$0, installs.question != nil { installs.answer(false) } }),
      message: "The app quits as if you chose Quit, then the new build replaces it and opens in the background.",
      systemImage: "arrow.down.app", confirm: "Quit and Install", role: nil
    ) {
      installs.answer(true)
    }
    .kitConfirmation(
      removalTitle, isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
      message: removalMessage, systemImage: "minus.circle", buttons: removalButtons)
    .kitNotice(
      model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
      message: model.alert?.message)
    .task { model.refresh() }
    .onChange(of: model.selection) {
      // A selection usually precedes a reconcile (catalog open); refresh so
      // badges track the record state the interaction just changed.
      model.refresh()
    }
    .onChange(of: onlyXcodeProjects) {
      model.refresh()
      model.vaultProjects.preferencesChanged()
    }
  }

  /// The Projects card: VaultUI's projects section over Dev's projects (narrowed by the search) in the vault's
  /// groups, the open project's tools in its section under the list (or under its row); the drop hint while empty.
  private var projectsSection: some View {
    let layout = ProjectGroupsLayout(
      projects: model.projects, tree: model.vaultProjects.vault.projectTree, search: search)
    return VaultProjectsSection(
      layout.tree,
      selection: Binding(
        get: { if case .project(let id) = model.selection { layout.ids[id] } else { nil } },
        set: { id in if let row = id.flatMap({ layout.rows[$0] }) { model.selection = .project(row.id) } }),
      layout: .separate, sort: .arranged, key: "SidebarProjects",
      // During a search every group is open, so the chevrons can't close one.
      collapsedGroups: search.isEmpty ? $collapsedGroups.ids : .constant([])
    ) { project in
      if let row = layout.rows[project.id] { ProjectTools(model: model, row: row) }
    } menu: {
      EmptyView()
    }
    .icon { layout.rows[$0.id].flatMap(model.icon(of:)) }
    .trailing { project in
      if let row = layout.rows[project.id] { ProjectTrailing(row: row) }
    }
    .rowSubtitle { layout.rows[$0.id].flatMap { ProjectTrailing.subtitle(installs.phase(for: $0.rootURL)) } }
    .rowProgress { layout.rows[$0.id].flatMap { ProjectTrailing.progress(installs.phase(for: $0.rootURL)) } }
    .groupTrailing { _, projects in
      ReviewCount(projects.compactMap { layout.rows[$0.id]?.needsReview }.reduce(0, +))
    }
    // Vault's section adds Finder and Terminal to Dev's apps, in one Open With row at the top.
    .openWith(first: true) { project in layout.rows[project.id]?.rootURL.map(ProjectOpener.openApps) ?? [] }
    .rowMenu { project in
      if let row = layout.rows[project.id] { projectMenu(row) }
    }
    .removable(confirmsRemoveAll: false) { ids in
      var seen = Set<Int64>()
      let rows = ids.compactMap { layout.rows[$0] }.filter { seen.insert($0.id).inserted }
      // One project with nothing to keep goes at once; anything else asks.
      if rows.count == 1, !model.holdsRecords(rows[0].id) {
        model.removeProject(id: rows[0].id, keepingRecords: false, localization: localization)
      } else if !rows.isEmpty {
        removal = rows
      }
    }
    .accessory {
      Button("Add Project…", systemImage: "plus") { model.addProjectsFromPanel() }
        .buttonStyle(.kitIcon)
        .kitHelp("Add Project", meta: "Add a project folder", systemImage: "plus")
    }
    .emptyState {
      if model.projects.isEmpty {
        dropHintRow
      } else {
        Text("No projects match “\(search)”.").kitFont(.callout).foregroundStyle(.kitSecondary)
      }
    }
  }

  /// A project row's context menu, between the Open With row and Copy Path.
  @ViewBuilder
  private func projectMenu(_ row: SidebarProjectRow) -> some View {
    if let root = row.rootURL {
      VaultOtherPlacesMenu(root: root)
      if installs.canInstall(root), let name = installs.appName(root) {
        Divider()
        switch installs.phase(for: root) {
        case .queued:
          Button("Cancel Install", systemImage: "xmark.circle") { installs.cancel(root) }
            .kitMenuPreview("Takes \(name) out of the install queue before it starts.")
        case .installing:
          Button("Cancel Install", systemImage: "xmark.circle") { installs.cancel(root) }
            .kitMenuPreview("Stops installing \(name) on this Mac.")
        default:
          Button("Install \(name) on This Mac", systemImage: "arrow.down.app") { installs.install(root) }
        }
        if let log = installs.logURL(root) {
          Button("Show Install Log", systemImage: "doc.text") { KitDesktop.open(log) }
        }
      }
      Divider()
    }
  }

  // MARK: - Removal

  /// "Remove Shell from the list?", "Remove 3 projects from the list?"
  private var removalTitle: String {
    guard let removal else { return "" }
    return removal.count == 1 ? "Remove \(removal[0].name) from the list?" : "Remove \(removal.count) projects from the list?"
  }

  private var removalMessage: String {
    guard let removal, removal.contains(where: { model.holdsRecords($0.id) }) else {
      return "Their folders and catalogs stay on disk, and Git and the other apps keep them."
    }
    return "Dev can keep which strings were reviewed, the notes, the width limits and the edit history, and bring them back when the folder is added again. The translations stay in the catalogs and the translation memory either way."
  }

  /// Keep (the default) or delete what Dev holds; just Remove when it holds nothing.
  private var removalButtons: [KitConfirmationButton] {
    guard let removal else { return [] }
    func remove(keepingRecords: Bool) {
      withAnimation(.kit) {
        for row in removal { model.removeProject(id: row.id, keepingRecords: keepingRecords, localization: localization) }
      }
    }
    guard removal.contains(where: { model.holdsRecords($0.id) }) else {
      return [KitConfirmationButton("Remove", role: .destructive) { remove(keepingRecords: false) }]
    }
    return [
      KitConfirmationButton("Delete Review State", role: .destructive) { remove(keepingRecords: false) },
      KitConfirmationButton("Keep Review State", isDefault: true) { remove(keepingRecords: true) },
    ]
  }

  /// Empty Projects section: still a drop target, so the hint invites the
  /// one gesture that fills it, and the + offers the panel.
  private var dropHintRow: some View {
    VStack(spacing: 6) {
      Image(systemName: "folder.badge.plus")
        .kitFont(.title3)
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

// MARK: - Project rows

/// The open project's tools, in its section: the same tabs as the toolbar's, with the strings waiting for review on
/// Localization.
private struct ProjectTools: View {
  let model: SidebarViewModel
  let row: SidebarProjectRow

  var body: some View {
    ForEach(DevTool.allCases) { tool in
      SidebarRow(tool.title) {
        RowTile(systemImage: tool.systemImage, hue: .blue)
      } trailing: {
        if tool == .localization { ReviewCount(row.needsReview) }
      }
      .isCurrent(model.projectTool == tool)
      .action { model.projectTool = tool }
    }
  }
}

/// How many strings wait for review (nothing at 0, or while Settings hides the badge).
private struct ReviewCount: View {
  let count: Int
  @AppStorage(SidebarPreferences.showReviewBadge) private var showsReviewBadge = true

  init(_ count: Int) { self.count = count }

  var body: some View {
    if showsReviewBadge, count > 0 {
      Count(count.formatted(.number.notation(.compactName)), .attention)
        .kitHelp("Needs Review", meta: "\(count) strings need review")
    }
  }
}

/// A project row's trailing views: how many strings wait for review, and Install while the source is newer than the
/// app on this Mac (then Cancel while it is queued or installing). The row's subtitle and bar say the install's step
/// and progress.
private struct ProjectTrailing: View {
  let row: SidebarProjectRow
  private let installs = AppInstalls.shared

  var body: some View {
    ReviewCount(row.needsReview)
    installButton(installs.phase(for: row.rootURL))
  }

  @ViewBuilder
  private func installButton(_ install: AppInstalls.Phase) -> some View {
    let name = installs.appName(row.rootURL) ?? row.name
    switch install {
    case .available(let installed):
      Button("Install", systemImage: "arrow.down.circle") { installs.install(row.rootURL) }
        .buttonStyle(.kitIcon)
        .kitHelp("Install", meta: installed ? "The source is newer than \(name) on this Mac: install it" : "Install \(name) on this Mac", systemImage: "arrow.down.circle")
    case .queued, .installing:
      Button("Cancel Install", systemImage: "xmark.circle") { installs.cancel(row.rootURL) }
        .buttonStyle(.kitIcon)
        .kitHelp("Cancel Install", meta: "Cancel installing \(name)", systemImage: "xmark.circle")
    case .failed(let reason):
      Button("Install Again", systemImage: "exclamationmark.arrow.circlepath") { installs.install(row.rootURL) }
        .buttonStyle(.kitIcon)
        .foregroundStyle(Hue.red.text)
        .kitHelp("Install Again", meta: "Installing \(name) failed: \(reason). Click to try again; the context menu shows the log.", systemImage: "exclamationmark.arrow.circlepath")
    case .none, .current:
      EmptyView()
    }
  }

  /// "Queued · 2nd", "Building · 3 min left", "Install failed".
  static func subtitle(_ install: AppInstalls.Phase) -> String? {
    switch install {
    case .queued(let position):
      return position == 1 ? "Queued · next" : "Queued · \(position.formatted(.number))\(ordinal(position))"
    case .installing(let step, let progress):
      let verb =
        switch step {
        case "Archive"?: "Building"
        case "Quit"?: "Quitting"
        case "Install"?: "Installing"
        case "Open"?: "Opening"
        default: "Preparing"
        }
      guard let remaining = progress?.remaining, remaining >= 1 else { return verb }
      let left = Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
      return "\(verb) · \(left) left"
    case .failed:
      return "Install failed"
    case .none, .current, .available:
      return nil
    }
  }

  private static func ordinal(_ number: Int) -> String {
    switch (number % 10, number % 100) {
    case (_, 11...13): "th"
    case (1, _): "st"
    case (2, _): "nd"
    case (3, _): "rd"
    default: "th"
    }
  }

  /// The install's bar under the title, once its history gives a fraction (the subtitle says the step until then).
  static func progress(_ install: AppInstalls.Phase) -> Double? {
    guard case .installing(_, let progress) = install else { return nil }
    return progress?.fraction
  }
}
