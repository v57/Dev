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

  /// Two toolbar items, so a narrow window folds the view toggles into the toolbar's overflow first and keeps the
  /// catalog's own tools (the translation database, Scan Strings, Save) in sight.
  var body: some ToolbarContent {
    KitToolbarItem(placement: .primaryAction) {
      ToolGroup(iconOnly: true) {
        TranslationDBControl(store: store)
        if allowsOpenCatalog {
          Button("Open…", systemImage: "folder") { store.openPanelAndLoad() }
            .kitHelp("Open…", meta: "Open a String Catalog", systemImage: "folder")
        }
        Button("Scan Strings", systemImage: "text.magnifyingglass") {
          store.startScan()
        }
        .disabled(!store.canScan)
        .kitHelp("Scan Strings", meta: "Scan the project's Swift packages and Xcode targets for localizable strings, then merge the new keys into this catalog (existing translations are never touched)", systemImage: "text.magnifyingglass")
        Button("Save", systemImage: "square.and.arrow.down") {
          Task { await store.save() }
        }
        .keyboardShortcut("s")
        .disabled(!store.canSave)
        .kitHelp("Save", shortcut: "⌘S", meta: store.canSave
          ? "Write the edited catalog to \(store.unsavedCatalogName) — nothing saves on its own"
          : "No unsaved changes", systemImage: "square.and.arrow.down")
      }
    }
    KitToolbarItem(placement: .primaryAction) {
      ToolGroup(iconOnly: true) {
        Button("Reload", systemImage: "arrow.clockwise") {
          Task { await store.reload() }
        }
        .disabled(!store.isLoaded)
        .kitHelp("Reload", meta: "Read the catalog file again", systemImage: "arrow.clockwise")
        Button("Non-translatable Keys", systemImage: "eye") {
          withKitAnimation { store.includeNonTranslatable.toggle() }
        }
        .kitToolOn(store.includeNonTranslatable)
        .accessibilityAddTraits(store.includeNonTranslatable ? .isSelected : [])
        .kitHelp("Non-translatable Keys", meta: "Include the \(store.nonTranslatableCount) keys marked shouldTranslate = false (hidden by default)", systemImage: "eye")
        Button("Comments", systemImage: "text.bubble") {
          withKitAnimation { store.setShowComments(!store.showComments) }
        }
        .kitToolOn(store.showComments)
        .accessibilityAddTraits(store.showComments ? .isSelected : [])
        .kitHelp("Comments", meta: "Show comment text under each source value", systemImage: "text.bubble")
        Button("Longest", systemImage: "ruler") {
          withKitAnimation { store.setShowLongest(!store.showLongest) }
        }
        .kitToolOn(store.showLongest)
        .accessibilityAddTraits(store.showLongest ? .isSelected : [])
        .kitHelp("Longest", meta: "Show the Longest column (longest value across all languages)", systemImage: "ruler")
        Button("Context Rules", systemImage: "text.book.closed") {
          store.openContextDocs()
        }
        .disabled(!store.isLoaded)
        .kitHelp("Context Rules", meta: "Edit the project context rules the translator follows — one rule per line, and deleting a line retracts it", systemImage: "text.book.closed")
      }
    }
  }
}
