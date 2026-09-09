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
          .disabled(store.run.isRunning)
      }
      Button {
        Task { await store.reload() }
      } label: {
        Label("Reload", systemImage: "arrow.clockwise")
      }
      .disabled(!store.isLoaded || store.run.isRunning)
    }
    ToolbarItemGroup(placement: .principal) {
      Picker(
        selection: Binding(get: { store.filter }, set: { store.filter = $0 }),
        label: EmptyView()) {
        ForEach(RowFilter.allCases) { rowFilter in
          Label(rowFilter.title, systemImage: rowFilter.icon).tag(rowFilter)
        }
      }
      .pickerStyle(.segmented)
      .fixedSize()
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
        store.startTranslate()
      } label: {
        Label("Translate", systemImage: "translate")
      }
      .buttonStyle(.borderedProminent)
      .disabled(!store.canTranslate)
      .help(store.run.isRunning
        ? "A translation run is in progress — cancel it from the footer"
        : "Run the translation pipeline: learn from confirmed edits, resolve translation memory, then Apple, Ollama and review")
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
