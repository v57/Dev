import AppKit
import ComponentKit
import DevScreenshots
import SwiftData
import SwiftUI

/// Thin host for the project-centric split view: owns the ONE sidebar view
/// model (single source of truth for project/tool selection) and the shared
/// tool observables, injected at the split level so the sidebar rows and the
/// tools read the SAME instances, then routes the detail pane from the
/// sidebar selection.
///
/// A selected project gets the toolbar's tab control — Overview, Localization,
/// App Icon, Screenshots, Workflows — and opens on Overview (or the tab it was
/// last left on). With no project yet, the pane is the welcome screen.
struct ContentView: View {
  @Environment(\.openSettings) private var openSettings
  /// A screenshot scene asks for Settings; the view opens it, since the environment's
  /// action only works from a view update.
  @State private var settingsRequests = 0
  @State private var model = SidebarViewModel()
  /// The demo project a screenshot launch imported: scenes that open a tool come back to it.
  @State private var demoProject: PersistentIdentifier?
  @State private var createIcon = CreateIcon()
  @State private var localizationStore = LocalizationStore()
  /// The localize servers the sidebar lists and the server pane reads: one
  /// instance for both, so a check that flips a dot is the same fact the pane
  /// shows.
  @State private var servers = ServerStore()
  /// The Storage tool's last scan: the sidebar row and the pane read the same one.
  @State private var storage = StorageStore()
  /// The UTM VMs and their Run on VM logs.
  @State private var vms = VMStore()
  /// The redesign's shell (Design notes 8.1): the bridge that builds a project's
  /// `Translation.Workspace` over the same SwiftData container the browser reads
  /// (10.16), so the toolbar's Start, the panes' overlays and the panes' status bars
  /// all speak about ONE run.
  @State private var translation = Translation.Shell()
  /// Screenshot captures and their framing, per project.
  @State private var screenshots = ScreenshotsStore()
  /// Workflow definitions and runs, per project.
  @State private var workflows = WorkflowStore()
  /// Requests from agents over MCP that need this window: runs and "Ask First".
  @State private var agents = AgentBridge()

  var body: some View {
    @Bindable var model = model
    NavigationSplitView {
      // The kit sidebar's own bottom bar has the toggle.
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 360)
        .toolbar(removing: .sidebarToggle)
    } detail: {
      detailPane
    }
    .environment(createIcon)
    .environment(localizationStore)
    .environment(servers)
    .environment(storage)
    .environment(vms)
    .environment(translation)
    .environment(screenshots)
    .environment(workflows)
    .navigationTitle(windowTitle)
    .navigationSubtitle(windowSubtitle)
    // The kit's rich title stands in for the window's.
    .kitHidesSystemTitle()
    .onAppear {
      AppContext.shared.localization = localizationStore
      AppContext.shared.shell = translation
      AppContext.shared.sidebar = model
      workflows.vms = vms
      agents.workflows = workflows
      agents.screenshots = screenshots
      workflows.watchedRoots = model.projects.compactMap(\.rootURL)
    }
    .onChange(of: model.projects.compactMap(\.rootURL)) { _, roots in
      workflows.watchedRoots = roots
    }
    .alert(
      "\(agents.pending?.client ?? "An agent") wants to \(agents.pending?.summary ?? "")",
      isPresented: Binding(get: { agents.pending != nil }, set: { _ in })
    ) {
      Button("Don't Allow", role: .cancel) { agents.answer(false) }
      Button("Allow") { agents.answer(true) }
    } message: {
      Text("The request came over Dev's MCP server. Settings ▸ Agents sets what agents may do without asking.")
    }
    // File ▸ New Icon: the App Icon tool without a project.
    .onReceive(NotificationCenter.default.publisher(for: .devOpenProjectlessIcon)) { _ in
      model.selection = .tool(.icon)
    }
    .onReceive(NotificationCenter.default.publisher(for: .devAddProject)) { _ in
      model.addProjectsFromPanel()
    }
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
    // Versions prompt: the file and the app's records carry different values for
    // the same slot, so the load asks which version to load instead of keeping
    // the cached records and dropping the file's (or the other way round). The
    // parse is held until this is answered — nothing is opened before it is.
    .alert(localizationStore.versionsPromptTitle, isPresented: Binding(
      get: { localizationStore.isVersionsPromptPresented },
      set: { if !$0 { localizationStore.dismissVersionsPrompt() } }
    )) {
      Button("Load the File's Values") {
        Task { await localizationStore.resolveDifferences(.file) }
      }
      Button("Keep the App's Records") {
        Task { await localizationStore.resolveDifferences(.app) }
      }
      Button("Cancel", role: .cancel) {
        Task { await localizationStore.resolveDifferences(.cancel) }
      }
    } message: {
      Text(localizationStore.versionsPromptMessage)
    }
    // Restore the remembered imported translation DB (path only — no open,
    // no scan) so the pipeline knows it is active.
    .task {
      guard !LaunchOptions.isScreenshotMode else { return }
      ImportedTranslationDB.shared.restoreIfNeeded()
    }
    // The projects the v57 apps share (added in Git and the others) join the sidebar.
    .task { VaultProjects.shared.start(model: model) }
    // A folder opened in Dev (Shell's Open With, `open -a Dev <folder>`): added like a drop, then shown.
    .onOpenURL { url in
      guard url.isFileURL else { return }
      Task {
        if let id = await model.importDroppedURLs([url]) { model.selection = .project(id) }
      }
    }
    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    // Screenshots (.dev/screenshots.json): a demo project instead of a dropped one, and
    // each scene's tool from its arguments, all scenes in one launch.
    .task {
      Screenshots.prepare(waitsForReady: true) { scene in await open(scene.arguments) }
      let demo = LaunchOptions.demoProjects
      if !demo.isEmpty, let first = await model.importDroppedURLs(demo) {
        demoProject = first
        model.selection = .project(first)
      }
      await open(ProcessInfo.processInfo.arguments)
      Screenshots.ready()
    }
    .onChange(of: settingsRequests) { openSettings() }
    .toolbar {
      KitToolbarItem(placement: .navigation) {
        windowTitleView.padding(.leading, 6)
      }
      // The project's tabs: only while a project is open.
      if model.hasSelectedProject {
        KitToolbarItem(placement: .principal) {
          KitSegmented(
            selection: $model.projectTool,
            segments: DevTool.allCases.map { KitSegment($0.title, value: $0) }
          )
          .help("Switch between this project's tools (⌘1–⌘5)")
        }
      }
      // One Translate button for the project whose Localization pane is showing:
      // it runs the whole plan (prepare, prelearn, learn, translate, the row pass);
      // its menu holds the same run without the two learning steps. Disabled while
      // a run is in flight: such a run is paused or cancelled from its own pages,
      // and pressing Translate again resumes it.
      if let catalogURL = paneCatalogURL {
        KitToolbarItem(placement: .primaryAction) {
          ToolGroup {
            Menu {
              Button("Translate Without Learning") {
                Task { await translation.startSkippingLearning(catalogURL) }
              }
              .help(translation.skipLearningHelp(catalogURL))
            } label: {
              Label("Translate", systemImage: "play.fill")
            } primaryAction: {
              Task { await translation.start(catalogURL) }
            }
            .menuIndicator(.visible)
            .disabled(!translation.canStart(catalogURL))
            .help(translation.startHelp(catalogURL))
          }
        }
      }
    }
    // ⌘1–⌘5 switch the tabs of the open project.
    .background {
      if model.hasSelectedProject {
        ForEach(Array(DevTool.allCases.enumerated()), id: \.element) { index, tool in
          Button("") { model.projectTool = tool }
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            .hidden()
        }
      }
    }
  }

  /// The toolbar's rich title: the open project (its icon, name and folder), or the tool.
  @ViewBuilder
  private var windowTitleView: some View {
    if case .project(let id) = model.selection, let row = model.projectRow(id: id) {
      RichHeader(Text(row.name), size: .title) {
        if let icon = row.iconImage {
          Image(nsImage: icon).resizable().interpolation(.high).frame(width: 28, height: 28)
        } else {
          Tile(systemImage: "app.dashed", hue: .blue, size: 28)
        }
      } meta: {
        Text(windowSubtitle).truncationMode(.middle)
      } accessory: {
        EmptyView()
      }
      .frame(maxWidth: 200)
    } else {
      KitTitle(windowTitle, systemImage: windowSymbol, hue: .gray)
    }
  }

  /// The symbol of what the window shows when it isn't a project.
  private var windowSymbol: String {
    switch model.selection {
    case .tool(.icon): "app.badge"
    case .storage: "internaldrive"
    case .vms: "desktopcomputer"
    case .server: "server.rack"
    default: "hammer"
    }
  }

  /// The window title: the open project, tool, or Dev.
  private var windowTitle: String {
    switch model.selection {
    case .project(let id): return model.projectRow(id: id)?.name ?? "Dev"
    case .tool(.icon): return "App Icon"
    case .storage: return "Storage"
    case .vms: return "Virtual Machines"
    case .server(let id): return servers.connection(id: id)?.name ?? "Localization Server"
    default: return "Dev"
    }
  }

  /// The line under the title: the project's folder, or nothing.
  private var windowSubtitle: String {
    guard case .project(let id) = model.selection, let row = model.projectRow(id: id) else { return "" }
    let path = (row.rootURL ?? row.catalogURL.deletingLastPathComponent()).path(percentEncoded: false)
    return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
  }

  /// A screenshot scene's screen, from its arguments: `-DevTool <tab>` picks the project's tab
  /// (`overview|localization|icon|screenshots|workflows`), `-DevOpen storage|vms` a tool instead,
  /// `-DevSettings` or `-DevSettingsTab <tab>` opens Settings, and `-DevRunWorkflow <id>` starts that
  /// workflow of the demo project.
  private func open(_ arguments: [String]) async {
    guard LaunchOptions.isScreenshotMode else { return }
    func value(after flag: String) -> String? {
      guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
      return arguments[index + 1]
    }
    switch value(after: "-DevOpen") {
    case "storage": model.selection = .storage
    case "vms": model.selection = .vms
    default: if let demoProject { model.selection = .project(demoProject) }
    }
    if let tab = value(after: "-DevTool").flatMap(DevTool.init(rawValue:)) { model.projectTool = tab }
    if let tab = value(after: "-DevSettingsTab") {
      UserDefaults.standard.set(tab, forKey: "settings.tab")
      settingsRequests += 1
    } else if arguments.contains("-DevSettings") {
      settingsRequests += 1
    }
    if let id = value(after: "-DevRunWorkflow"), let demoProject, let root = model.projectRow(id: demoProject)?.rootURL,
       let workflow = workflows.workflows(for: root).first(where: { $0.id == id }) {
      workflows.start(workflow, in: root, startedBy: "launch argument")
    }
    // A catalog loads after the tool opens.
    if model.projectTool == .localization {
      for _ in 0..<100 where localizationStore.catalogURL == nil { try? await Task.sleep(for: .milliseconds(100)) }
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
    case .tool:
      EmptyState(systemImage: "sidebar.left", title: "Select a Project").kitPane()
    case .project(let id):
      if let row = model.projectRow(id: id) {
        ProjectDetailView(model: model, row: row)
      } else {
        EmptyState(systemImage: "folder.badge.questionmark", title: "Project Not Found").kitPane()
      }
    case .server(let id):
      ServerDetailView(serverID: id, store: servers)
    case .storage:
      StorageView()
    case .vms:
      VMsView(projects: model.projects)
    case nil:
      if model.projects.isEmpty {
        WelcomeView(model: model)
      } else {
        EmptyState(
          systemImage: "sidebar.left", title: "Select a Project",
          message: "Pick a project in the sidebar, or open Storage or Virtual Machines."
        ).kitPane()
      }
    }
  }
}

extension Notification.Name {
  /// File ▸ New Icon.
  static let devOpenProjectlessIcon = Notification.Name("dev.openProjectlessIcon")
  /// File ▸ Add Project…
  static let devAddProject = Notification.Name("dev.addProject")
}

#Preview {
  ContentView()
}
