//
//  SidebarView.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import SwiftUI

/// Sidebar column of the split view: the 'Projects' section (P20) — one row
/// per imported project, with drag-and-drop directory/catalog import — plus
/// the PROJECTLESS tools pinned to the bottom safe area.
///
/// The bottom bar carries the two tools that are NOT bound to a project,
/// with LIVE mini-status: an app-icon thumbnail mirroring the shared
/// CreateIcon settings/result and the open-catalog key/needs-review summary
/// from the shared LocalizationStore. Both observables are injected by
/// ContentView at the split level, so the rows update as the tools edit
/// their state. Each row writes the same `.tool` selection the detail pane
/// routes — one source of truth for what is open.
struct SidebarView: View {
  let model: SidebarViewModel

  /// The shared open-catalog store: the context menu asks it before removing
  /// a project whose catalog it is showing (unsaved edits / a run in flight
  /// refuse the removal, and an idle open catalog is closed with the row).
  @Environment(LocalizationStore.self) private var localization
  /// The Localization Servers this app works against, and their last check.
  @Environment(ServerStore.self) private var servers
  /// Which server the form sheet is adding or editing (nil = no sheet). Owned
  /// here so the toolbar button, the empty-state row and a row's Edit… all open
  /// the SAME sheet.
  @State private var serverSheet: ServerSheet?

  var body: some View {
    @Bindable var model = model
    List(selection: $model.selection) {
      // Servers first: they are where the app's data comes from, and the
      // 'Add Connection' button has to be visible without opening anything.
      ServersSidebarSection(
        store: servers,
        selection: $model.selection) { sheet in
          serverSheet = sheet
        }
      Section("Projects") {
        if model.projects.isEmpty {
          dropHintRow
        } else {
          ForEach(model.projects) { row in
            NavigationLink(value: SidebarSelection.project(row.id)) {
              ProjectRow(row: row)
            }
            .contextMenu {
              Button("Remove Project", role: .destructive) {
                model.removeProject(id: row.id, localization: localization)
              }
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          serverSheet = .add
        } label: {
          Label("Add Connection", systemImage: "plus")
        }
        .help("Connect a server that serves its strings through the Localization Server API")
      }
    }
    .sheet(item: $serverSheet) { sheet in
      switch sheet {
      case .add:
        ServerFormView { name, endpoint, key in
          // The id the new server gets is not needed here: the sheet closes and
          // the row appears in the list. An untouched key field arrives as nil
          // and means the shared key, i.e. no own keychain item.
          _ = servers.add(name: name, endpoint: endpoint, key: key ?? "")
        }
      case .edit(let id):
        ServerFormView(editing: servers.connection(id: id)) { name, endpoint, key in
          servers.update(id: id, name: name, endpoint: endpoint, key: key)
        }
      }
    }
    // First sight of the sidebar: build the rows, then ask every server how it
    // is doing. Nothing polls after this — a check is a reader action.
    .task {
      servers.refresh()
      await servers.checkAll()
    }
    // Projectless tools live here, not in the toolbar picker: the picker is
    // project-bound and only exists while a project is open.
    .compatSafeAreaBar(edge: .bottom) {
      ProjectlessBar(model: model)
    }
    .dropDestination(for: URL.self) { urls, _ in
      // Import searches a dropped directory for its catalog, so it is async.
      // Return true immediately — the drop is accepted — and let the row and
      // its selection land when the walk finishes.
      Task {
        if let firstID = await model.importDroppedURLs(urls) {
          model.selection = .project(firstID)
        }
      }
      return true
    } isTargeted: {
      model.isDropTargeted = $0
    }
    .overlay {
      if model.isDropTargeted {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
          .padding(6)
          .allowsHitTesting(false)
      }
    }
    .sheet(isPresented: Binding(
      get: { !model.importSuggestions.isEmpty },
      set: { if !$0 { model.importSuggestions = [] } }
    )) {
      ImportSuggestionsSheet(suggestions: model.importSuggestions) { urls in
        Task {
          if let firstID = await model.addSuggestedDirectories(urls) {
            model.selection = .project(firstID)
          }
        }
      }
    }
    .alert(model.alert?.title ?? "", isPresented: Binding(
      get: { model.alert != nil },
      set: { if !$0 { model.alert = nil } }
    )) {
      Button("OK") { model.alert = nil }
    } message: {
      Text(model.alert?.message ?? "")
    }
    .task { model.refresh() }
    .onChange(of: model.selection) {
      // A selection usually precedes a reconcile (catalog open); refresh so
      // badges track the record state the interaction just changed.
      model.refresh()
    }
  }

  /// Empty Projects section: still a drop target, so the hint invites the
  /// one gesture that fills it.
  private var dropHintRow: some View {
    HStack(spacing: 8) {
      Image(systemName: "folder.badge.plus")
        .foregroundStyle(.tertiary)
      Text("Drag a project, or a folder of repos, here")
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Project row

/// One project row: icon thumbnail + display name + compact translation
/// badge (needs-review keys / total keys from the reconciled records).
private struct ProjectRow: View {
  let row: SidebarProjectRow

  var body: some View {
    HStack(spacing: 8) {
      thumbnail
        .frame(width: 26, height: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.name)
          .lineLimit(1)
        badge
      }
    }
    .padding(.vertical, 1)
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
        .font(.system(size: 15))
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private var badge: some View {
    if row.hasRecords {
      Text("\(row.keyCount) keys")
        .font(.caption)
        .foregroundStyle(.secondary)
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
}

// MARK: - Projectless tools (bottom bar)

/// The sidebar's bottom bar: the two PROJECTLESS tools, always reachable
/// while no project is open, plus the app-level action that empties the
/// translation store (Design notes 7.5).
///
/// The clear lives HERE rather than in the app's menu because it is the one
/// action with nothing selected to hang off — it spans every project at once —
/// and this is where the app already keeps exactly those; the bar is on screen
/// whatever the detail pane shows, and the prompt it raises is a SwiftUI alert
/// bound to the state the rows beside it read, with no menu-to-object-graph
/// bridge to invent. Selecting a row routes the detail pane through the same
/// shared selection the project rows use.
private struct ProjectlessBar: View {
  let model: SidebarViewModel

  /// The app's own open catalog: the clear has to reload what it is showing.
  @Environment(LocalizationStore.self) private var localization
  /// The redesign's shell: the clear has to drop its workspaces.
  @Environment(Translation.Shell.self) private var shell

  /// The confirmation first, then what the clear did. ONE prompt at a time, and
  /// never the model's alert (that one belongs to the project rows and to
  /// removing a project).
  @State private var prompt: ClearPrompt?

  var body: some View {
    VStack(spacing: 2) {
      ForEach(DevTool.projectless) { tool in
        ProjectlessRow(tool: tool, isSelected: model.currentTool == tool) {
          model.selection = .tool(tool)
        }
      }
      // Pinned here rather than in the list: at the list's end it scrolled
      // under this bar and out of sight.
      Button {
        model.selection = .storage
      } label: {
        StorageSidebarRow()
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(model.selection == .storage ? Color.accentColor.opacity(0.18) : Color.clear))
      .help("What fills this Mac, by developer category")
      Divider()
        .padding(.vertical, 3)
      clearRow
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .alert(
      prompt?.title ?? "",
      isPresented: Binding(
        get: { prompt != nil },
        set: { if !$0 { prompt = nil } }
      )
    ) {
      if prompt == .confirm {
        Button("Cancel", role: .cancel) { prompt = nil }
        Button("Clear Store", role: .destructive) { clear() }
      } else {
        Button("OK") { prompt = nil }
      }
    } message: {
      Text(prompt?.message ?? "")
    }
  }

  /// The one destructive control the app has outside a project.
  ///
  /// DISABLED, not stopping anything, while a writer is in flight (see
  /// `storeClearBlocker`): stopping a run is not a thing that happens instantly —
  /// a cancel lands at the run's next suspension point — so a clear that stopped
  /// one could still race the write-back it had in flight. The row says which
  /// writer it is waiting for instead of failing after the fact.
  private var clearRow: some View {
    let blocker = storeClearBlocker(localization: localization, shell: shell)
    return Button {
      prompt = .confirm
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "trash")
          .font(.system(size: 14))
          .foregroundStyle(.tertiary)
          .frame(width: 24, height: 24)
        VStack(alignment: .leading, spacing: 1) {
          Text("Clear Translation Store")
            .lineLimit(1)
          Text(blocker ?? "Slots, journal, context, memory, cursors")
            .font(.caption)
            .foregroundStyle(blocker == nil ? Color.secondary : Color.orange)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(blocker != nil)
    .help("Delete every project's slots, journal, context documents, memory and run cursors. "
      + "The project list and every .xcstrings file stay.")
  }

  /// One press: the confirmation is answered, so the clear runs (it re-reads the
  /// open catalog, so it is worth a Task of its own), the sidebar's badges are
  /// refreshed — they ARE record counts — and the report is what comes back on
  /// screen.
  private func clear() {
    Task {
      let outcome = await clearTranslationStore(localization: localization, shell: shell)
      model.refresh()
      prompt = .result(outcome)
    }
  }

  /// What the bar is showing: the confirmation, or the report.
  private enum ClearPrompt: Equatable {
    case confirm
    case result(StoreClearOutcome)

    var title: String {
      switch self {
      case .confirm: "Clear the translation store?"
      case .result(.cleared): "Translation store cleared"
      case .result(.alreadyEmpty): "Nothing to clear"
      case .result(.refused): "A writer is in flight"
      case .result(.failed): "Couldn't clear the translation store"
      }
    }

    var message: String {
      switch self {
      case .confirm:
        """
        This deletes every slot value, the journal of edits, the context documents, \
        the translation memory and the saved run positions — the app-side session, \
        for every project at once.

        It stays: the project list, and every .xcstrings file. A catalog keeps the \
        strings and the translations already written into it.

        What a re-scan cannot rebuild: the context documents and the translation \
        memory are what the app LEARNED from your corrections, and this deletes \
        them. Edits a window is still holding — anything not yet written to a file — \
        go with the session.

        Open catalogs re-read their files afterwards and read as untranslated work. \
        The rows go in ONE pass, so even a large store is emptied in a second or two.
        """
      case .result(.cleared(let counts)):
        "Removed \(counts.summary). Every project and every .xcstrings is still here."
      case .result(.alreadyEmpty):
        "There was nothing to delete: the store held no slot records, journal rows, "
          + "context documents, memory entries or run cursors. That is not an error."
      case .result(.refused(let reason)), .result(.failed(let reason)):
        reason
      }
    }
  }
}

// MARK: - Clearing the store (Design notes 7.5)

/// What one press of the clear did. Every branch is a state the bar reports, so
/// the button never fails silently and a second press is never an error.
enum StoreClearOutcome: Equatable {
  /// The store held rows: this is what was deleted, per model.
  case cleared(StoreClearCounts)
  /// The store was already empty — the second press, which does nothing.
  case alreadyEmpty
  /// Nothing was touched: a writer is in flight.
  case refused(String)
  /// The delete or its save failed.
  case failed(String)
}

/// Why the clear cannot run right now, or nil when it can.
///
/// A WRITER in flight is the one hard reason (7.5): a run writes records into the
/// store as it goes, and an open's mirror writes a whole catalog's slots into it
/// behind the pane — so a clear that ran under either would leave a live writer
/// writing into a store that just emptied. The button is disabled on this AND the
/// flow refuses on it, so the safety does not depend on the button being the only
/// caller.
@MainActor
func storeClearBlocker(localization: LocalizationStore, shell: Translation.Shell) -> String? {
  if localization.isLoading {
    return "A catalog is opening — clear once it has landed"
  }
  if localization.isSyncing {
    return "The store is still catching up with a catalog — clear once it has"
  }
  if localization.scan.isRunning || localization.isAddingLanguage
    || shell.isRunning {
    return "A run is in flight — finish or cancel it first"
  }
  return nil
}

/// The clear itself, in the ONE order that is safe.
///
/// Everything the app holds OVER the store lets go FIRST, in this same
/// main-actor turn: an open pane's rows carry the record objects themselves, and
/// the redesign's workspaces were built from them, so rows deleted under a live
/// cache leave this window reading values that no longer exist. Then the rows go
/// — one delete per row, in `TranslationStore.clear()` — and then both halves
/// rebuild what they can: the browser re-reads its open artifact (no mirror, or
/// the records would come straight back), the redesign's workspaces are rebuilt
/// from those artifacts, and the old pipeline's run summary is dropped. What
/// cannot be rebuilt is what was deleted, and 7.5 says so on screen before the
/// press.
@MainActor
@discardableResult
func clearTranslationStore(
  localization: LocalizationStore, shell: Translation.Shell
) async -> StoreClearOutcome {
  if let blocker = storeClearBlocker(localization: localization, shell: shell) {
    return .refused(blocker)
  }
  localization.dropStoreMirror()
  shell.dropStoreCaches()
  let outcome: StoreClearOutcome
  do {
    let counts = try TranslationStore.shared.clear()
    outcome = counts.isEmpty ? .alreadyEmpty : .cleared(counts)
  } catch {
    outcome = .failed(error.localizedDescription)
  }
  // Whatever the store did — a save that failed can still have taken the rows out
  // of the context — the app-side halves come back over it rather than keep the
  // readings they had.
  await localization.reloadAfterStoreClear()
  shell.rebuildAfterStoreClear()
  return outcome
}

/// One projectless tool row: live mini-status + selection highlight.
private struct ProjectlessRow: View {
  let tool: DevTool
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        ProjectlessThumbnail(tool: tool)
          .frame(width: 24, height: 24)
        VStack(alignment: .leading, spacing: 1) {
          Text(tool.title)
            .lineLimit(1)
          status
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear))
    .help("Open the projectless \(tool.title) tool")
  }

  /// Same at-a-glance status the old list rows carried.
  @ViewBuilder
  private var status: some View {
    switch tool {
    case .icon:
      CreateIconStatus()
    case .localization:
      LocalizationStatus()
    case .release:
      EmptyView()
    }
  }
}

/// Live summary of the shared CreateIcon settings/result.
private struct CreateIconStatus: View {
  @Environment(CreateIcon.self) private var create

  var body: some View {
    Text(create.settings.preview ? "Rendered PNG" : "Live preview")
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }
}

/// Live summary of the shared LocalizationStore's open catalog.
private struct LocalizationStatus: View {
  @Environment(LocalizationStore.self) private var store

  var body: some View {
    Group {
      if store.isLoaded {
        Text("\(store.totalKeyCount) keys")
          .foregroundStyle(.secondary)
      } else {
        Text("No catalog open")
          .foregroundStyle(.tertiary)
      }
    }
    .font(.caption)
    .lineLimit(1)
  }
}

/// Mini thumbnail: the shared CreateIcon render for the icon tool, the SF
/// glyph for localization. Never re-runs generation.
private struct ProjectlessThumbnail: View {
  let tool: DevTool
  @Environment(CreateIcon.self) private var create

  var body: some View {
    switch tool {
    case .icon:
      iconThumbnail
    case .localization, .release:
      Image(systemName: tool.systemImage)
        .font(.system(size: 15))
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private var iconThumbnail: some View {
    Group {
      if create.settings.preview, let result = create.result {
        Image(nsImage: result)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
      } else {
        liveRender
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  /// Tiny live icon: rounded background (flat/gradient) + the SF glyph at
  /// the same proportional size CreateIconView's preview uses.
  private var liveRender: some View {
    GeometryReader { view in
      ZStack {
        if create.settings.gradient {
          LinearGradient(
            colors: [create.settings.primary, create.settings.secondary],
            startPoint: .top, endPoint: .bottom)
        } else {
          create.settings.primary
        }
        Image(systemName: create.settings.symbol)
          .font(.system(size: view.size.width * 0.5 * create.settings.scale))
          .foregroundStyle(create.settings.glyph.opacity(0.8))
      }
    }
    .aspectRatio(1, contentMode: .fit)
  }
}
