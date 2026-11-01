//
//  Project.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import ComponentKit
import Foundation
import SwiftUI

/// A translation project: one merged .xcstrings catalog being translated.
/// A project owns its project-scope ContextDoc and the TranslationRecords
/// reconciled from its catalog.
///
/// Two creation paths share this one table:
///  - CATALOG-FILE projects (the original path): first seen when an
///    .xcstrings file opens; `catalogURL` is that file and `rootURL`/`iconURL`
///    stay nil.
///  - DIRECTORY-ROOT projects (sidebar drag-import): the dropped folder IS
///    the project. `catalogURL` is the catalog found by searching the tree
///    (see `CatalogDiscovery`) — `<root>/Localizable.xcstrings` when present,
///    else the shallowest `.xcstrings` found, else that same root path as a
///    placeholder whether or not the file exists yet ('no catalog' is derived
///    at display time). `iconURL` is <root>/Assets.xcassets/AppIcon.appiconset
///    when present.
nonisolated struct Project: Hashable, Sendable, Identifiable {
  /// The row id (assigned by `TranslationData` on insert; kept from the SwiftData store).
  var id: Int64
  /// Display name of the project (e.g. the repo name).
  var name: String
  /// File URL of the project's merged .xcstrings catalog.
  var catalogURL: URL
  /// Root directory of a directory-dropped project; nil for rows first seen
  /// via their catalog file.
  var rootURL: URL?
  /// Resolved AppIcon.appiconset directory (<root>/Assets.xcassets/
  /// AppIcon.appiconset) of a directory-root project. The directory may not
  /// exist on disk yet — presence is checked when the thumbnail is needed.
  /// nil for catalog-file rows.
  var iconURL: URL?
  /// When the project was first seen.
  var createdAt: Date

  // MARK: - display conveniences

  /// Name shown in the sidebar: the root folder's own name for a
  /// directory-root project, else the catalog's home directory (the
  /// pre-drag behavior — the merged catalog lives at the repo root).
  var displayName: String {
    if let rootURL { return rootURL.lastPathComponent }
    let home = catalogURL.deletingLastPathComponent().lastPathComponent
    return home.isEmpty ? name : home
  }

  /// The best PNG of an AppIcon.appiconset, for its thumbnail: this app's
  /// exporter always writes a canonical 1024.png; Xcode-authored sets use
  /// Contents.json + arbitrary filenames, so fall back to the biggest PNG by
  /// file size. Reads the disk: call it off the main actor.
  nonisolated static func bestIconFile(in setURL: URL?) -> URL? {
    guard let setURL else { return nil }
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: setURL.path) else { return nil }
    for name in ["1024.png", "512.png", "256.png", "128.png"] where names.contains(name) {
      return setURL.appendingPathComponent(name)
    }
    let largest = names
      .filter { $0.lowercased().hasSuffix(".png") }
      .map { name -> (String, Int) in
        let size = (try? fm.attributesOfItem(
          atPath: setURL.appendingPathComponent(name).path))?[.size] as? Int ?? 0
        return (name, size)
      }
      .max { $0.1 < $1.1 }
    guard let largest, largest.1 > 0 else { return nil }
    return setURL.appendingPathComponent(largest.0)
  }

  init(
    id: Int64, name: String, catalogURL: URL, createdAt: Date = .now,
    rootURL: URL? = nil, iconURL: URL? = nil
  ) {
    self.id = id
    self.name = name
    self.catalogURL = catalogURL
    self.rootURL = rootURL
    self.iconURL = iconURL
    self.createdAt = createdAt
  }
}
