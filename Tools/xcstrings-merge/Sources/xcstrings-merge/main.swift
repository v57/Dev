import Foundation
import Darwin

// xcstrings-merge — scan a repo tree for Swift packages, extract localizable
// keys with the Swift toolchain (-emit-localized-strings), and merge them
// into a single .xcstrings String Catalog, preserving existing translations.
//
// Usage:
//   xcstrings-merge [--root <repo>] [--output <catalog.xcstrings>]
//
//   --root    Repo to scan (default: current directory). Every Swift package
//             under it (dirs containing Package.swift, nested sub-packages
//             included) is processed.
//   --output  Catalog to merge into (default: <root>/Localizable.xcstrings).
//             Existing entries are preserved; missing keys are added with an
//             empty localization and state "new". The file is only written
//             when new keys were found.

struct Options {
  var root: URL
  var output: URL
}

func usage() {
  print("""
  Usage: xcstrings-merge [--root <repo>] [--output <catalog.xcstrings>]
    --root    Repo tree to scan for Swift packages (default: current dir)
    --output  .xcstrings catalog to merge into (default: <root>/Localizable.xcstrings)
    -h, --help  Show this help
  """)
}

func parseArguments(_ arguments: [String]) -> Options? {
  var rootPath = FileManager.default.currentDirectoryPath
  var outputPath: String?
  var args = arguments
  while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "--root":
      guard !args.isEmpty else { return nil }
      rootPath = args.removeFirst()
    case "--output":
      guard !args.isEmpty else { return nil }
      outputPath = args.removeFirst()
    case "-h", "--help":
      usage()
      return nil
    default:
      fputs("error: unknown argument '\(flag)'\n", stderr)
      usage()
      return nil
    }
  }
  let root = URL(fileURLWithPath: rootPath).standardizedFileURL
  let output = outputPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
    ?? root.appendingPathComponent("Localizable.xcstrings")
  return Options(root: root, output: output)
}

func warn(_ message: String) {
  fputs("warning: \(message)\n", stderr)
}

// MARK: - Orchestration

let options = parseArguments(Array(CommandLine.arguments.dropFirst()))
guard let options else { exit(2) }

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: options.root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
else {
  fputs("error: --root '\(options.root.path)' is not a directory\n", stderr)
  exit(1)
}

let workDirectory = FileManager.default.temporaryDirectory
  .appendingPathComponent("xcstrings-merge-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }

print("Scanning for Swift packages under \(options.root.path) ...")
let packages = PackageFinder.findPackageRoots(under: options.root)
if packages.isEmpty {
  print("  (no directories containing Package.swift found)")
} else {
  for package in packages {
    print("  \(package.path)")
  }
}

// Merge base: existing catalog content is loaded lazily by CatalogMerger.

var allKeys: [String: Set<String>] = [:]
var grandTotal = 0

for packageRoot in packages {
  print()
  let result = Extractor.processPackage(packageRoot, workDirectory: workDirectory)
  print("Package: \(result.packageRoot.path)")
  print("  name: \(result.packageName)")

  if !result.buildWarning.isEmpty {
    warn("\(result.packageName): \(result.buildWarning.replacingOccurrences(of: "\n", with: "\n  "))")
  }

  if result.modules.isEmpty {
    print("  (no Swift targets with sources)")
  }
  for module in result.modules {
    var suffix = ""
    if module.skippedTableKeys > 0 {
      suffix += " (+\(module.skippedTableKeys) keys in non-Localizable tables, skipped)"
    }
    if module.failed {
      warn("\(result.packageName)/\(module.moduleName): extraction failed — \(module.detail)")
    }
    print("  \(module.moduleName): \(module.keys.count) unique keys from \(module.swiftFileCount) files\(suffix)")
  }

  print("  package total: \(result.totalKeyCount) unique keys")
  grandTotal += result.totalKeyCount
  for (key, comments) in result.uniqueKeys {
    allKeys[key, default: []].formUnion(comments)
  }
}

print()
print("Total extracted keys across packages: \(allKeys.count) unique (grand total over per-package unions: \(grandTotal))")
print()

// MARK: - Merge

do {
  let outcome = try CatalogMerger.merge(extractedKeys: allKeys, into: options.output)
  if outcome.wroteFile {
    print("Merged catalog written: \(options.output.path)")
    print("  existing entries preserved: \(outcome.existingEntryCount)")
    print("  entries added (empty localization, state \"new\"): \(outcome.addedCount)")
    print("  total entries: \(outcome.totalEntryCount)")
  } else {
    print("Catalog up to date: \(options.output.path)")
    print("  existing entries: \(outcome.existingEntryCount) — no new keys to add, file left untouched")
  }
} catch {
  fputs("error: merge failed: \(error)\n", stderr)
  exit(1)
}
