import SwiftUI

/// Thin host for the project-centric split view: owns the ONE sidebar view
/// model (single source of truth for project/tool selection — the sidebar's
/// projectless bottom bar and the project-bound tools read it) and the two
/// shared tool observables (CreateIcon settings + the LocalizationStore's
/// open catalog), then routes the detail pane from the sidebar selection.
/// Both are injected at the split level so the sidebar's live projectless
/// mini-status rows and the tools themselves read the SAME instances.
///
/// There is exactly ONE tool picker — the toolbar one — and it is
/// PROJECT-BOUND: it appears only while a project is the selection, starts
/// deselected, and picks which tool fills the pane for that project.
/// Projectless tools are reached from the sidebar's bottom bar instead.
struct ContentView: View {
  @State private var model = SidebarViewModel()
  @State private var createIcon = CreateIcon()
  @State private var localizationStore = LocalizationStore()

  var body: some View {
    @Bindable var model = model
    NavigationSplitView {
      SidebarView(model: model)
    } detail: {
      detailPane
    }
    .environment(createIcon)
    .environment(localizationStore)
    // Unsaved-changes prompt: Reload…, Open…, a sidebar project switch and
    // quitting all hold their request here until it is answered, because
    // Save is the only writer of the .xcstrings. Attached at the root so a
    // hidden Localize pane cannot swallow the prompt.
    .alert(localizationStore.unsavedChangesTitle, isPresented: Binding(
      get: { localizationStore.isUnsavedPromptPresented },
      set: { if !$0 { localizationStore.dismissUnsavedPrompt() } }
    )) {
      Button("Save") { Task { await localizationStore.resolvePendingLeave(.save) } }
      Button("Discard", role: .destructive) {
        Task { await localizationStore.resolvePendingLeave(.discard) }
      }
      Button("Cancel", role: .cancel) {
        Task { await localizationStore.resolvePendingLeave(.cancel) }
      }
    } message: {
      Text(localizationStore.unsavedChangesMessage)
    }
    // Restore the remembered imported translation DB (path only — no open,
    // no scan) so the pipeline knows it is active.
    .task {
      ImportedTranslationDB.shared.restoreIfNeeded()
    }
    .toolbar {
      // The one tool picker: project-bound, so it is absent until a project
      // is opened, and deselected (nil) by default.
      if model.hasSelectedProject {
        ToolbarItemGroup(placement: .primaryAction) {
          Picker("Tool", selection: $model.projectTool) {
            ForEach(DevTool.allCases) { tool in
              Text(tool.title).tag(tool as DevTool?)
            }
          }
          .pickerStyle(.segmented)
          .help("Open a tool for the selected project")
        }
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
      ContentUnavailableView("Select a project", systemImage: "sidebar.left")
    }
  }
}

#Preview {
  ContentView()
}
