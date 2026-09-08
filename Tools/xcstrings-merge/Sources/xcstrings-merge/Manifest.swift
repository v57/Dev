import Foundation

/// Top-level shape of `swift package dump-package` output. Unknown JSON
/// keys are ignored by Codable, so future manifest fields do not break us.
struct PackageManifest: Decodable {
  var name: String?
  var targets: [TargetManifest]?
}

/// A single target entry from dump-package.
struct TargetManifest: Decodable {
  var name: String
  var moduleName: String?
  var type: String?
  /// Target source directory, relative to the package root, when the
  /// manifest sets an explicit `path`.
  var path: String?
  /// Explicit source file list (relative to the target path) when the
  /// manifest sets `sources`; otherwise sources are discovered by walking
  /// the target directory.
  var sources: [String]?
  var exclude: [String]?
  var resources: [TargetResourceManifest]?

  var effectiveModuleName: String {
    // SwiftPM derives the module name from the target name, converting
    // hyphens to underscores ("foo-bar" compiles as module "foo_bar").
    (moduleName ?? name).replacingOccurrences(of: "-", with: "_")
  }

  /// Target types that never carry localizable product strings.
  var isSkippable: Bool {
    switch type {
    case "test", "plugin", "macro", "system": return true
    default: return false
    }
  }
}

struct TargetResourceManifest: Decodable {
  var path: String
}

enum PackageDumpError: Error {
  case dumpFailed(String)
  case decodeFailed(String)
}

/// Loads and decodes `swift package dump-package` for one package root.
enum PackageDumper {
  static func dump(packageRoot: URL) throws -> PackageManifest {
    let result = Shell.swift(
      ["package", "dump-package"],
      currentDirectory: packageRoot,
      timeout: 300
    )
    guard result.succeeded else {
      let detail = result.stderr.split(separator: "\n").prefix(3).joined(separator: "\n")
      throw PackageDumpError.dumpFailed(detail.isEmpty ? result.stdout : detail)
    }
    guard let data = result.stdout.data(using: .utf8) else {
      throw PackageDumpError.decodeFailed("dump-package output was not UTF-8")
    }
    do {
      return try JSONDecoder().decode(PackageManifest.self, from: data)
    } catch {
      throw PackageDumpError.decodeFailed("\(error)")
    }
  }
}
