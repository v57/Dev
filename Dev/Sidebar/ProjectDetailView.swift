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

  /// Which bound tool fills the pane. UI-only switch — the sidebar's
  /// selection stays the single source of truth.
  @State private var tool: ProjectTool = .icon

  /// The shared open-catalog store (owned + injected by ContentView, same
  /// instance the sidebar 'Current (no project)' row and the projectless
  /// tool read).
  @Environment(LocalizationStore.self) private var localization

  var body: some View {
    VStack(spacing: 0) {
      header
      Picker("Tool", selection: $tool) {
        ForEach(ProjectTool.allCases) { tool in
          Label(tool.title, systemImage: tool.systemImage).tag(tool)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .help("Switch the project-bound tool")
      .padding(.horizontal, 20)
      .padding(.bottom, 12)
      Divider()
      switch tool {
      case .icon:
        CreateIconView(exportRootURL: row.rootURL)
      case .localization:
        LocalizationView(projectCatalogURL: row.catalogURL)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Binding side effect: the moment a project is selected its catalog is
    // opened into the shared store (id-keyed, so switching projects
    // re-runs). Already-open catalogs are left untouched so per-catalog
    // view state survives a revisit; a missing file stays closed and the
    // Localization pane shows its 'no catalog' state.
    .task(id: row.id) { await bindProjectCatalog() }
  }

  /// Project identity banner: current icon thumbnail + name + the root the
  /// tools are bound to.
  private var header: some View {
    HStack(spacing: 10) {
      thumbnail
        .frame(width: 40, height: 40)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.name)
          .font(.headline)
          .lineLimit(1)
        Text(row.rootURL?.path ?? row.catalogURL.deletingLastPathComponent().path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
      Spacer()
      statusBadge
    }
    .padding(.horizontal, 20)
    .padding(.top, 16)
    .padding(.bottom, 12)
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
        .font(.system(size: 20))
        .foregroundStyle(.tertiary)
    }
  }

  /// At-a-glance translation state, same semantics as the sidebar badge.
  @ViewBuilder
  private var statusBadge: some View {
    if row.hasRecords {
      Text(row.needsReviewKeyCount > 0
        ? "\(row.needsReviewKeyCount) need review · \(row.keyCount) keys"
        : "\(row.keyCount) keys")
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

  private func bindProjectCatalog() async {
    guard row.catalogExists else { return }
    guard localization.catalogURL != row.catalogURL else { return }
    await localization.open(row.catalogURL)
    // The open reconciled new records into the project — rebuild the rows
    // so sidebar badges track what the binding just changed.
    model.refresh()
  }
}

// MARK: - Project tool picker

/// The two tools a project pane can show. Tool-choice only; the project
/// identity comes from `SidebarSelection`, never from here.
private enum ProjectTool: String, CaseIterable, Identifiable {
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
