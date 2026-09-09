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
    // Restore the remembered imported translation DB (path only — no open,
    // no scan) so the toolbar control and the pipeline know it is active.
    .task {
      ImportedTranslationDB.shared.restoreIfNeeded()
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Picker("Tool", selection: Binding<SidebarTool?>(
          get: { model.currentTool },
          set: { model.currentTool = $0 })) {
          Text("App Icon").tag(SidebarTool.icon as SidebarTool?)
          Text("Localization").tag(SidebarTool.localization as SidebarTool?)
        }
        .pickerStyle(.segmented)
        .help("Open the Create Icon or Localization tool (projectless)")
      }
    }
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
      ContentUnavailableView("Select a tool or a project", systemImage: "square.grid.2x2")
    }
  }
}

#Preview {
  ContentView()
}
