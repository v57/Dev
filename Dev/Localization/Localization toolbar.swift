//
//  Localization toolbar.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import SwiftUI

// MARK: - Controls

struct ControlsBar: ToolbarContent {
  let store: LocalizationStore
  /// Projectless mode offers Open…; a project-bound catalog (P40) doesn't —
  /// opening an arbitrary file would re-target the store's reconcile away
  /// from the selected project.
  var allowsOpenCatalog = true

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .secondaryAction) {
      TranslationDBControl(store: store)
    }
    ToolbarItemGroup(placement: .primaryAction) {
      if allowsOpenCatalog {
        Button("Open…") { store.openPanelAndLoad() }
      }
      Button {
        store.startScan()
      } label: {
        Label("Scan Strings", systemImage: "text.magnifyingglass")
      }
      .disabled(!store.canScan)
      .help("Scan the project's Swift packages and Xcode targets for localizable strings, then merge the new keys into this catalog (existing translations are never touched)")
      Button {
        Task { await store.save() }
      } label: {
        Label("Save", systemImage: "square.and.arrow.down")
      }
      .keyboardShortcut("s")
      .disabled(!store.canSave)
      .help(store.canSave
        ? "Write the edited catalog to \(store.unsavedCatalogName) — nothing saves on its own"
        : "No unsaved changes")
      Button {
        Task { await store.reload() }
      } label: {
        Label("Reload", systemImage: "arrow.clockwise")
      }
      .disabled(!store.isLoaded)
    }
    ToolbarItemGroup(placement: .primaryAction) {
      Toggle(isOn: Binding(
        get: { store.includeNonTranslatable },
        set: { store.includeNonTranslatable = $0 })) {
          Image(systemName: "eye")
        }
        .help("Include the \(store.nonTranslatableCount) keys marked shouldTranslate = false (hidden by default)")
        .toggleStyle(ToggleButtonStyle())

      Toggle(isOn: Binding(
        get: { store.showComments },
        set: { store.setShowComments($0) })) {
          Image(systemName: "text.bubble")
        }
        .help("Show comment text under each source value")
        .toggleStyle(ToggleButtonStyle())

      Toggle(isOn: Binding(
        get: { store.showLongest },
        set: { store.setShowLongest($0) })) {
          Image(systemName: "ruler")
        }
        .help("Show the Longest column (longest value across all languages)")
        .toggleStyle(ToggleButtonStyle())

      Button {
        store.openContextDocs()
      } label: {
        Label("Context Rules", systemImage: "text.book.closed")
      }
      .disabled(!store.isLoaded)
      .help("Edit the project context rules the translator follows — one rule per line, and deleting a line retracts it")

    }
  }
  struct ToggleButtonStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
      Button {
        withAnimation {
          configuration.isOn.toggle()
        }
      } label: {
        configuration.label
          .foregroundStyle(configuration.isOn ? .blue : .secondary)
          .symbolVariant(configuration.isOn ? .fill : .none.slash)
          .contentTransition(.symbolEffect)
      }.buttonStyle(.plain)
    }
  }
}
