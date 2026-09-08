import Foundation

/// Directory names that are SwiftPM/Xcode artifacts or VCS internals —
/// never treated as package roots, never descended into.
private let skippedDirectoryNames: Set<String> = [
  ".build", ".git", ".svn", ".hg", ".swiftpm",
  "Packages", "DerivedData", "build", "checkouts", "xcuserdata",
]

/// Finds every Swift package root under a repo tree.
enum PackageFinder {
  /// Recursively locates every directory under `root` that contains a
  /// Package.swift — the main project package plus any nested local
  /// sub-packages. Artifact directories (`.build`, `Packages`, ...) and
  /// symlinked directories are skipped. Returns paths sorted for
  /// deterministic output.
  static func findPackageRoots(under root: URL) -> [URL] {
    var results: [URL] = []
    var stack: [URL] = [root.standardizedFileURL]

    while let directory = stack.popLast() {
      let contents = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )) ?? []

      var isPackageRoot = false
      for item in contents {
        let name = item.lastPathComponent
        let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory {
          let isLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
          if !isLink, !skippedDirectoryNames.contains(name) {
            stack.append(item)
          }
        } else if name == "Package.swift" {
          isPackageRoot = true
        }
      }
      if isPackageRoot {
        results.append(directory)
      }
    }
    return results.sorted { $0.path < $1.path }
  }
}
