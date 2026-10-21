//
//  Project.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import AppKit
import Foundation

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

  /// The project's app-icon bitmap: the best PNG inside `iconURL` when the
  /// icon set exists on disk, else a folder placeholder symbol (catalog-file
  /// projects and directory projects without Assets.xcassets yet). nil only
  /// if even the symbol cannot be resolved.
  var iconThumbnail: NSImage? {
    if let image = Self.bestIconImage(in: iconURL) { return image }
    return NSImage(systemSymbolName: "folder", accessibilityDescription: name)
  }

  /// Loads the largest-representative PNG of an AppIcon.appiconset: this
  /// app's exporter always writes a canonical 1024.png; Xcode-authored sets
  /// use Contents.json + arbitrary filenames, so fall back to the biggest
  /// PNG by file size.
  private static func bestIconImage(in setURL: URL?) -> NSImage? {
    guard let setURL else { return nil }
    let fm = FileManager.default
    guard fm.fileExists(atPath: setURL.path),
          let names = try? fm.contentsOfDirectory(atPath: setURL.path)
    else { return nil }
    for name in ["1024.png", "512.png", "256.png", "128.png"] where names.contains(name) {
      if let image = NSImage(contentsOf: setURL.appendingPathComponent(name)) {
        return image
      }
    }
    let pngs = names.filter { $0.lowercased().hasSuffix(".png") }
    let largest = pngs
      .map { name -> (String, Int) in
        let size = (try? fm.attributesOfItem(
          atPath: setURL.appendingPathComponent(name).path))?[.size] as? Int ?? 0
        return (name, size)
      }
      .max { $0.1 < $1.1 }
    guard let largest, largest.1 > 0,
          let image = NSImage(contentsOf: setURL.appendingPathComponent(largest.0))
    else { return nil }
    return image
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
