//
//  SidebarViewModel.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import AppKit
import Foundation
import SwiftData

// MARK: - Sidebar destinations

/// The app's two tools. They are the SAME tool whether opened projectless
/// (bottom sidebar bar) or bound to a selected project (toolbar picker);
/// only the target differs. The single toolbar picker and the projectless
/// bottom bar both speak this enum.
enum DevTool: String, Hashable, CaseIterable, Identifiable {
  case icon
  case localization
  /// Project-bound only: a release needs a project to build.
  case release

  /// The tools the sidebar's bottom bar offers without a project. Localization is
  /// not one: a catalog is always a project's (a dropped .xcstrings becomes one).
  static let projectless: [DevTool] = [.icon]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .icon: return "App Icon"
    case .localization: return "Localization"
    case .release: return "Release"
    }
  }

  var systemImage: String {
    switch self {
    case .icon: return "hammer.fill"
    case .localization: return "globe"
    case .release: return "shippingbox"
    }
  }
}

/// What the sidebar selection points at. THE single source of truth for
/// 'which project is selected' — the projectless bottom bar and the
/// project-bound tools read and write exactly this.
enum SidebarSelection: Hashable {
  /// A projectless ad-hoc tool (bottom sidebar bar).
  case tool(DevTool)
  /// A directory/catalog project from the Projects section.
  case project(PersistentIdentifier)
  /// A localize server from the Servers section. Keyed by the server's own
  /// string id rather than its PersistentIdentifier, because the id is what its
  /// keychain item and its status are keyed by too.
  case server(String)
  /// The Storage tool: what fills this Mac, by developer category.
  case storage
  /// The VMs tool: UTM virtual machines, and Run on VM.
  case vms
}

/// What the sidebar's one alert is about. A single value rather than one
/// optional per case, because a view presents one alert at a time.
struct SidebarAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

// MARK: - Row value

/// Immutable per-project row data, computed once per `refresh()` so row
/// bodies never touch SwiftData or the filesystem repeatedly.
struct SidebarProjectRow: Identifiable {
  let id: PersistentIdentifier
  let name: String
  let rootURL: URL?
  let catalogURL: URL
  let iconImage: NSImage?
  /// Distinct translatable keys present in the project's reconciled records.
  let keyCount: Int
  let catalogExists: Bool
  let hasRecords: Bool
}

// MARK: - View model

/// Sidebar state + import logic for the project-centric split view.
/// Owned once by ContentView and shared with every sidebar card so project
/// selection has exactly one home.
@Observable
final class SidebarViewModel {
  // MARK: state

  /// The one sidebar selection. nil = neither project nor tool selected
  /// (the launch state — the toolbar tool picker is deselected by default).
  var selection: SidebarSelection? = nil {
    didSet {
      guard selection != oldValue else { return }
      // Opening a project always starts with NO tool chosen: the toolbar
      // picker is deselected by default and the pane prompts for a pick.
      if case .project = selection { projectTool = nil }
    }
  }

  /// The tool shown for the SELECTED project, or nil while none is chosen.
  /// Drives the single toolbar picker (which only exists for a project).
  var projectTool: DevTool?

  /// True while a project is the selection — the toolbar picker is visible
  /// only then (projectless tools live in the sidebar's bottom bar).
  var hasSelectedProject: Bool {
    if case .project = selection { return true }
    return false
  }

  /// The projectless tool currently open, or nil when none is selected
  /// (or a project is). Drives the bottom bar's highlighted row.
  var currentTool: DevTool? {
    get {
      if case .tool(let tool) = selection { return tool }
      return nil
    }
    set {
      selection = newValue.map(SidebarSelection.tool)
    }
  }

  /// Fresh per-project rows, rebuilt by `refresh()`.
  private(set) var projects: [SidebarProjectRow] = []

  init() {
    observeSaves()
  }

  /// The alert the sidebar shows (import failure, refused removal), or nil.
  var alert: SidebarAlert?

  /// True while a Finder drag hovers the sidebar (drop feedback).
  var isDropTargeted = false

  /// Directories the last drop passed over (no repo inside, but a repo beside
  /// them), offered to the reader as projects to add. Empty = no offer showing.
  var importSuggestions: [RepoDiscovery.Skipped] = []

  /// The selected project's live SwiftData object, or nil when the
  /// selection is a projectless tool. Looked up on demand.
  var selectedProject: Project? {
    guard case .project(let id) = selection else { return nil }
    return project(id: id)
  }

  // MARK: lookups

  func project(id: PersistentIdentifier) -> Project? {
    let context = TranslationStore.shared.context
    return ((try? context.fetch(FetchDescriptor<Project>())) ?? [])
      .first { $0.persistentModelID == id }
  }

  func projectRow(id: PersistentIdentifier) -> SidebarProjectRow? {
    projects.first { $0.id == id }
  }

  // MARK: refresh

  /// Refetches the project list and rebuilds rows (thumbnail + badge
  /// counts). Called on sidebar appear, after imports and on selection
  /// changes — a reconcile usually follows a selection, so this keeps the
  /// badges tracking record state within one interaction.
  ///
  /// The rows are built at once from the badge counts already in hand; the
  /// counts themselves are a fetch of the WHOLE record table (measured ~1.5 s
  /// for a 67,844-record store even properties-limited, and 7.6 s through
  /// `project.records`), so they are recounted OFF the main actor, and only
  /// when something has saved since the last count (`countsAreStale`). A
  /// selection change over an unchanged store costs a project fetch and
  /// nothing else; the badges catch up when a recount lands.
  func refresh() {
    rebuildRows()
    if countsAreStale { recount() }
  }

  private func rebuildRows() {
    let context = TranslationStore.shared.context
    let fetched = (try? context.fetch(FetchDescriptor<Project>())) ?? []
    let fm = FileManager.default
    projects = fetched
      .sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
      .map { project in
        let badge = badgeCounts[project.persistentModelID] ?? BadgeCounts()
        return SidebarProjectRow(
          id: project.persistentModelID,
          name: project.displayName,
          rootURL: project.rootURL,
          catalogURL: project.catalogURL,
          iconImage: project.iconThumbnail,
          keyCount: badge.keys,
          catalogExists: fm.fileExists(atPath: project.catalogURL.path),
          hasRecords: badge.records > 0)
      }
  }

  /// Per-project badge counts: the DISTINCT keys a project's records cover,
  /// and how many records it has.
  private struct BadgeCounts: Sendable {
    var keys = 0
    var records = 0
  }

  /// The last counts, by project.
  @ObservationIgnored private var badgeCounts: [PersistentIdentifier: BadgeCounts] = [:]
  /// True when a context has saved since `badgeCounts` was taken (or none was
  /// ever taken). Set by `ModelContext.didSave` from ANY context — the
  /// background mirror and the passes save on their own — so a recount is paid
  /// once per change, not once per click.
  @ObservationIgnored private var countsAreStale = true
  @ObservationIgnored private var recountTask: Task<Void, Never>?
  @ObservationIgnored private var saveObserver: NSObjectProtocol?

  /// Starts watching for saves. Idempotent; called from `init`.
  private func observeSaves() {
    guard saveObserver == nil else { return }
    saveObserver = NotificationCenter.default.addObserver(
      forName: ModelContext.didSave, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.countsAreStale = true }
    }
  }

  private func recount() {
    countsAreStale = false
    recountTask?.cancel()
    recountTask = Task { [weak self] in
      let counts = await Task.detached(priority: .utility) {
        Self.recordCounts(in: ModelContext(TranslationStore.container))
      }.value
      guard !Task.isCancelled, let self else { return }
      self.badgeCounts = counts
      self.rebuildRows()
    }
  }

  /// One properties-limited fetch of the record table, grouped in memory —
  /// never `project.records` (see `refresh`). On a context of its own, off the
  /// main actor.
  private nonisolated static func recordCounts(
    in context: ModelContext
  ) -> [PersistentIdentifier: BadgeCounts] {
    var descriptor = FetchDescriptor<TranslationRecord>()
    // Only the two fields the badges read, so the fetch builds no object graph
    // and no relationship fault per record.
    descriptor.propertiesToFetch = [\.key, \.project]
    let rows = (try? context.fetch(descriptor)) ?? []
    var keys: [PersistentIdentifier: Set<String>] = [:]
    var counts: [PersistentIdentifier: Int] = [:]
    for record in rows {
      guard let project = record.project else { continue }
      let id = project.persistentModelID
      counts[id, default: 0] += 1
      keys[id, default: []].insert(record.key)
    }
    var out: [PersistentIdentifier: BadgeCounts] = [:]
    for (id, count) in counts {
      out[id] = BadgeCounts(keys: keys[id]?.count ?? 0, records: count)
    }
    return out
  }

  // MARK: - removal

  /// Removes a project from the sidebar: the SwiftData row and — by cascade —
  /// its reconciled records and its project-scope context doc. The catalog
  /// FILE on disk is never touched: removing un-imports the project, it does
  /// not delete the artifact (re-dropping the folder imports it afresh).
  ///
  /// When the project's catalog is the one open in Localization, the store is
  /// closed with it: keeping it open would render records of a deleted
  /// project and its next reconcile would silently re-create the row just
  /// removed. Two states refuse the removal instead, because they would drop
  /// work that has nowhere else to live — unsaved catalog edits (Save is the
  /// only writer of the .xcstrings) and an in-flight Translate/Scan run. Both
  /// report through `alert`.
  ///
  /// No-op when the project is already gone (a stale row's menu action).
  func removeProject(id: PersistentIdentifier, localization: LocalizationStore) {
    let context = TranslationStore.shared.context
    guard let project = project(id: id) else { return }

    if localization.catalogURL == project.catalogURL {
      if localization.hasUnsavedChanges {
        alert = SidebarAlert(
          title: "Unsaved changes",
          message: "The open catalog has edits the file does not have yet. Save or discard them in Localization, then remove the project.")
        return
      }
      if localization.scan.isRunning || localization.isSyncing {
        alert = SidebarAlert(
          title: "Work in progress",
          message: "Work on this project's catalog is still going — a scan, or the store catching up with the catalog it was opened from. Let it finish or cancel it, then remove the project.")
        return
      }
      localization.closeCatalog()
    }

    let rootURL = project.rootURL
    context.delete(project)
    do {
      try context.save()
    } catch {
      alert = SidebarAlert(
        title: "Remove failed",
        message: "Couldn't remove the project: \(error.localizedDescription)")
      return
    }
    // A removed row cannot stay selected: this drops the detail pane back to
    // its prompt and takes the project-bound toolbar picker with it.
    if selection == .project(id) {
      selection = nil
    }
    // Removed here only: Git and the other apps keep it, and Dev doesn't bring it back.
    VaultProjects.shared.dismiss(rootURL: rootURL)
    refresh()
  }

  // MARK: - drag-and-drop import

  /// Adds dropped Finder items as projects: a DIRECTORY is searched for git
  /// repos (`RepoDiscovery`) and each repo becomes a directory-root project via
  /// the P10 resolver — the directory itself when it holds none; an .xcstrings
  /// FILE becomes a project rooted at its parent directory. Directories the
  /// search passed over land in `importSuggestions` for the sidebar to offer.
  /// Dedupe is the
  /// resolver's contract:
  ///  - re-dropping a directory returns the SAME row (rootURL match);
  ///  - a file whose parent is already a project joins that row;
  ///  - a file with an existing catalog-file row (opened earlier via the
  ///    Localization tool) is adopted in place and upgraded to a
  ///    directory-root project — its catalogURL keeps pointing at the real
  ///    file, so records/context survive and re-drops never duplicate.
  ///
  /// `async` because a dropped directory is now SEARCHED for its catalog
  /// rather than assumed to hold one at its root (`CatalogDiscovery`). That
  /// walk is unbounded in the size of the tree, so it runs OFF the main
  /// actor; only the metadata work — dedupe, creation, save, refresh —
  /// happens here. Dropping a huge directory therefore still cannot freeze
  /// the UI. A directory that names its catalog at the root short-circuits to
  /// a single existence check inside the walk, so the common case stays as
  /// cheap as it was.
  @discardableResult
  func importDroppedURLs(_ urls: [URL]) async -> PersistentIdentifier? {
    guard !urls.isEmpty else { return nil }
    let fm = FileManager.default

    // Classify first: cheap, metadata-only, and it preserves the input ORDER
    // so "the first dropped item wins the selection" is unchanged.
    enum DroppedItem {
      case directory(URL)
      case catalog(URL)
    }
    var dropped: [DroppedItem] = []
    for url in urls {
      let fileURL = url.standardizedFileURL
      var isDirectory: ObjCBool = false
      guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else { continue }
      if isDirectory.boolValue {
        dropped.append(.directory(fileURL))
      } else if fileURL.pathExtension.lowercased() == "xcstrings" {
        dropped.append(.catalog(fileURL))
      }
      // Anything else is neither a folder nor a catalog: ignore the drop.
    }
    guard !dropped.isEmpty else { return nil }

    // The tree walks — off the main actor, because a drop can point at an
    // arbitrarily large tree: first the repos in each dropped directory, then
    // the catalog in each repo.
    let dropRoots = dropped.compactMap { item -> URL? in
      if case .directory(let root) = item { return root }
      return nil
    }
    let scans = await Task.detached(priority: .userInitiated) {
      dropRoots.map { RepoDiscovery.scan($0) }
    }.value
    let reposByDrop = Dictionary(
      zip(dropRoots, scans.map(\.repos)), uniquingKeysWith: { first, _ in first })
    let skipped = scans.flatMap(\.skipped)
    let catalogByRoot = await Self.discoverCatalogs(in: scans.flatMap(\.repos))

    let context = TranslationStore.shared.context
    var firstID: PersistentIdentifier?
    var resolved: [Project] = []
    for item in dropped {
      let projects: [Project]
      switch item {
      case .directory(let dropRoot):
        projects = (reposByDrop[dropRoot] ?? [dropRoot]).map { root in
          Reconcile.resolveDirectoryProject(
            rootDir: root, catalogURL: catalogByRoot[root] ?? nil, in: context)
        }
      case .catalog(let fileURL):
        projects = [resolveCatalogFileDrop(fileURL, in: context)]
      }
      if firstID == nil { firstID = projects.first?.persistentModelID }
      resolved += projects
    }
    do {
      try context.save()
    } catch {
      alert = SidebarAlert(
        title: "Import failed",
        message: "Couldn't save the imported project: \(error.localizedDescription)")
      return nil
    }
    refresh()
    // The other v57 apps list the folder too.
    VaultProjects.shared.publish(resolved.compactMap(\.rootURL))
    // Offer only what is not a project already: re-dropping a folder must not
    // keep suggesting the directories the reader added from its last drop.
    let known = Set(projects.compactMap(\.rootURL))
    let fresh = skipped.filter { !known.contains($0.url) }
    if !fresh.isEmpty { importSuggestions = fresh }
    return firstID
  }

  /// Adds the suggested directories the reader picked, each as one project
  /// exactly as dropped — no repo search, because they hold none.
  @discardableResult
  func addSuggestedDirectories(_ urls: [URL]) async -> PersistentIdentifier? {
    importSuggestions = []
    guard !urls.isEmpty else { return nil }
    let catalogByRoot = await Self.discoverCatalogs(in: urls)
    let context = TranslationStore.shared.context
    let added = urls.map { root in
      Reconcile.resolveDirectoryProject(
        rootDir: root, catalogURL: catalogByRoot[root] ?? nil, in: context)
    }
    do {
      try context.save()
    } catch {
      alert = SidebarAlert(
        title: "Import failed",
        message: "Couldn't save the imported projects: \(error.localizedDescription)")
      return nil
    }
    refresh()
    VaultProjects.shared.publish(added.compactMap(\.rootURL))
    return added.first?.persistentModelID
  }

  /// Removes the project at `rootPath` because the vault dropped it (removed in Git), unless it holds
  /// translation records or is selected. Returns whether it's gone.
  func removeUnusedProject(rootPath: String) -> Bool {
    let context = TranslationStore.shared.context
    let all = (try? context.fetch(FetchDescriptor<Project>())) ?? []
    guard let project = all.first(where: { $0.rootURL?.standardizedFileURL.path == rootPath }) else { return true }
    guard (project.records ?? []).isEmpty, selection != .project(project.persistentModelID) else { return false }
    context.delete(project)
    do {
      try context.save()
    } catch {
      return false
    }
    refresh()
    return true
  }

  /// Each root's catalog, searched off the main actor.
  private static func discoverCatalogs(in roots: [URL]) async -> [URL: URL?] {
    let found = await Task.detached(priority: .userInitiated) {
      roots.map { ($0, CatalogDiscovery.catalog(inRoot: $0)) }
    }.value
    return Dictionary(found, uniquingKeysWith: { first, _ in first })
  }

  /// A dropped .xcstrings file becomes a directory-root project at its
  /// parent, without ever duplicating an existing row:
  ///  1. the file already has a catalog-file row (the Localization tool
  ///     opened it before) -> upgrade THAT row in place to a
  ///     directory-root project (rootURL = parent, iconURL resolved), the
  ///     same adoption the P10 resolver performs for directory drops;
  ///  2. otherwise defer to `resolveDirectoryProject(parent)` — its
  ///     rootURL/catalogURL matching returns an existing project for that
  ///     folder (a Localizable.xcstrings drop re-hits the canonical row).
  private func resolveCatalogFileDrop(_ fileURL: URL, in context: ModelContext) -> Project {
    let parent = fileURL.deletingLastPathComponent()
    if let existing = Reconcile.existingProject(catalogURL: fileURL, in: context) {
      existing.rootURL = parent.standardizedFileURL
      existing.iconURL = parent
        .appendingPathComponent("Assets.xcassets", isDirectory: true)
        .appendingPathComponent("AppIcon.appiconset", isDirectory: true)
      return existing
    }
    return Reconcile.resolveDirectoryProject(rootDir: parent, in: context)
  }
}
