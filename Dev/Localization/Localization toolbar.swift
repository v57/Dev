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
          Button("Non-translatable Keys", systemImage: "eye") {
            withKitAnimation { store.includeNonTranslatable.toggle() }
          }
          .kitToolOn(store.includeNonTranslatable)
          .accessibilityAddTraits(store.includeNonTranslatable ? .isSelected : [])
          .help("Include the \(store.nonTranslatableCount) keys marked shouldTranslate = false (hidden by default)")
          Button("Comments", systemImage: "text.bubble") {
            withKitAnimation { store.setShowComments(!store.showComments) }
          }
          .kitToolOn(store.showComments)
          .accessibilityAddTraits(store.showComments ? .isSelected : [])
          .help("Show comment text under each source value")
          Button("Longest", systemImage: "ruler") {
            withKitAnimation { store.setShowLongest(!store.showLongest) }
          }
          .kitToolOn(store.showLongest)
          .accessibilityAddTraits(store.showLongest ? .isSelected : [])
          .help("Show the Longest column (longest value across all languages)")
          Button("Context Rules", systemImage: "text.book.closed") {
            store.openContextDocs()
          }
          .disabled(!store.isLoaded)
          .help("Edit the project context rules the translator follows — one rule per line, and deleting a line retracts it")
        }
      }
    }
  }
}
