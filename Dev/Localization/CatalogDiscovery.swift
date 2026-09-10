//
//  CatalogDiscovery.swift
//  Dev
//

import Foundation

// MARK: - CatalogDiscovery

/// Recursive `.xcstrings` discovery for a dropped directory.
///
/// The directory-drop resolver used to assume the catalog was exactly
/// `<root>/Localizable.xcstrings`. That is true of this repo — the merged
/// catalog is written to the repo root — but not of the general case: an
/// Xcode app target normally keeps its catalog beside its sources, often
/// several levels down, so dropping such a project reported "no catalog"
/// while a perfectly good one sat in the tree.
///
/// `nonisolated` on purpose: this target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and this walk must be able to
/// run OFF the main actor — a drop can point at an arbitrarily large tree.
nonisolated enum CatalogDiscovery {
  /// The canonical merged-catalog name, and the first candidate tried, so a
  /// repo that already satisfied the old assumption resolves identically.
  static let canonicalName = "Localizable.xcstrings"

  /// The catalog a dropped directory should open, or nil when the tree holds
  /// none. The caller keeps the canonical path as a placeholder in that case:
  /// a directory project is allowed to have no catalog yet ('no catalog' is a
  /// display-time derivation, and one may be written there later).
  ///
  /// Precedence, so the pick is deterministic rather than dependent on
  /// directory-enumeration order:
  ///  1. `<root>/Localizable.xcstrings` — the canonical merged catalog.
  ///  2. fewest directories deep, so an app target's own catalog beats a copy
  ///     buried in a nested package or build product.
  ///  3. lexicographically first.
  static func catalog(inRoot root: URL) -> URL? {
    let root = root.standardizedFileURL
    let canonical = root.appendingPathComponent(canonicalName)
    if FileManager.default.fileExists(atPath: canonical.path) {
      return canonical
    }
    return candidates(inRoot: root).first
  }

  /// Every `.xcstrings` catalog in the tree, in the precedence order above.
  ///
  /// Directories whose name begins with `.` are never descended into, which
  /// covers VCS and tooling state (`.git`, `.build`, `.swiftpm`) in one rule.
  /// Package descendants (`.xcodeproj`, `.app`, `.framework`) are skipped as
  /// well, so bundled build output cannot masquerade as the project's own
  /// catalog.
  ///
  /// NOT excluded: build output that happens to be unhidden (`DerivedData/`,
  /// `build/`). A stale copy inside one of those loses to any shallower real
  /// catalog, but it can still win when it is the only catalog in the tree.
  static func candidates(inRoot root: URL) -> [URL] {
    let root = root.standardizedFileURL
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    guard let walker = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }

    var found: [(url: URL, depth: Int)] = []
    for case let url as URL in walker {
      guard url.pathExtension.lowercased() == "xcstrings" else { continue }
      // Regular files only: a directory or a symlink named *.xcstrings is not
      // a catalog, and following one could leave the dropped tree entirely.
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
            values.isRegularFile == true,
            values.isSymbolicLink != true
      else { continue }
      found.append((url.standardizedFileURL, depth(of: url, under: root)))
    }
    return found
      .sorted {
        $0.depth == $1.depth ? $0.url.path < $1.url.path : $0.depth < $1.depth
      }
      .map(\.url)
  }

  /// Directory levels between `root` and `url` (a direct child file is 1).
  private static func depth(of url: URL, under root: URL) -> Int {
    max(0, url.standardizedFileURL.pathComponents.count
      - root.standardizedFileURL.pathComponents.count)
  }
}
