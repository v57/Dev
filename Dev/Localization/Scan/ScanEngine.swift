//
//  ScanEngine.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import Foundation

/// What to scan.
nonisolated struct ScanConfig: Sendable {
  /// Repo tree to scan: every Swift package under it, plus every Xcode
  /// project's app-target sources.
  var root: URL
  /// Run `swift build` per package before extraction (the verified
  /// mechanism: a module's sources typecheck against its sibling modules'
  /// current `.swiftmodule` products). Off = extract with whatever products
  /// the package's `.build` already holds.
  var buildRefresh = true
}

/// Live progress of a running scan.
nonisolated enum ScanEvent: Sendable {
  case phase(String)
  case log(String)
  case discovered(packages: [String], projects: [String])
  case progress(done: Int, total: Int, label: String)
  case moduleFinished(ScanModuleOutcome)
}

/// One scan run: find the tree's Swift packages AND Xcode project targets,
/// extract every localizable key from their sources with the toolchain
/// (`swiftc -emit-localized-strings`), and union the result.
///
/// Synchronous by design — it runs on a detached task (the engine blocks on
/// subprocesses) and reports through `emit` plus the shared cancellation
/// token. Nothing here touches the catalog; the merge is the caller's step.
nonisolated enum ScanEngine {
  static func run(
    config: ScanConfig,
    cancellation: ScanCancellation,
    emit: @escaping @Sendable (ScanEvent) -> Void
  ) -> ScanReport {
    let startedAt = Date()
    var warnings: [String] = []
    let collected = Collector()

    // Scratch space for emitted modules + .stringsdata fragments.
    let workDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dev-scan-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDirectory) }

    // MARK: 1. discovery

    emit(.phase("Finding Swift packages and Xcode projects…"))
    let packageRoots = ScanPackageFinder.findPackageRoots(under: config.root)
    let projectURLs = ScanXcodeProject.findProjects(under: config.root)
    emit(.discovered(
      packages: packageRoots.map(\.path),
      projects: projectURLs.map(\.path)))

    if packageRoots.isEmpty, projectURLs.isEmpty {
      return ScanReport(
        root: config.root, startedAt: startedAt,
        duration: Date().timeIntervalSince(startedAt),
        packages: [], modules: [], extracted: [:], keyOwners: [:],
        skippedTableKeys: 0, warnings: [],
        cancelled: false,
        errorMessage: "Nothing to scan in \(config.root.path) — no Package.swift and no .xcodeproj found.")
    }

    // MARK: 2. packages -> compile units

    var units: [ScanCompileUnit] = []
    var projectUnits: [ScanCompileUnit] = []
    var allIncludeDirs: Set<String> = []
    var allModuleMapFiles: Set<String> = []
    var packageSeeds: [(name: String, root: URL, warning: String)] = []

    for packageRoot in packageRoots {
      if cancellation.isCancelled { break }
      let name = packageRoot.lastPathComponent
      emit(.phase("Reading \(name)…"))

      var warning = ""
      var manifest: ScanPackageManifest?
      do {
        manifest = try ScanPackageDumper.dump(packageRoot: packageRoot)
      } catch {
        warning = error.localizedDescription
        warnings.append("\(name): \(warning)")
        emit(.log("warning: \(name): \(warning)"))
      }

      if config.buildRefresh, !cancellation.isCancelled {
        emit(.phase("Building \(name)… (module products the extraction typechecks against)"))
        let buildWarning = ScanExtractor.buildWarning(for: packageRoot)
        if !buildWarning.isEmpty {
          warnings.append("\(name): \(buildWarning)")
          emit(.log("warning: \(name): \(buildWarning)"))
        }
      }

      let searchPaths = ScanExtractor.moduleSearchPaths(packageRoot: packageRoot)
      allIncludeDirs.formUnion(searchPaths.includeDirs)
      allModuleMapFiles.formUnion(searchPaths.moduleMapFiles)

      let packageName = manifest?.name.flatMap { $0.isEmpty ? nil : $0 } ?? name
      packageSeeds.append((packageName, packageRoot, warning))
      guard let manifest else { continue }

      for target in (manifest.targets ?? []).filter({ !$0.isSkippable }) {
        let files = ScanExtractor.targetSourceFiles(for: target, packageRoot: packageRoot)
        guard !files.isEmpty else { continue }
        let directory: String
        if let path = target.path, !path.isEmpty {
          directory = packageRoot.appendingPathComponent(path).path
        } else {
          directory = packageRoot.appendingPathComponent("Sources/\(target.name)").path
        }
        units.append(
          ScanCompileUnit(
            owner: packageName,
            module: target.effectiveModuleName,
            origin: .packageTarget,
            directory: directory,
            files: files,
            workingDirectory: packageRoot,
            includeDirs: searchPaths.includeDirs,
            moduleMapFiles: searchPaths.moduleMapFiles))
      }
    }

    // MARK: 3. Xcode project targets -> compile units
    // Their sources import the package modules, so they compile against the
    // union of every package's module search paths.

    if !cancellation.isCancelled {
      for projectURL in projectURLs {
        if cancellation.isCancelled { break }
        let projectName = projectURL.deletingPathExtension().lastPathComponent
        emit(.phase("Reading \(projectName).xcodeproj…"))
        let targets = ScanXcodeProject.targets(inProjectAt: projectURL)
        if targets.isEmpty {
          warnings.append("\(projectName): no scannable targets in \(projectURL.path)")
          emit(.log("warning: \(projectName): no scannable targets"))
        }
        for target in targets {
          if cancellation.isCancelled { break }
          var files = target.files.filter { FileManager.default.fileExists(atPath: $0.path) }
          for directory in target.directories {
            files.append(contentsOf: ScanExtractor.swiftFiles(in: directory))
          }
          var seen = Set<String>()
          files = files
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
          guard !files.isEmpty else { continue }
          let roots = (target.directories.map(\.path) + (target.files.isEmpty ? [] : ["listed sources"]))
          projectUnits.append(
            ScanCompileUnit(
              owner: projectName,
              module: sanitizedModuleName(target.name),
              origin: .projectTarget,
              directory: roots.isEmpty ? "listed sources" : roots.joined(separator: ", "),
              files: files,
              workingDirectory: projectURL.deletingLastPathComponent(),
              includeDirs: allIncludeDirs.sorted(),
              moduleMapFiles: allModuleMapFiles.sorted()))
        }
      }
    }

    let allUnits = units + projectUnits
    emit(.phase("Extracting strings from \(allUnits.count) module(s)…"))

    // MARK: 4. extraction (parallel; each compile is its own process)

    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = ScanExtractor.maxConcurrentCompiles
    queue.name = "dev.localization.scan"
    for unit in allUnits {
      queue.addOperation {
        if cancellation.isCancelled { return }
        let outcome = ScanExtractor.compile(
          unit, workDirectory: workDirectory, cancellation: cancellation)
        let done = collected.record(outcome)
        emit(.moduleFinished(outcome))
        emit(.progress(done: done.done, total: allUnits.count, label: outcome.id))
      }
    }
    queue.waitUntilAllOperationsAreFinished()

    let modules = collected.modules.sorted { $0.id < $1.id }

    // MARK: 5. union across modules (one key found twice is ONE key)

    var extracted: [String: Set<String>] = [:]
    var keyOwners: [String: Set<String>] = [:]
    var skippedTotal = 0
    for module in modules {
      skippedTotal += module.skippedTableKeys
      for (key, comments) in module.keys {
        extracted[key, default: []].formUnion(comments)
        keyOwners[key, default: []].insert(module.id)
      }
    }

    // MARK: 6. per-package roll-up

    let packages: [ScanPackageOutcome] = packageSeeds.map { seed in
      let owned = modules.filter { $0.owner == seed.name && $0.origin == .packageTarget }
      return ScanPackageOutcome(
        name: seed.name,
        root: seed.root,
        buildWarning: seed.warning,
        moduleCount: owned.count,
        keyCount: owned.reduce(0) { $0 + $1.keys.count })
    }

    return ScanReport(
      root: config.root,
      startedAt: startedAt,
      duration: Date().timeIntervalSince(startedAt),
      packages: packages,
      modules: modules,
      extracted: extracted,
      keyOwners: keyOwners.mapValues { $0.sorted() },
      skippedTableKeys: skippedTotal,
      warnings: warnings,
      cancelled: cancellation.isCancelled,
      errorMessage: nil)
  }

  /// Cheap root heuristic for the UI: a folder that directly holds an
  /// `.xcodeproj`, a `Package.swift` or a `.git` is a repo root worth
  /// scanning. Deliberately shallow — it runs from the toolbar, so it must
  /// never walk a tree.
  static func looksLikeRepoRoot(_ url: URL) -> Bool {
    let manager = FileManager.default
    if manager.fileExists(atPath: url.appendingPathComponent(".git").path) { return true }
    if manager.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return true }
    let contents = (try? manager.contentsOfDirectory(
      at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    return contents.contains { $0.pathExtension == "xcodeproj" }
  }

  /// OperationQueue result sink (compiles finish on several threads).
  private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScanModuleOutcome] = []
    private var count = 0

    var modules: [ScanModuleOutcome] {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }

    /// Appends one outcome and returns the running completion count.
    func record(_ outcome: ScanModuleOutcome) -> (done: Int, modules: Int) {
      lock.lock()
      defer { lock.unlock() }
      storage.append(outcome)
      count += 1
      return (count, storage.count)
    }
  }

  /// Target names with spaces/dashes are not valid module names.
  private static func sanitizedModuleName(_ name: String) -> String {
    name
      .replacingOccurrences(of: "-", with: "_")
      .replacingOccurrences(of: " ", with: "_")
  }
}
