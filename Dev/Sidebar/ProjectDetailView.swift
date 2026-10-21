//
//  ProjectDetailView.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import ComponentKit
import SwiftUI

/// Detail pane for a SELECTED sidebar project: the tab the toolbar picked
/// (`SidebarViewModel.projectTool`) — Overview first, then the tools bound to
/// the project. The binding source is the row snapshot from the shared
/// SidebarViewModel (the SAME rows the sidebar renders).
///
///  - Overview: what the project is and how its localization, icon, workflows
///    and App Store screenshots stand, each a click from its tab.
///  - Localization: picking the tab opens the project's catalog into the
///    shared LocalizationStore. LAZY: the open happens when the tab is first
///    opened for the project, never on selection alone, so browsing the sidebar
///    costs no parse (see `openCatalogIfPicked`).
///  - App Icon: CreateIconView exports into the project's root directory.
///  - Screenshots: capture, frame and review the App Store pictures.
///  - Workflows: the project's CI.
struct ProjectDetailView: View {
  let model: SidebarViewModel
  let row: SidebarProjectRow

  /// The shared open-catalog store (owned + injected by ContentView, same
  /// instance the sidebar's projectless bottom bar and the projectless tool
  /// read).
  @Environment(LocalizationStore.self) private var localization

  /// Identity of the lazy catalog open: the (project, tool) pair. Making the
  /// TOOL part of the key is what keeps loading lazy — the task only fires
  /// when Localization is the picked tool, and re-fires when either half
  /// changes (another project while the tool is open, or the tool re-picked
  /// after a trip to App Icon).
  private struct CatalogOpenKey: Equatable {
    let project: Int64
    let tool: DevTool
  }

  var body: some View {
    Group {
      switch model.projectTool {
      case .overview:
        ProjectOverviewView(model: model, row: row)
      case .icon:
        CreateIconView(exportRootURL: row.rootURL)
      case .localization:
        LocalizationView(
          projectCatalogURL: row.catalogURL,
          projectRootURL: row.rootURL,
          onCatalogCreated: { model.refresh() })
      case .screenshots:
        if let root = row.rootURL {
          ScreenshotsView(root: root, projectName: row.name)
        } else {
          noFolder("Drop the project's folder on the sidebar to capture its screenshots.")
        }
      case .workflows:
        if let root = row.rootURL {
          WorkflowsView(root: root, projectName: row.name)
        } else {
          noFolder("Drop the project's folder on the sidebar to run its workflows.")
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Binding side effect, LAZY: the catalog loads the moment the
    // Localization tab is first opened for this project — not when the
    // project is selected, and not while another tab is showing. A catalog the
    // store already holds is left untouched, so per-catalog view state survives
    // a revisit; a missing file stays closed and the Localization pane shows
    // its 'no catalog' state.
    .task(id: CatalogOpenKey(project: row.id, tool: model.projectTool)) {
      await openCatalogIfPicked()
    }
  }

  private func noFolder(_ message: String) -> some View {
    EmptyState(systemImage: "folder.badge.questionmark", title: "No Project Folder", message: message).kitPane()
  }

  /// Opens the bound catalog — only for the Localization tool, and only when
  /// the store is not already showing it.
  private func openCatalogIfPicked() async {
    guard model.projectTool == .localization else { return }
    // A project whose file is missing stays closed ('no catalog' state). The
    // one exception is a catalog this store already holds: it was generated
    // (or opened) here, and the row's snapshot has simply not been rebuilt.
    guard row.catalogExists || localization.catalogURL == row.catalogURL else { return }
    await localization.openIfNeeded(row.catalogURL)
    // The open reconciled records into the project — rebuild the rows so
    // sidebar badges track what the open just changed. Also how a freshly
    // GENERATED catalog reaches the row (`onCatalogCreated`).
    model.refresh()
  }
}
