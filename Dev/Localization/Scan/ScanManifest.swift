//
//  ScanManifest.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import Foundation

/// Top-level shape of `swift package dump-package` output. Unknown JSON
/// keys are ignored by Codable, so future manifest fields do not break us.
nonisolated struct ScanPackageManifest: Decodable {
  var name: String?
  var targets: [ScanTargetManifest]?
  /// The undecoded `dump-package` JSON — for the manifest fields this model
  /// does not carry (products, platforms). Set by the dumper, never decoded.
  var rawJSON: Data?

  private enum CodingKeys: String, CodingKey {
    case name
    case targets
  }
}

/// A single target entry from dump-package.
nonisolated struct ScanTargetManifest: Decodable {
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
  var resources: [ScanTargetResourceManifest]?

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

nonisolated struct ScanTargetResourceManifest: Decodable {
  var path: String
}

nonisolated enum ScanPackageDumpError: Error, LocalizedError {
  case dumpFailed(String)
  case decodeFailed(String)

  var errorDescription: String? {
    switch self {
    case .dumpFailed(let detail): return "dump-package failed: \(detail)"
    case .decodeFailed(let detail): return "dump-package output unreadable: \(detail)"
    }
  }
}

/// Loads and decodes `swift package dump-package` for one package root.
nonisolated enum ScanPackageDumper {
  static func dump(packageRoot: URL) throws -> ScanPackageManifest {
    let result = ScanShell.swift(
      ["package", "dump-package"],
      currentDirectory: packageRoot,
      timeout: 300
    )
    guard result.succeeded else {
      let detail = result.stderr
        .split(separator: "\n")
        .prefix(3)
        .joined(separator: "\n")
      throw ScanPackageDumpError.dumpFailed(detail.isEmpty ? result.stdout : detail)
    }
    guard let data = result.stdout.data(using: .utf8) else {
      throw ScanPackageDumpError.decodeFailed("output was not UTF-8")
    }
    do {
      var manifest = try JSONDecoder().decode(ScanPackageManifest.self, from: data)
      manifest.rawJSON = data
      return manifest
    } catch {
      throw ScanPackageDumpError.decodeFailed("\(error)")
    }
  }
}
