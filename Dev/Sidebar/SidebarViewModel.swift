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

  var id: String { rawValue }

  var title: String {
    switch self {
    case .icon: return "App Icon"
    case .localization: return "Localization"
    }
  }

  var systemImage: String {
    switch self {
    case .icon: return "hammer.fill"
    case .localization: return "globe"
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
  /// Distinct keys with at least one filled needs_review record — mirrors
  /// the Localization tool's 'Needs review' row filter (a key counts when
  /// ANY of its language/plural slots needs review).
  let needsReviewKeyCount: Int
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

  /// Non-nil surfaces the drop-import alert.
  var importError: String?

  /// True while a Finder drag hovers the sidebar (drop feedback).
  var isDropTargeted = false

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
  func refresh() {
    let context = TranslationStore.shared.context
    let fetched = (try? context.fetch(FetchDescriptor<Project>())) ?? []
    let fm = FileManager.default
    projects = fetched
      .sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
      .map { project in
        let records = project.records
        var keys = Set<String>()
        var reviewKeys = Set<String>()
        for record in records {
          keys.insert(record.key)
          if let value = record.value,
             !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
             record.state == .needs_review {
            reviewKeys.insert(record.key)
          }
        }
        return SidebarProjectRow(
          id: project.persistentModelID,
          name: project.displayName,
          rootURL: project.rootURL,
          catalogURL: project.catalogURL,
          iconImage: project.iconThumbnail,
          needsReviewKeyCount: reviewKeys.count,
          keyCount: keys.count,
          catalogExists: fm.fileExists(atPath: project.catalogURL.path),
          hasRecords: !records.isEmpty)
      }
  }

  // MARK: - drag-and-drop import

  /// Adds dropped Finder items as projects: a DIRECTORY becomes a
  /// directory-root project via the P10 resolver; an .xcstrings FILE
  /// becomes a project rooted at its parent directory. Dedupe is the
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

    // The tree walk — off the main actor, because a drop can point at an
    // arbitrarily large tree.
    let roots = dropped.compactMap { item -> URL? in
      if case .directory(let root) = item { return root }
      return nil
    }
    let discovered = await Task.detached(priority: .userInitiated) {
      roots.map { ($0, CatalogDiscovery.catalog(inRoot: $0)) }
    }.value
    let catalogByRoot = Dictionary(discovered, uniquingKeysWith: { first, _ in first })

    let context = TranslationStore.shared.context
    var firstID: PersistentIdentifier?
    for item in dropped {
      let project: Project
      switch item {
      case .directory(let root):
        project = Reconcile.resolveDirectoryProject(
          rootDir: root, catalogURL: catalogByRoot[root] ?? nil, in: context)
      case .catalog(let fileURL):
        project = resolveCatalogFileDrop(fileURL, in: context)
      }
      if firstID == nil { firstID = project.persistentModelID }
    }
    do {
      try context.save()
    } catch {
      importError = "Couldn't save the imported project: \(error.localizedDescription)"
      return nil
    }
    refresh()
    return firstID
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
