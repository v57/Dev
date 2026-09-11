//
//  ProjectDetailView.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import SwiftData
import SwiftUI

/// Detail pane for a SELECTED sidebar project: the two dev tools bound to
/// it (P40 — binding IS the integration). The binding source is the row
/// snapshot from the shared SidebarViewModel (the SAME rows the sidebar
/// renders); nothing here tracks 'which project is selected' on its own.
///
/// WHICH tool fills the pane is owned by the ONE toolbar picker
/// (`SidebarViewModel.projectTool`), not by this view: it is deselected by
/// default, and while it is, the pane prompts for a pick. There is no
/// project header here — the sidebar row already carries the project's
/// icon, name and translation badge.
///
///  - App Icon: CreateIconView exports into the project's root directory
///    (no folder picker), so Export writes the project's OWN
///    Assets.xcassets/AppIcon.appiconset. Projects without a rootURL
///    (legacy catalog-file rows) fall back to the picker.
///  - Localization: picking the tool opens the project's catalog into the
///    shared LocalizationStore — reconcile find-or-creates by catalogURL and
///    reuses the selected project's row, so no duplicate is ever created —
///    and LocalizationView shows the catalog, or a 'no catalog' state when
///    the file is absent. LAZY: the open happens when the Localization tool is
///    first opened for the project, never on selection alone, so browsing the
///    sidebar costs no parse, no mirror and no row build (see
///    `openCatalogIfPicked`). The store is shared with the projectless tool;
///    the bound view only renders content while the store holds THIS project's
///    catalog.
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
    let project: PersistentIdentifier
    let tool: DevTool?
  }

  var body: some View {
    Group {
      if let tool = model.projectTool {
        switch tool {
        case .icon:
          CreateIconView(exportRootURL: row.rootURL)
        case .localization:
          LocalizationView(projectCatalogURL: row.catalogURL)
        }
      } else {
        toolPrompt
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Binding side effect, LAZY: the catalog loads the moment the
    // Localization tool is first opened for this project — not when the
    // project is selected, and not while another tool (or no tool) is picked.
    // A catalog the store already holds is left untouched, so per-catalog
    // view state survives a revisit; a missing file stays closed and the
    // Localization pane shows its 'no catalog' state.
    .task(id: CatalogOpenKey(project: row.id, tool: model.projectTool)) {
      await openCatalogIfPicked()
    }
  }

  /// Deselected toolbar picker state: explain the single picker instead of
  /// guessing a tool.
  private var toolPrompt: some View {
    ContentUnavailableView(
      "Choose a tool",
      systemImage: "wrench.and.screwdriver",
      description: Text("Pick App Icon or Localization in the toolbar to open it for this project."))
  }

  /// Opens the bound catalog — only for the Localization tool, and only when
  /// the store is not already showing it.
  private func openCatalogIfPicked() async {
    guard model.projectTool == .localization else { return }
    guard row.catalogExists else { return }
    await localization.openIfNeeded(row.catalogURL)
    // The open reconciled records into the project — rebuild the rows so
    // sidebar badges track what the open just changed.
    model.refresh()
  }
}
