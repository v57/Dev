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
  /// Header search paths for the CLANG importer (`-Xcc -I`), which is a different channel from
  /// `includeDirs` (`-I`, Swift modules).
  ///
  /// A dependency's clang module is only usable if its HEADERS resolve: avif.swift's `avifc` map
  /// includes `AVIFDataDecoder.h`, which includes `avif/avif.h` — a header of that package's own
  /// `libavif` target, found only under its `include/` directory. With the map passed and the path
  /// missing the compile fails inside the header ("'avif/avif.h' file not found"), which takes the
  /// whole module with it (reader, 2026-09-15: "make the app target compile, it's the most important
  /// one" — a large app imports `avifnuke`, which re-exports `avifc`).
  var clangIncludeDirs: [String] = []
  /// The SDK/triple/conditions this unit is compiled with — the platform the
  /// tree's own build products belong to (see `ScanToolchain`).
  var toolchain: ScanToolchain = .host()
  /// Build settings of the unit's own project (`ScanSwiftSettings`), appended
  /// after the platform arguments.
  var settingsArguments: [String] = []
  /// The project's own package dependencies that this unit can see, one entry
  /// per package: the products it vends (importable module names) and every
  /// target module it builds, clang ones included.
  ///
  /// The salvage loop needs both halves: a dependency can be only PARTLY
  /// usable — SwiftPM's build of avif.swift exposes `avifnuke` and `avif` but
  /// not the clang module `avifc` they re-export — so the diagnostic names a
  /// module no source imports (`avifc`) while the files that must be dropped
  /// import its product (`avifnuke`). Matching the missing module against the
  /// dependency's TARGET list and then dropping that package's PRODUCT
  /// importers keeps the fallback narrow: a missing module of package A never
  /// costs you the files that import package B.
  var dependencies: [ScanDependencyModules] = []
}

/// Result of extracting localizable keys from one module's sources.
nonisolated struct ScanModuleOutcome: Identifiable, Sendable {
  var owner: String
  var module: String
  var origin: ScanOrigin
  var directory: String
  var fileCount: Int
  var keys: [String: Set<String>] = [:]
  /// Key -> the module's OWN source files that emitted it (resolved from the
  /// `.stringsdata` document's `source`). The comment pass reads a call site
  /// out of one of these; an empty entry means the format named a file this
  /// module does not carry (or named none at all).
  var keyFiles: [String: Set<String>] = [:]
  var skippedTableKeys: Int = 0
  /// Source files dropped from the compile because they failed to typecheck
  /// (their keys are lost; every other file still contributed).
  var skippedFiles: [String] = []
  var failed: Bool = false
  var detail: String = ""

  var id: String { "\(owner) · \(module)" }
  var keyCount: Int { keys.count }
}

/// One package dependency a compile unit can see (see
/// `ScanCompileUnit.dependencies`).
nonisolated struct ScanDependencyModules: Sendable {
  var identity: String
  var products: [String]
  var targets: [String]
}

/// Runs the toolchain's localizable-key extraction over one module's sources
/// and parses the emitted `.stringsdata` fragments.
nonisolated enum ScanExtractor {
  /// Artifact/foreign directories never searched for module products. The
  /// platform product directories are NOT in here: which one is usable is
  /// decided by `ScanToolchain`, not by name-matching.
  private static let moduleSkipComponents = [
    "checkouts", "SwiftExplicitPrecompiledModules",
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
    var keyFiles: [String: Set<String>] = [:]
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
        for (key, sources) in parsed.files {
          let paths = resolveSourceFiles(sources, in: unit.files)
          if !paths.isEmpty {
            keyFiles[key, default: []].formUnion(paths)
          }
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
        var blamed = ScanExtractor.blamedSourceFiles(in: attempt.output)
        if blamed.isEmpty, let module = ScanExtractor.unresolvableModule(in: attempt.output) {
          // A module-level failure names no source file ("missing required
          // module 'avifc'", because a package dependency's clang module is not
          // exposed by a `swift build` tree), so nothing would be dropped and
          // the whole module's keys would be lost. Drop the files that import
          // it instead: their keys are lost either way, and the rest compiles.
          blamed = ScanExtractor.filesImporting(module, in: remaining)
          if blamed.isEmpty {
            // The missing module is not imported by name — it belongs to a
            // dependency's own targets (avifc ← avif.swift), so drop the files
            // importing that package's products.
            for dependency in unit.dependencies
            where dependency.targets.contains(module) || dependency.targets.contains(where: {
              $0 == module || module.hasPrefix($0 + ".")
            }) {
              blamed += dependency.products.flatMap {
                ScanExtractor.filesImporting($0, in: remaining)
              }
            }
          }
        }
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
    module.keyFiles = keyFiles
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
  /// Four, not two: a module can have several independently broken files (the
  /// main target of a large app loses App.swift and the other `avifnuke` importers on
  /// top of its missing-dependency file), and each round drops everything the
  /// compiler named at once — so the cost is one compile per round only for
  /// modules that fail.
  private static let maxSalvageRounds = 4

  private struct AttemptOutcome {
    var succeeded: Bool
    var detail: String
    /// stderr + stdout of the decisive attempt, for blame extraction.
    var output: String
  }

  /// The real paths behind a `.stringsdata` document's `source` value(s),
  /// resolved against the module's OWN source list.
  ///
  /// The compiler records the file it read as a name (`Localization view.swift`)
  /// or, under an Xcode build, as a path (`Sources/App/View.swift`); a name is
  /// ambiguous on its own and a path is relative to a directory the scan does
  /// not know. The unit's `files` are the only files that could have produced
  /// the document, so they are the authority: a path source matches by path
  /// suffix, and anything that matches nothing contributes nothing (the key
  /// then has no file, and the comment pass reports it as skipped).
  static func resolveSourceFiles(_ sources: Set<String>, in files: [URL]) -> [String] {
    var byName: [String: [String]] = [:]
    for file in files {
      byName[file.lastPathComponent, default: []].append(file.path)
    }
    var resolved: Set<String> = []
    for source in sources {
      guard var candidates = byName[(source as NSString).lastPathComponent] else { continue }
      if source.contains("/") {
        let suffix = source.hasPrefix("/") ? source : "/" + source
        let exact = candidates.filter { $0.hasSuffix(suffix) }
        if !exact.isEmpty { candidates = exact }
      }
      resolved.formUnion(candidates)
    }
    return resolved.sorted()
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
    // The platform's SDK/triple/conditions come first: they select the module
    // slice every `-I` directory is read for.
    args += unit.toolchain.platformArguments
    args += unit.settingsArguments
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
    for dir in unit.clangIncludeDirs {
      // ONE `-Xcc` per clang argument: `-Xcc -I <dir>` hands the PATH back to swiftc as an input
      // file ("error: unexpected input file: …/include"), so the flag and its value travel joined.
      args += ["-Xcc", "-I\(dir)"]
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
    // `Bundle.module` is synthesized by SwiftPM for resource-bearing targets
    // (DerivedSources/resource_bundle_accessor.swift) and declared `internal`,
    // so a standalone swiftc sees either no member at all, or — worse — the
    // SAME declaration from a sibling module that was built with
    // `-enable-testing`, which reports `'module' is inaccessible due to
    // 'internal' protection level` and points at that other target's file
    // (both messages verified on a large app's video editor target). Either way the shim
    // declares the accessor for THIS module, which wins the lookup.
    if needsBundleModuleShim(combined) {
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

  /// The module a "can't find it" diagnostic names, or nil. Both spellings
  /// appear: `no such module 'X'` (absent) and `missing required module 'X'`
  /// (a dependency of a module that WAS found is missing).
  static func unresolvableModule(in output: String) -> String? {
    guard let regex = try? NSRegularExpression(
      pattern: "(?:no such module|missing required module|could not find module) '([A-Za-z_][A-Za-z0-9_.]*)'")
    else { return nil }
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    guard let match = regex.firstMatch(in: output, range: range),
          match.numberOfRanges > 1,
          let captured = Range(match.range(at: 1), in: output)
    else { return nil }
    return String(output[captured])
  }

  /// The files that import `module` (or a submodule of it).
  static func filesImporting(_ module: String, in files: [URL]) -> [String] {
    let root = module.split(separator: ".").first.map(String.init) ?? module
    var matching: [String] = []
    for file in files {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      for line in text.split(separator: "\n").prefix(80) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(root) || trimmed.contains("import \(root)"),
              trimmed.contains("import")
        else { continue }
        if trimmed.hasSuffix(root), trimmed.contains("import ") {
          matching.append(file.path)
          break
        }
      }
    }
    return matching
  }

  /// True when the compiler output blames `Bundle.module` — either the member
  /// is missing, or it resolved to another module's internal declaration.
  static func needsBundleModuleShim(_ output: String) -> Bool {
    guard output.contains("module") , output.contains("Bundle") || output.contains(".module") else {
      return false
    }
    return output.contains("no member 'module'")
      || output.contains("'module' is inaccessible")
      || output.contains("value of type 'Bundle' has no member 'module'")
  }

  /// The `.swift` paths the compiler blamed with a source-level error —
  /// `<path>:<line>:<col>: error: …`.
  ///
  /// The path itself may contain SPACES (a large app: `Chat camera.swift`,
  /// `Selected item.swift`, `Server manager.swift`), so the match takes
  /// everything up to the last `.swift:` before the position, and tolerates
  /// the indentation some diagnostics carry. A `\S+\.swift` pattern silently
  /// matches none of those files — verified: 1 of 6 real diagnostics — which
  /// disables the salvage loop for whole modules and loses every key in them
  /// (a large app's target: 171 files, 0 keys).
  static func blamedSourceFiles(in output: String) -> [String] {
    guard let regex = try? NSRegularExpression(
      pattern: "(?m)^[ \\t]*(.+?\\.swift):\\d+:\\d+: (?:fatal )?error:")
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

  /// Refreshes a package's build so sibling `.swiftmodule` products exist, for
  /// the platform the scan is going to type-check against. A failure is a
  /// warning: extraction continues with whatever products the package already
  /// had.
  ///
  /// The platform matters: building a UIKit/iOS package for the host either
  /// fails outright or refreshes the WRONG products, leaving the extraction to
  /// read stale modules (the source errors that follow — "requires that 'X'
  /// conform to 'Observable'", "cannot assign to property: 'y' is a 'let'
  /// constant" — are version skew, not source defects).
  static func buildWarning(for packageRoot: URL, toolchain: ScanToolchain) -> String {
    var arguments = ["build"]
    if let sdkPath = toolchain.sdkPath { arguments += ["--sdk", sdkPath] }
    if let triple = toolchain.targetTriple { arguments += ["--triple", triple] }
    let result = ScanShell.swift(arguments, currentDirectory: packageRoot, timeout: 1800)
    if result.succeeded { return "" }
    let platform = toolchain.platform == .iosSimulator ? "iOS Simulator" : "the host"
    return "swift build failed for \(platform) (\(result.status)); extraction used the "
      + "existing module products.\n"
      + result.errorLines(limit: 3).joined(separator: "\n")
  }

  /// Search paths that let a module's sources import sibling modules during a
  /// standalone compile:
  /// - include dirs: unique parent directories of `*.swiftmodule` files under
  ///   the package's `.build` tree, restricted to the platform's product
  ///   directories (a host slice in the search path is unusable for an iOS
  ///   compile and vice versa);
  /// - module maps: the clang-only modules of that platform (a target without
  ///   a `.swiftmodule` product — the C/ObjC ones, e.g. `SomeC`, and a binary
  ///   dependency's helper, e.g. `LKObjCHelpers`). Passing the Swift targets'
  ///   modulemaps too redefines modules the `.swiftmodule` already provides.
  static func moduleSearchPaths(
    packageRoot: URL, toolchain: ScanToolchain
  ) -> (includeDirs: [String], moduleMapFiles: [String]) {
    moduleSearchPaths(
      buildRoot: packageRoot.appendingPathComponent(".build"), toolchain: toolchain)
  }

  /// Same, for any SwiftPM/swiftbuild scratch tree — a package's own `.build`,
  /// or the scratch path a dependency was built into (`ScanProjectPackages`).
  static func moduleSearchPaths(
    buildRoot: URL, toolchain: ScanToolchain
  ) -> (includeDirs: [String], moduleMapFiles: [String]) {
    let enumerator = FileManager.default.enumerator(
      at: buildRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    var parents: Set<String> = []
    // Keyed by module name: a build tree can hold the same generated modulemap
    // more than once (a large app: `.build/out/Intermediates.noindex/GeneratedModuleMaps`
    // and a nested `.build/out/out/...` copy), and passing both makes clang
    // report "redefinition of module 'CallUI'" before any source is read. The
    // shortest path wins, which is the primary directory.
    var moduleMaps: [String: String] = [:]
    var swiftModuleNames: Set<String> = []
    // Both the swiftbuild layout (`out/Products/Debug-iphonesimulator`) and the
    // classic SwiftPM one (`.build/<triple>/debug-iphonesimulator`).
    let acceptedProductDirectories = Set(
      toolchain.productDirectoryNames + [toolchain.platform.legacyProductDirectoryName])
    while let url = enumerator?.nextObject() as? URL {
      let components = url.path.split(separator: "/").map(String.init)
      if components.contains(where: moduleSkipComponents.contains) { continue }
      switch url.pathExtension {
      case "swiftmodule":
        // Slice files live INSIDE the module bundle:
        // `<products>/AppUI.swiftmodule/arm64-apple-ios-simulator.swiftmodule`.
        let bundle = url.deletingLastPathComponent()
        let productsDirectory = bundle.deletingLastPathComponent()
        let slice = url.deletingPathExtension().lastPathComponent
        guard slice.contains("apple-"),
              acceptedProductDirectories.contains(productsDirectory.lastPathComponent)
        else { continue }
        parents.insert(productsDirectory.path)
        swiftModuleNames.insert(bundle.deletingPathExtension().lastPathComponent)
      case "modulemap":
        guard components.contains(where: toolchain.moduleMapDirectoryNames.contains) else {
          continue
        }
        let name = moduleName(forModuleMap: url.path)
        if let existing = moduleMaps[name], existing.count <= url.path.count { continue }
        moduleMaps[name] = url.path
      default:
        break
      }
    }
    // A C target whose headers are PUBLIC gets no generated map in
    // `GeneratedModuleMaps-<platform>`; SwiftPM emits the map as
    // `<products>/include/module.modulemap` instead (avif.swift's `avifc` —
    // without it the consumer fails with "missing required module 'avifc'").
    for directory in parents {
      let candidate = URL(fileURLWithPath: directory)
        .appendingPathComponent("include/module.modulemap")
      guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
      let name = moduleName(forModuleMap: candidate.path)
      if moduleMaps[name] == nil { moduleMaps[name] = candidate.path }
    }

    // Clang-only modules only: a name that also has a `.swiftmodule` product
    // would be redefined by its modulemap.
    let clangOnly = moduleMaps
      .filter { name, _ in !swiftModuleNames.contains(name) }
      .values
      .sorted()
    return (parents.sorted(), clangOnly)
  }

  /// The module a `.modulemap` DECLARES, falling back to its file name. Needed
  /// because SwiftPM's public-header map is named `module.modulemap` for every
  /// such target — keying maps by file name would collide them.
  static func moduleName(forModuleMap path: String) -> String {
    let fallback = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let regex = try? NSRegularExpression(
            pattern: "(?m)^\\s*(?:explicit\\s+)?module\\s+([A-Za-z_][A-Za-z0-9_]*)"),
          let match = regex.firstMatch(
            in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
          match.numberOfRanges > 1,
          let captured = Range(match.range(at: 1), in: text)
    else { return fallback }
    return String(text[captured])
  }

  /// One `-fmodule-map-file=` argument per MODULE NAME, keeping the first
  /// occurrence of each. Attaching the same module's map twice makes clang
  /// report "redefinition of module 'X'" before any source is read — and a
  /// dependency built by the scan produces a second copy of every map the
  /// project's package build already generated (a large app: built
  /// `client-sdk-swift` next to the package's own maps → `LKObjCHelpers` twice,
  /// which failed all four project targets). Pass the list whose maps belong to
  /// the build the units actually type-check against FIRST.
  /// The same idea for `-I` directories: first occurrence wins, order preserved.
  ///
  /// ORDER IS THE POINT for search paths, where it is not for module maps. The FIRST directory
  /// holding a module is the one the compiler reads, and a machine that also builds the project in
  /// Xcode has THREE copies of the same modules: the scan's own fresh products, its scratch builds
  /// of the project's package dependencies, and Xcode's DerivedData — which can be a day older than
  /// the sources. Sorted alphabetically the oldest one came first (`~/Library` sorts before
  /// `~/github`), so a large app's main target type-checked against yesterday's `AppUI` and failed
  /// on APIs the current sources already have (reader, 2026-09-15: "make the app target compile, it's
  /// the most important one").
  static func uniqueDirs(_ paths: [String]) -> [String] {
    var seen: Set<String> = []
    var unique: [String] = []
    for path in paths where seen.insert(path).inserted { unique.append(path) }
    return unique
  }

  static func uniqueModuleMaps(_ paths: [String]) -> [String] {
    var seen: Set<String> = []
    var unique: [String] = []
    for path in paths {
      let name = moduleName(forModuleMap: path)
      if seen.insert(name).inserted { unique.append(path) }
    }
    return unique
  }

  /// Directories the XCTest/derived-data products of a project may live in
  /// (`~/Library/Developer/Xcode/DerivedData/<Project>-*/Build/Products/<Config>-<platform>`).
  /// A project target's own Swift package dependencies (e.g. `SwiftUIIntrospect`)
  /// only exist there — `swift build` does not build another project's
  /// dependencies — so when the user has built the app in Xcode, its extracted
  /// keys can still come out of this scan. Absent → the salvage loop drops the
  /// handful of files that import those packages and reports the module name.
  static func derivedDataIncludeDirs(
    projectName: String, toolchain: ScanToolchain
  ) -> [String] {
    let derivedData = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: derivedData, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    var directories: [String] = []
    for entry in entries.sorted(by: { $0.path < $1.path })
    where entry.lastPathComponent.hasPrefix(projectName + "-") {
      for productName in toolchain.productDirectoryNames {
        let candidate = entry
          .appendingPathComponent("Build/Products", isDirectory: true)
          .appendingPathComponent(productName, isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) {
          directories.append(candidate.path)
        }
      }
    }
    return directories
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
