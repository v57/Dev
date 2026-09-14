//
//  Project.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import AppKit
import Foundation
import SwiftData

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
@Model final class Project {
  /// Display name of the project (e.g. the repo name).
  var name: String
  /// File URL of the project's merged .xcstrings catalog.
  var catalogURL: URL
  /// Root directory of a directory-dropped project; nil for rows first seen
  /// via their catalog file. Additive + optional so pre-drag rows load via
  /// lightweight SwiftData migration.
  var rootURL: URL?
  /// Resolved AppIcon.appiconset directory (<root>/Assets.xcassets/
  /// AppIcon.appiconset) of a directory-root project. The directory may not
  /// exist on disk yet — presence is checked when the thumbnail is needed.
  /// nil for catalog-file rows.
  var iconURL: URL?
  /// When the project was first seen.
  var createdAt: Date

  // MARK: - relationships

  /// The project-scope context document (scope == .project); nil until the
  /// pipeline first learns from this project's confirmed edits.
  @Relationship(deleteRule: .cascade, inverse: \ContextDoc.project)
  var contextDoc: ContextDoc?

  /// Every translation record reconciled from this project's catalog.
  ///
  /// OPTIONAL (`[TranslationRecord]?`) on purpose — the relationship's shape is
  /// load-bearing for the store clear, and a non-optional array here is what
  /// makes the clear cost minutes-to-hours instead of a second (Design notes 7.5,
  /// measured). SwiftData derives the
  /// CHILD's to-one `project` from this array's optionality: a non-optional
  /// inverse generates `TranslationRecord/project` as a MANDATORY to-one, and
  /// CoreData then REFUSES the store-level form of a delete —
  /// `context.delete(model: TranslationRecord.self)` throws "Constraint trigger
  /// violation: Batch delete failed due to mandatory OTO nullify inverse on
  /// TranslationRecord/project" and deletes nothing — leaving the object form,
  /// which pays SwiftData's inverse maintenance for every row (N^2 on a table this
  /// size). Optional, the batch delete is legal and the clear is a store-level
  /// DELETE. Read it as `project.records ?? []`; empty and nil are the same state.
  @Relationship(deleteRule: .cascade, inverse: \TranslationRecord.project)
  var records: [TranslationRecord]? = []

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
    name: String, catalogURL: URL, createdAt: Date = .now,
    rootURL: URL? = nil, iconURL: URL? = nil,
    contextDoc: ContextDoc? = nil, records: [TranslationRecord] = []
  ) {
    self.name = name
    self.catalogURL = catalogURL
    self.rootURL = rootURL
    self.iconURL = iconURL
    self.createdAt = createdAt
    self.contextDoc = contextDoc
    self.records = records
  }
}
