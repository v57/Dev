//
//  ScanExtractor.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import Foundation

/// Which half of the tree a module came from.
nonisolated enum ScanOrigin: String, Sendable {
  case packageTarget
  case projectTarget
}

/// One compilation unit of the scan: a set of Swift sources compiled once
/// with `-emit-localized-strings`.
nonisolated struct ScanCompileUnit {
  var owner: String
  var module: String
  var origin: ScanOrigin
  /// Reported directory (target path or the project's target roots).
  var directory: String
  var files: [URL]
  var workingDirectory: URL
  var includeDirs: [String]
  var moduleMapFiles: [String]
}

/// Result of extracting localizable keys from one module's sources.
nonisolated struct ScanModuleOutcome: Identifiable, Sendable {
  var owner: String
  var module: String
  var origin: ScanOrigin
  var directory: String
  var fileCount: Int
  var keys: [String: Set<String>] = [:]
  var skippedTableKeys: Int = 0
  /// Source files dropped from the compile because they failed to typecheck
  /// (their keys are lost; every other file still contributed).
  var skippedFiles: [String] = []
  var failed: Bool = false
  var detail: String = ""

  var id: String { "\(owner) · \(module)" }
  var keyCount: Int { keys.count }
}

/// Runs the toolchain's localizable-key extraction over one module's sources
/// and parses the emitted `.stringsdata` fragments.
nonisolated enum ScanExtractor {
  /// Artifact/foreign directories never searched for module products.
  private static let moduleSkipComponents = [
    "checkouts", "SwiftExplicitPrecompiledModules",
    "Debug-iphonesimulator", "Release-iphonesimulator",
    "Debug-maccatalyst", "Release-maccatalyst",
  ]

  static let maxConcurrentCompiles = 4

  // MARK: - per-module extraction

  /// Extracts one module's keys. The compiler writes one `.stringsdata` per
  /// source file as it processes them, so a file that fails typechecking
  /// suppresses the output of every file AFTER it in the batch (verified: an
  /// error in the first file leaves the output directory empty; the same
  /// file last still yields every other file's keys). Extraction is
  /// therefore two passes plus a bounded salvage loop:
  ///
  ///  1. compile in sorted order — collects everything before the first
  ///     blocker, then retries with the blamed files removed;
  ///  2. compile in REVERSE order — collects everything after the first
  ///     blocker, which the forward pass could never reach;
  ///  3. union everything. The extra cost is paid only by modules that fail.
  static func compile(
    _ unit: ScanCompileUnit,
    workDirectory: URL,
    cancellation: ScanCancellation
  ) -> ScanModuleOutcome {
    var module = ScanModuleOutcome(
      owner: unit.owner, module: unit.module, origin: unit.origin,
      directory: unit.directory, fileCount: unit.files.count)

    guard !unit.files.isEmpty else { return module }
    if cancellation.isCancelled {
      module.failed = true
      module.detail = "cancelled"
      return module
    }

    // Per-module scratch: emitted module + .stringsdata output directory.
    let moduleOut = workDirectory.appendingPathComponent("\(unit.module).swiftmodule")
    let stringsOut = workDirectory.appendingPathComponent("out-\(unit.module)")
    try? FileManager.default.createDirectory(at: stringsOut, withIntermediateDirectories: true)

    var keys: [String: Set<String>] = [:]
    var skippedTableKeys = 0
    var excluded: [String] = []
    var failureDetail = ""
    var failed = true

    for files in [unit.files, unit.files.reversed()] {
      var remaining = files
      var rounds = 0
      while !remaining.isEmpty {
        let attempt = compileOnce(
          unit: unit, files: remaining,
          moduleOut: moduleOut, stringsOut: stringsOut,
          workDirectory: workDirectory, cancellation: cancellation)

        let parsed = ScanStringsData.parse(directory: stringsOut)
        for (key, comments) in parsed.keys {
          keys[key, default: []].formUnion(comments)
        }
        skippedTableKeys = max(skippedTableKeys, parsed.skippedTableKeys)

        if attempt.succeeded {
          failed = false
          break
        }
        failureDetail = attempt.detail
        if cancellation.isCancelled {
          failureDetail = "cancelled"
          break
        }

        // Drop the files the compiler blamed and retry with the rest — their
        // keys are lost, but every other file can still contribute.
        let blamed = ScanExtractor.blamedSourceFiles(in: attempt.output)
        let newlyBlamed = blamed.filter { path in
          !excluded.contains(path) && remaining.contains { $0.path == path }
        }
        rounds += 1
        guard !newlyBlamed.isEmpty, rounds <= maxSalvageRounds else { break }
        excluded.append(contentsOf: newlyBlamed)
        remaining = files.filter { !excluded.contains($0.path) }
      }
      if !failed || cancellation.isCancelled { break }
    }

    module.keys = keys
    module.skippedTableKeys = skippedTableKeys
    module.skippedFiles = excluded.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
    module.failed = failed
    if failed {
      module.detail = keys.isEmpty
        ? failureDetail
        : "partial (\(keys.count) keys) — \(failureDetail)"
    }
    return module
  }

  /// Extra whole-module compiles allowed per pass after dropping blamed files.
  private static let maxSalvageRounds = 2

  private struct AttemptOutcome {
    var succeeded: Bool
    var detail: String
    /// stderr + stdout of the decisive attempt, for blame extraction.
    var output: String
  }

  /// One compile of `files` with the argument ladder: `-parse-as-library`
  /// first, then main-file semantics (executables), then the
  /// `Bundle.module` shim (SwiftPM synthesizes that accessor; a standalone
  /// swiftc does not).
  private static func compileOnce(
    unit: ScanCompileUnit,
    files: [URL],
    moduleOut: URL,
    stringsOut: URL,
    workDirectory: URL,
    cancellation: ScanCancellation
  ) -> AttemptOutcome {
    var args = [
      "-emit-module", "-emit-module-path", moduleOut.path,
      "-parse-as-library",
      "-module-name", unit.module,
    ]
    args += files.map { $0.path }
    args += [
      "-emit-localized-strings",
      "-emit-localized-strings-path", stringsOut.path,
    ]
    for dir in unit.includeDirs {
      args += ["-I", dir]
    }
    for mapFile in unit.moduleMapFiles {
      args += ["-Xcc", "-fmodule-map-file=\(mapFile)"]
    }

    let first = ScanShell.swiftc(args, currentDirectory: unit.workingDirectory, timeout: 900)
    if first.succeeded {
      return AttemptOutcome(succeeded: true, detail: "", output: first.stdout + first.stderr)
    }
    if cancellation.isCancelled {
      return AttemptOutcome(succeeded: false, detail: "cancelled", output: "")
    }

    let retry = ScanShell.swiftc(
      args.filter { $0 != "-parse-as-library" },
      currentDirectory: unit.workingDirectory, timeout: 900)
    if retry.succeeded {
      return AttemptOutcome(succeeded: true, detail: "", output: retry.stdout + retry.stderr)
    }

    let combined = retry.stderr + "\n" + retry.stdout
    if combined.contains("no member 'module'"), combined.contains("Bundle") {
      let shim = bundleModuleShim(in: workDirectory)
      let shimRun = ScanShell.swiftc(
        args + [shim.path], currentDirectory: unit.workingDirectory, timeout: 900)
      if shimRun.succeeded {
        return AttemptOutcome(succeeded: true, detail: "", output: shimRun.stdout + shimRun.stderr)
      }
      return AttemptOutcome(
        succeeded: false,
        detail: shimRun.firstErrorLine,
        output: shimRun.stderr + "\n" + shimRun.stdout)
    }
    return AttemptOutcome(
      succeeded: false, detail: retry.firstErrorLine, output: combined)
  }

  /// The `.swift` paths the compiler blamed with a source-level error —
  /// `<path>:<line>:<col>: error: …`.
  static func blamedSourceFiles(in output: String) -> [String] {
    guard let regex = try? NSRegularExpression(
      pattern: "(?m)^(\\S+\\.swift):\\d+:\\d+: error:")
    else { return [] }
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    var paths: [String] = []
    for match in regex.matches(in: output, range: range) {
      guard let pathRange = Range(match.range(at: 1), in: output) else { continue }
      let path = String(output[pathRange])
      if !paths.contains(path) { paths.append(path) }
    }
    return paths
  }

  // MARK: - Package build + module search paths

  /// Refreshes a package's build so sibling `.swiftmodule` products exist.
  /// A failure is a warning: extraction continues with whatever products the
  /// package already had.
  static func buildWarning(for packageRoot: URL) -> String {
    let result = ScanShell.swift(["build"], currentDirectory: packageRoot, timeout: 1800)
    if result.succeeded { return "" }
    return "swift build failed (\(result.status)); extraction used the existing module products.\n"
      + result.errorLines(limit: 3).joined(separator: "\n")
  }

  /// Search paths that let a module's sources import sibling modules during a
  /// standalone compile:
  /// - include dirs: unique parent directories of `*.swiftmodule` files under
  ///   the package's `.build` tree (foreign slices excluded);
  /// - module maps: every `<Module>.modulemap` SwiftPM generated for the
  ///   package's C/ObjC targets.
  static func moduleSearchPaths(packageRoot: URL) -> (includeDirs: [String], moduleMapFiles: [String]) {
    let buildRoot = packageRoot.appendingPathComponent(".build")
    let enumerator = FileManager.default.enumerator(
      at: buildRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    var parents: Set<String> = []
    var moduleMaps: [String: String] = [:]
    while let url = enumerator?.nextObject() as? URL {
      let components = url.path.split(separator: "/").map(String.init)
      if components.contains(where: moduleSkipComponents.contains) {
        continue
      }
      switch url.pathExtension {
      case "swiftmodule":
        parents.insert(url.deletingLastPathComponent().path)
      case "modulemap":
        if components.contains("GeneratedModuleMaps") {
          let moduleName = url.deletingPathExtension().lastPathComponent
          if moduleMaps[moduleName] == nil {
            moduleMaps[moduleName] = url.path
          }
        }
      default:
        break
      }
    }
    return (parents.sorted(), moduleMaps.values.sorted())
  }

  // MARK: - source discovery

  /// The .swift sources belonging to a package target: either the manifest's
  /// explicit `sources` list or a recursive walk of the target directory,
  /// honoring `exclude` and `resources`.
  static func targetSourceFiles(for target: ScanTargetManifest, packageRoot: URL) -> [URL] {
    let targetDir: URL
    if let path = target.path, !path.isEmpty {
      targetDir = packageRoot.appendingPathComponent(path).standardizedFileURL
    } else {
      targetDir = packageRoot.appendingPathComponent("Sources/\(target.name)").standardizedFileURL
    }

    var excluded: [String] = []
    for entry in (target.exclude ?? []) {
      excluded.append(targetDir.appendingPathComponent(entry).standardizedFileURL.path)
    }
    for resource in (target.resources ?? []) {
      excluded.append(targetDir.appendingPathComponent(resource.path).standardizedFileURL.path)
    }

    var files: [URL] = []
    if let sources = target.sources, !sources.isEmpty {
      for source in sources {
        let candidate = targetDir.appendingPathComponent(source).standardizedFileURL
        let url = FileManager.default.fileExists(atPath: candidate.path)
          ? candidate
          : packageRoot.appendingPathComponent(source).standardizedFileURL
        if url.pathExtension == "swift" {
          files.append(url)
        }
      }
    } else {
      files = swiftFiles(in: targetDir, excluding: excluded)
    }
    return files
  }

  /// Every `.swift` file under `directory` (recursively), skipping hidden
  /// files, symlinked directories and excluded paths.
  static func swiftFiles(in directory: URL, excluding excluded: [String] = []) -> [URL] {
    var files: [URL] = []
    var stack: [URL] = [directory]
    while let dir = stack.popLast() {
      guard let contents = try? FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      ) else {
        continue
      }
      for item in contents {
        let path = item.standardizedFileURL.path
        if excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
        let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory {
          if scanArtifactNames.contains(item.lastPathComponent) { continue }
          let isLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
          if !isLink {
            stack.append(item)
          }
        } else if item.pathExtension == "swift" {
          files.append(item)
        }
      }
    }
    return files.sorted { $0.path < $1.path }
  }

  /// Build/VCS directories never walked while collecting sources.
  private static let scanArtifactNames: Set<String> = [
    ".build", ".git", ".svn", ".hg", ".swiftpm", "Packages",
    "DerivedData", "build", "checkouts", "xcuserdata",
  ]

  /// Writes (once per run) a typecheck-only stand-in for the `Bundle.module`
  /// accessor SwiftPM synthesizes for resource-bearing targets. The file
  /// lives in the run's own work directory, so the content is idempotent and
  /// no cross-run state is needed.
  private static func bundleModuleShim(in workDirectory: URL) -> URL {
    let url = workDirectory.appendingPathComponent("BundleModuleShim.swift")
    if !FileManager.default.fileExists(atPath: url.path) {
      let source = """
      import Foundation
      extension Bundle {
        static var module: Bundle { Bundle.main }
      }
      """
      try? source.write(to: url, atomically: true, encoding: .utf8)
    }
    return url
  }
}
