import SwiftUI

/// Thin host for the project-centric split view: owns the ONE sidebar view
/// model (single source of truth for project/tool selection — the bottom
/// 'Current (no project)' section and the project-bound tools read it) and
/// the two shared tool observables (CreateIcon settings + the
/// LocalizationStore's open catalog), then routes the detail pane from the
/// sidebar selection. Both are injected at the split level so the sidebar's
/// live 'Current (no project)' mini-status rows and the tools themselves
/// read the SAME instances.
struct ContentView: View {
  @State private var model = SidebarViewModel()
  @State private var createIcon = CreateIcon()
  @State private var localizationStore = LocalizationStore()

  var body: some View {
    NavigationSplitView {
      SidebarView(model: model)
    } detail: {
      detailPane
    }
    .environment(createIcon)
    .environment(localizationStore)
  }

  @ViewBuilder
  private var detailPane: some View {
    switch model.selection {
    case .tool(.icon):
      CreateIconView()
    case .tool(.localization):
      LocalizationView()
    case .project(let id):
      if let row = model.projectRow(id: id) {
        ProjectDetailView(model: model, row: row)
      } else {
        ContentUnavailableView("Project not found", systemImage: "folder.badge.questionmark")
      }
    case nil:
      ContentUnavailableView("Select a project", systemImage: "sidebar.left")
    }
  }
}

#Preview {
  ContentView()
}
