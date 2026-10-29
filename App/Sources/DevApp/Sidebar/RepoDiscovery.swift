//
//  RepoDiscovery.swift
//  Dev
//

import Foundation

// MARK: - RepoDiscovery

/// Which projects a dropped directory holds: every git repository in it.
///
/// A folder of repos (`~/Developer`) used to become ONE project rooted at the
/// folder. Now the tree is searched for directories with a `.git` entry, and
/// each one is a project. The walk stops at a repo — what is inside a repo
/// belongs to that repo, nested packages and submodules included — and a tree
/// with no repo at all is still one project, the dropped directory itself.
///
/// The directories the walk passed over are reported too: a non-repo directory
/// beside a repo (a scratch folder of demos next to the real projects) is not
/// added on its own, so the sidebar offers it instead of dropping it silently.
///
/// `nonisolated`, like `CatalogDiscovery`: a drop can point at a huge tree, so
/// the walk runs off the main actor.
nonisolated enum RepoDiscovery {
  struct Result: Sendable, Equatable {
    /// The projects to add, in path order.
    var repos: [URL]
    /// Directories that hold no repo but sit beside one, in path order.
    var skipped: [Skipped]
  }

  /// A directory the walk did not add.
  struct Skipped: Sendable, Hashable, Identifiable {
    let url: URL
    /// It has the marks of a project (a manifest, an Xcode project, a catalog)
    /// even without git, so the suggestion pre-selects it.
    let looksLikeProject: Bool

    var id: URL { url }
  }

  /// How deep the walk goes below the dropped directory. Repos sit a level or
  /// two down in practice; the cap keeps a drop of `~` from walking the disk.
  static let maxDepth = 6

  /// Directory names never descended into or offered: build output and
  /// dependency caches, which hold no repos of the user's and can be huge.
  static let ignoredNames: Set<String> = [
    "node_modules", "DerivedData", "build", "Build", "Pods", "Carthage",
    "vendor", "target", "dist", "__pycache__", "venv",
  ]

  static func scan(_ root: URL) -> Result {
    let root = root.standardizedFileURL
    if isRepo(root) { return Result(repos: [root], skipped: []) }
    var repos: [URL] = []
    var skipped: [Skipped] = []
    _ = walk(root, depth: 0, repos: &repos, skipped: &skipped)
    if repos.isEmpty { return Result(repos: [root], skipped: []) }
    return Result(
      repos: repos.sorted { $0.path < $1.path },
      skipped: skipped.sorted { $0.url.path < $1.url.path })
  }

  /// Walks `directory` (not itself a repo) and answers whether a repo is
  /// somewhere below it. Children without one are reported as skipped only when
  /// a sibling has one: a subtree with no repos at all is the parent's to
  /// report, as a single entry rather than every folder inside it.
  private static func walk(
    _ directory: URL, depth: Int, repos: inout [URL], skipped: inout [Skipped]
  ) -> Bool {
    guard depth < maxDepth else { return false }
    var withRepo = false
    var withoutRepo: [URL] = []
    var nestedSkipped: [Skipped] = []
    for child in childDirectories(of: directory) {
      if isRepo(child) {
        repos.append(child)
        withRepo = true
      } else if walk(child, depth: depth + 1, repos: &repos, skipped: &nestedSkipped) {
        withRepo = true
      } else {
        withoutRepo.append(child)
      }
    }
    skipped += nestedSkipped
    if withRepo {
      skipped += withoutRepo.map { Skipped(url: $0, looksLikeProject: looksLikeProject($0)) }
    }
    return withRepo
  }

  /// A `.git` directory, or a `.git` FILE: a worktree's and a submodule's
  /// checkout point at their repository through one.
  static func isRepo(_ directory: URL) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
  }

  /// Visible, real directories: no hidden ones, no symlinks (they can leave the
  /// tree or loop), no packages (`.app`, `.xcodeproj`), nothing in `ignoredNames`.
  private static func childDirectories(of directory: URL) -> [URL] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return [] }
    return children.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
            values.isDirectory == true,
            values.isSymbolicLink != true,
            values.isPackage != true,
            !ignoredNames.contains(url.lastPathComponent)
      else { return nil }
      return url.standardizedFileURL
    }
  }

  /// A manifest, an Xcode project or a String Catalog at the top level.
  private static func looksLikeProject(_ directory: URL) -> Bool {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    let manifests: Set<String> = [
      "Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml",
      "build.gradle", "build.gradle.kts", "CMakeLists.txt", "Makefile",
    ]
    return names.contains { name in
      manifests.contains(name)
        || name.hasSuffix(".xcodeproj")
        || name.hasSuffix(".xcworkspace")
        || name.hasSuffix(".xcstrings")
    }
  }
}
