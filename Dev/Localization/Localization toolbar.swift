//
//  Localization toolbar.swift
//  Dev
//
//  Created by Dmitry on 09.09.26.
//

import ComponentKit
import SwiftUI

// MARK: - Controls

struct ControlsBar: ToolbarContent {
  let store: LocalizationStore
  /// Projectless mode offers Open…; a project-bound catalog (P40) doesn't —
  /// opening an arbitrary file would re-target the store's reconcile away
  /// from the selected project.
  var allowsOpenCatalog = true

  var body: some ToolbarContent {
    KitToolbarItem(placement: .primaryAction) {
      HStack(spacing: KitMetrics.gutter) {
        ToolGroup(iconOnly: true) {
          TranslationDBControl(store: store)
          if allowsOpenCatalog {
            Button("Open…", systemImage: "folder") { store.openPanelAndLoad() }
              .help("Open a String Catalog")
          }
          Button("Scan Strings", systemImage: "text.magnifyingglass") {
            store.startScan()
          }
          .disabled(!store.canScan)
          .help("Scan the project's Swift packages and Xcode targets for localizable strings, then merge the new keys into this catalog (existing translations are never touched)")
          Button("Save", systemImage: "square.and.arrow.down") {
            Task { await store.save() }
          }
          .keyboardShortcut("s")
          .disabled(!store.canSave)
          .help(store.canSave
            ? "Write the edited catalog to \(store.unsavedCatalogName) — nothing saves on its own"
            : "No unsaved changes")
          Button("Reload", systemImage: "arrow.clockwise") {
            Task { await store.reload() }
          }
          .disabled(!store.isLoaded)
          .help("Read the catalog file again")
        }
        ToolGroup(iconOnly: true) {
          Toggle(isOn: Binding(
            get: { store.includeNonTranslatable },
            set: { store.includeNonTranslatable = $0 })) {
              Label("Non-translatable Keys", systemImage: "eye")
            }
            .help("Include the \(store.nonTranslatableCount) keys marked shouldTranslate = false (hidden by default)")
          Toggle(isOn: Binding(
            get: { store.showComments },
            set: { store.setShowComments($0) })) {
              Label("Comments", systemImage: "text.bubble")
            }
            .help("Show comment text under each source value")
          Toggle(isOn: Binding(
            get: { store.showLongest },
            set: { store.setShowLongest($0) })) {
              Label("Longest", systemImage: "ruler")
            }
            .help("Show the Longest column (longest value across all languages)")
          Button("Context Rules", systemImage: "text.book.closed") {
            store.openContextDocs()
          }
          .disabled(!store.isLoaded)
          .help("Edit the project context rules the translator follows — one rule per line, and deleting a line retracts it")
        }
        .toggleStyle(ToolToggleStyle())
      }
    }
  }

  /// A toggle as one of the group's tools: the accent glyph while on, the quiet slashed one while off.
  struct ToolToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
      Button {
        withAnimation(.kit) {
          configuration.isOn.toggle()
        }
      } label: {
        configuration.label
          .foregroundStyle(configuration.isOn ? AnyShapeStyle(Hue.accent.text) : AnyShapeStyle(.kitSecondary))
          .symbolVariant(configuration.isOn ? .fill : .none.slash)
          .contentTransition(.symbolEffect)
      }
      .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
  }
}
