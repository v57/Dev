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
  /// The redesign's shell (Design notes 8.1): the bridge that builds a project's
  /// `Translation.Workspace` over the same SwiftData container the browser reads
  /// (10.16), so the toolbar's Start, the panes' overlays and the panes' status bars
  /// all speak about ONE redesign run. The old pipeline is untouched and carries on
  /// beside it (10.9).
  @State private var translation = Translation.Shell()

  var body: some View {
    @Bindable var model = model
    NavigationSplitView {
      SidebarView(model: model)
    } detail: {
      detailPane
    }
    .environment(createIcon)
    .environment(localizationStore)
    .environment(translation)
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
      // The redesign's Starts (Design notes 8.1): the one button that runs the
      // new plan — prepare, prelearn, learn, translate, then the row pass —
      // for the project whose Localization pane is showing, because that pane
      // is where its run reports (its overlay, and its status bar at the
      // foot). Its twin, immediately after it, is the same run with the two
      // learning steps left out (reader, 2026-09-14): the pane's own status bar
      // offers both, so the toolbar does too — wherever the reader looks for
      // Start, both ways to start it are there. Disabled while a run is in
      // flight: such a run is paused or cancelled from its own pages, and
      // pressing Start again resumes it.
      // The old pipeline's Translate button lives in that pane's own toolbar
      // and is untouched — the app carries both runs, side by side (10.9).
      if let catalogURL = paneCatalogURL {
        ToolbarItemGroup(placement: .primaryAction) {
          Button {
            Task { await translation.start(catalogURL) }
          } label: {
            Label("Start", systemImage: "play.fill")
          }
          .disabled(!translation.canStart(catalogURL))
          .help(translation.startHelp(catalogURL))
          // Icon-only, and the twin of the button beside it: it differs by ONE
          // thing — the learning steps — and the tooltip is where that is said.
          Button {
            Task { await translation.startSkippingLearning(catalogURL) }
          } label: {
            Image(systemName: "forward.fill")
          }
          .disabled(!translation.canStart(catalogURL))
          .help(translation.skipLearningHelp(catalogURL))
        }
      }
    }
  }

  /// The catalog of the project pane the toolbar is bound to, or nil when no
  /// project-bound translation pane is showing. The redesign's run belongs to
  /// that pane (8.1): its overlay covers the pane's catalog and its status bar
  /// sits at the pane's foot, so its Start belongs to the same project.
  private var paneCatalogURL: URL? {
    guard model.projectTool == .localization, case .project(let id) = model.selection,
      let row = model.projectRow(id: id)
    else { return nil }
    return row.catalogURL
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
