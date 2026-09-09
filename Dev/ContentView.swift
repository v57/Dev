import SwiftUI

/// Thin host for the project-centric split view: owns the ONE sidebar view
/// model (single source of truth for project/tool selection — the bottom
/// 'Current (no project)' section and the project-bound tools read it) and
/// the CreateIcon settings, then routes the detail pane from the sidebar
/// selection. The CreateIcon/Localization detail wiring is unchanged.
struct ContentView: View {
  @State private var model = SidebarViewModel()
  @State private var createIcon = CreateIcon()

  var body: some View {
    NavigationSplitView {
      SidebarView(model: model)
    } detail: {
      detailPane
    }
  }

  @ViewBuilder
  private var detailPane: some View {
    switch model.selection {
    case .tool(.icon):
      CreateIconView().environment(createIcon)
    case .tool(.localization):
      LocalizationView()
    case .project(let id):
      if let row = model.projectRow(id: id) {
        ProjectDetailView(row: row)
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
