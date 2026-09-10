//
//  ProjectDetailView.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

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
///  - Localization: selecting the project opens its catalog into the shared
///    LocalizationStore — reconcile find-or-creates by catalogURL and reuses
///    the selected project's row, so no duplicate is ever created — and
///    LocalizationView shows the catalog, or a 'no catalog' state when the
///    file is absent. The store is shared with the projectless tool; the
///    bound view only renders content while the store holds THIS project's
///    catalog.
struct ProjectDetailView: View {
  let model: SidebarViewModel
  let row: SidebarProjectRow

  /// The shared open-catalog store (owned + injected by ContentView, same
  /// instance the sidebar's projectless bottom bar and the projectless tool
  /// read).
  @Environment(LocalizationStore.self) private var localization

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
    // Binding side effect: the moment a project is selected its catalog is
    // opened into the shared store (id-keyed, so switching projects
    // re-runs). Already-open catalogs are left untouched so per-catalog
    // view state survives a revisit; a missing file stays closed and the
    // Localization pane shows its 'no catalog' state. Runs regardless of
    // the picked tool so the sidebar badge tracks the binding.
    .task(id: row.id) { await bindProjectCatalog() }
  }

  /// Deselected toolbar picker state: explain the single picker instead of
  /// guessing a tool.
  private var toolPrompt: some View {
    ContentUnavailableView(
      "Choose a tool",
      systemImage: "wrench.and.screwdriver",
      description: Text("Pick App Icon or Localization in the toolbar to open it for this project."))
  }

  private func bindProjectCatalog() async {
    guard row.catalogExists else { return }
    guard localization.catalogURL != row.catalogURL else { return }
    await localization.open(row.catalogURL)
    // The open reconciled new records into the project — rebuild the rows
    // so sidebar badges track what the binding just changed.
    model.refresh()
  }
}
