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
        packages: [], modules: [], extracted: [:], keyOwners: [:], keyFiles: [:],
        skippedTableKeys: 0, warnings: [],
        cancelled: false,
        errorMessage: "Nothing to scan in \(config.root.path) — no Package.swift and no .xcodeproj found.")
    }

    // MARK: 1b. which platform the tree builds for

    // Package manifests are read once here: the platform decision needs their
    // target source lists, and the unit loop below needs them again.
    var manifests: [String: ScanPackageManifest] = [:]
    for packageRoot in packageRoots {
      if cancellation.isCancelled { break }
      let name = packageRoot.lastPathComponent
      emit(.phase("Reading \(name)…"))
      do {
        manifests[packageRoot.path] = try ScanPackageDumper.dump(packageRoot: packageRoot)
      } catch {
        let detail = error.localizedDescription
        warnings.append("\(name): \(detail)")
        emit(.log("warning: \(name): \(detail)"))
      }
    }

    // An iOS tree cannot type-check against the host's module products (and its
    // host build usually fails outright), so the platform is decided from the
    // tree itself: an SDKROOT the project declares, or a module that imports
    // UIKit. See `ScanToolchain`.
    let toolchain = resolveToolchain(
      projectURLs: projectURLs, packageRoots: packageRoots, manifests: manifests,
      warnings: &warnings, emit: emit)
    let platformLabel = toolchain.platform == .iosSimulator ? "iOS Simulator" : "the host"

    // MARK: 2. packages -> compile units

    var units: [ScanCompileUnit] = []
    var projectUnits: [ScanCompileUnit] = []
    var allIncludeDirs: Set<String> = []
    var allModuleMapFiles: Set<String> = []
    var packageSeeds: [(name: String, root: URL, warning: String)] = []

    // A tree can hold targets for both platforms (playgra: an iOS app next to
    // an AppKit preview app; Dev: a project whose SDKROOT is `auto`). The
    // platform is therefore chosen per UNIT from the sources themselves, with
    // the run's resolved platform as the default, and each unit is compiled
    // against its own platform's product directories — a host slice in an iOS
    // compile is unusable and vice versa.
    // MARK: 2a. build the packages — BEFORE a single search path is read
    //
    // The ORDER here is the fix (reader, 2026-09-15: "playgra failed to scan after i deleted
    // Sources/.build", where every library with a dependency reported
    // `no such module 'SomeCore'`). `moduleSearchPaths` ENUMERATES the package's `.build` for
    // `*.swiftmodule` products, and it used to run before `buildWarning`'s `swift build`: on a tree
    // whose `.build` is gone, the enumeration finds nothing, every unit is handed an EMPTY `-I` set
    // (the per-platform entry exists — as an empty tuple — so `unitCompileSetup` never falls back to
    // the union), and the refresh then rebuilt 91 cold products into a tree nothing had read. The
    // build was never the failure; it was the reading that came first.
    if config.buildRefresh {
      for packageRoot in packageRoots {
        if cancellation.isCancelled { break }
        let name = packageRoot.lastPathComponent
        emit(.phase("Building \(name) for \(platformLabel)… (module products the extraction typechecks against)"))
        let buildWarning = ScanExtractor.buildWarning(for: packageRoot, toolchain: toolchain)
        if !buildWarning.isEmpty {
          warnings.append("\(name): \(buildWarning)")
          emit(.log("warning: \(name): \(buildWarning)"))
        }
      }
    }

    var platformSearchPaths: [ScanPlatform: (includeDirs: [String], moduleMapFiles: [String])] = [:]
    var hostSearch: (includeDirs: Set<String>, moduleMapFiles: Set<String>) = ([], [])
    var iosSearch: (includeDirs: Set<String>, moduleMapFiles: Set<String>) = ([], [])
    for packageRoot in packageRoots {
      let host = ScanExtractor.moduleSearchPaths(packageRoot: packageRoot, toolchain: .host())
      hostSearch.includeDirs.formUnion(host.includeDirs)
      hostSearch.moduleMapFiles.formUnion(host.moduleMapFiles)
      if toolchain.platform == .iosSimulator {
        let ios = ScanExtractor.moduleSearchPaths(packageRoot: packageRoot, toolchain: toolchain)
        iosSearch.includeDirs.formUnion(ios.includeDirs)
        iosSearch.moduleMapFiles.formUnion(ios.moduleMapFiles)
      }
    }
    platformSearchPaths[.host] = (hostSearch.includeDirs.sorted(), hostSearch.moduleMapFiles.sorted())
    if toolchain.platform == .iosSimulator {
      platformSearchPaths[.iosSimulator] = (iosSearch.includeDirs.sorted(), iosSearch.moduleMapFiles.sorted())
    }

    /// The platform this unit compiles for:
    ///  - an explicit UIKit import means iOS;
    ///  - an explicit AppKit import (and no UIKit) means the host;
    ///  - a PROJECT target that imports neither is not an iOS target — an
    ///    Xcode project routinely holds a mixed set (playgra: the iOS app next
    ///    to an AppKit-less SwiftUI preview app that uses `NSBezierPath` with
    ///    only `import SwiftUI`, which re-exports AppKit on macOS). Compiling
    ///    it for iOS fails on exactly those symbols;
    ///  - everything else follows the run's resolved platform.
    func unitPlatform(_ files: [URL]) -> ScanPlatform {
      if ScanPlatformResolver.importsUIKit(files) { return .iosSimulator }
      // AN iOS RUN IS iOS ONLY (reader, 2026-09-15: "only build on ios"). The scan builds ONE
      // platform — the one it resolved — so routing a unit to the OTHER one hands it a product set
      // that was never built: after the reader deleted `Sources/.build`, CoreUI's `Window.swift`
      // (whose `import AppKit` sits inside `#if os(macOS)`, which the marker test cannot see) was
      // classified host, got an empty `-I` set, and failed on `no such module 'Router'` even though
      // the iOS build compiles that very file. The macOS heuristic now applies only to a run that
      // IS the host, where a macOS-only unit is genuinely a different platform.
      if toolchain.platform == .iosSimulator { return .iosSimulator }
      if ScanPlatformResolver.usesMacOSOnlyAPI(files) { return .host }
      return toolchain.platform
    }

    /// The toolchain + search paths for one unit, defaulting to the run's
    /// platform when the unit's platform has no products of its own.
    func unitCompileSetup(_ files: [URL]) -> (ScanToolchain, [String], [String]) {
      let platform = unitPlatform(files)
      guard let paths = platformSearchPaths[platform] else {
        return (toolchain, allIncludeDirs.sorted(), allModuleMapFiles.sorted())
      }
      switch platform {
      case .host:
        return (.host(), paths.includeDirs, paths.moduleMapFiles)
      case .iosSimulator:
        return (toolchain, paths.includeDirs, paths.moduleMapFiles)
      }
    }

    for packageRoot in packageRoots {
      if cancellation.isCancelled { break }
      let name = packageRoot.lastPathComponent
      let manifest = manifests[packageRoot.path]

      // Already built, above: this loop reads what that build produced.
      let searchPaths = ScanExtractor.moduleSearchPaths(
        packageRoot: packageRoot, toolchain: toolchain)
      allIncludeDirs.formUnion(searchPaths.includeDirs)
      allModuleMapFiles.formUnion(searchPaths.moduleMapFiles)

      let packageName = manifest?.name.flatMap { $0.isEmpty ? nil : $0 } ?? name
      packageSeeds.append((packageName, packageRoot, manifests[packageRoot.path] == nil
        ? "manifest unreadable" : ""))
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
        let setup = unitCompileSetup(files)
        units.append(
          ScanCompileUnit(
            owner: packageName,
            module: target.effectiveModuleName,
            origin: .packageTarget,
            directory: directory,
            files: files,
            workingDirectory: packageRoot,
            includeDirs: setup.1,
            moduleMapFiles: setup.2,
            toolchain: setup.0))
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
        let settingsArguments = ScanSwiftSettings.arguments(fromProjectAt: projectURL)
        let targets = ScanXcodeProject.targets(inProjectAt: projectURL)
        if targets.isEmpty {
          warnings.append("\(projectName): no scannable targets in \(projectURL.path)")
          emit(.log("warning: \(projectName): no scannable targets"))
        }
        // The project's own Swift package dependencies (SwiftUIIntrospect,
        // avif.swift, …) are built by Xcode's package resolution, never by the
        // SwiftPM package build above. Two sources are used, in order:
        //   1. the project's derived data, when Xcode has built it before
        //      (`ScanExtractor.derivedDataIncludeDirs`);
        //   2. the pinned revisions in Xcode's local package cache, materialized
        //      and built for the scan's platform (`ScanProjectPackages`) — the
        //      route that works when resolution cannot run at all.
        var projectPackageIncludes: [String] = []
        var projectPackageMaps: [String] = []
        var projectPackageClangIncludes: [String] = []
        var dependencyModules: [ScanDependencyModules] = []
        if !targets.isEmpty, !cancellation.isCancelled {
          let imported = importedModules(in: targets)
          let pins = ScanProjectPackages.resolvedPins(forProjectAt: projectURL)
          if !pins.isEmpty, !imported.isEmpty {
            emit(.phase("Building \(projectName)'s package dependencies for \(platformLabel)…"))
            let packagePaths = ScanProjectPackages.build(
              pins: pins, projectName: projectName, importedModules: imported,
              toolchain: toolchain, workDirectory: workDirectory,
              cancellation: cancellation
            ) { outcome in
              switch outcome.status {
              case .built:
                emit(.log("package \(outcome.identity): built \(outcome.modules.joined(separator: ", "))"))
              case .cached:
                emit(.log("package \(outcome.identity): reused a previous build"))
              case .notImported:
                break
              case .noCheckout:
                emit(.log("package \(outcome.identity): no cached checkout — \(outcome.detail)"))
              case .failed:
                emit(.log("warning: package \(outcome.identity): \(outcome.detail)"))
              }
            }
            projectPackageIncludes = packagePaths.includeDirs
            projectPackageMaps = packagePaths.moduleMapFiles
            projectPackageClangIncludes = packagePaths.clangIncludeDirs
            dependencyModules = packagePaths.dependencies
          }
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
          let setup = unitCompileSetup(files)
          let derivedData = ScanExtractor.derivedDataIncludeDirs(
            projectName: projectName, toolchain: setup.0)
          projectUnits.append(
            ScanCompileUnit(
              owner: projectName,
              module: sanitizedModuleName(target.name),
              origin: .projectTarget,
              directory: roots.isEmpty ? "listed sources" : roots.joined(separator: ", "),
              files: files,
              workingDirectory: projectURL.deletingLastPathComponent(),
              // FRESHEST FIRST, and never an alphabetical sort: the first directory holding a
              // module is the one the compiler reads. `setup.1` is this run's own `swift build`
              // products, `projectPackageIncludes` are the scans' builds of the project's package
              // dependencies, and `derivedData` is Xcode's — which on this reader's machine held
              // yesterday's `VijoUI`, so `Vijo` failed on `Notifications.text(_:icon:)` and
              // `VijoAlert.cancel(action:)` after the sources had both (2026-09-15).
              includeDirs: ScanExtractor.uniqueDirs(
                setup.1
                  + (setup.0.platform == toolchain.platform ? projectPackageIncludes : [])
                  + derivedData.sorted()),
              moduleMapFiles: ScanExtractor.uniqueModuleMaps(
                projectPackageMaps + setup.2.sorted()),
              // The project's package dependencies' C headers: their clang modules only resolve
              // with these (`avifc` → `avif/avif.h`), and only for the platform this run built.
              clangIncludeDirs: setup.0.platform == toolchain.platform
                ? projectPackageClangIncludes : [],
              toolchain: setup.0,
              settingsArguments: settingsArguments,
              dependencies: dependencyModules))
        }
      }
    }

    allModuleMapFiles = Set(ScanExtractor.uniqueModuleMaps(allModuleMapFiles.sorted()))
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
    var keyFiles: [String: Set<String>] = [:]
    var skippedTotal = 0
    for module in modules {
      skippedTotal += module.skippedTableKeys
      for (key, comments) in module.keys {
        extracted[key, default: []].formUnion(comments)
        keyOwners[key, default: []].insert(module.id)
      }
      for (key, files) in module.keyFiles {
        keyFiles[key, default: []].formUnion(files)
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
      keyFiles: keyFiles.mapValues { $0.sorted() },
      skippedTableKeys: skippedTotal,
      warnings: warnings,
      cancelled: cancellation.isCancelled,
      errorMessage: nil)
  }

  /// Every module the project's targets import (`import Foo`), the filter for
  /// which pinned package dependencies are worth building.
  private static func importedModules(in targets: [ScanXcodeTarget]) -> Set<String> {
    var files: [URL] = targets.flatMap(\.files)
    for target in targets {
      files += target.directories.flatMap { ScanExtractor.swiftFiles(in: $0) }
    }
    // Module names may be lowercase (`import avifnuke`) — no case filter.
    let modifiers: Set<String> = [
      "class", "struct", "enum", "protocol", "func", "var", "let", "typealias", "actor",
    ]
    var modules: Set<String> = []
    for file in files.prefix(600) {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      for line in text.split(separator: "\n").prefix(80) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("import ") else { continue }
        var tokens = trimmed.dropFirst("import ".count)
          .trimmingCharacters(in: .whitespaces)
          .split(separator: " ").map(String.init)
        // `import class Foo.Bar` names a declaration, not a module.
        if let first = tokens.first, modifiers.contains(first) { tokens.removeFirst() }
        guard let name = tokens.first, !name.isEmpty else { continue }
        // `import Foo.Bar` → `Foo`.
        let module = name.split(separator: ".").first.map(String.init) ?? name
        if !module.isEmpty { modules.insert(module) }
      }
    }
    return modules
  }

  /// Decides the platform the scan type-checks against and builds the matching
  /// toolchain: an iOS app (SDKROOT = iphoneos, or any source importing UIKit)
  /// is compiled for the iOS simulator with the product directories its own
  /// build wrote; anything else stays on the host.
  private static func resolveToolchain(
    projectURLs: [URL],
    packageRoots: [URL],
    manifests: [String: ScanPackageManifest],
    warnings: inout [String],
    emit: (ScanEvent) -> Void
  ) -> ScanToolchain {
    let projectUsesIOS = projectURLs.contains {
      ScanPlatformResolver.projectUsesIOSSDK(at: $0)
    }
    let packageImportsUIKit = packageRoots.contains { packageRoot in
      guard let manifest = manifests[packageRoot.path] else { return false }
      for target in (manifest.targets ?? []).filter({ !$0.isSkippable }) {
        let files = ScanExtractor.targetSourceFiles(for: target, packageRoot: packageRoot)
        // The whole target, not its first twelve files: a UIKit import past file 12 (alphabetical)
        // used to leave an iOS package resolved as the HOST, which then builds host products for a
        // tree that cannot make them (reader, 2026-09-15: "also prioritize building on iOS").
        if ScanPlatformResolver.importsUIKit(files) { return true }
      }
      return false
    }
    // A declared iOS platform counts as an iOS tree on its own (a package declaring both iOS and
    // macOS is an iOS TREE for this scan: the iOS build is the one it makes).
    let packageDeclaresIOS = packageRoots.contains {
      ScanPlatformResolver.declaresIOSPlatform(manifests[$0.path]?.rawJSON)
    }
    guard projectUsesIOS || packageImportsUIKit || packageDeclaresIOS else {
      emit(.phase("Targets the host platform"))
      return .host()
    }

    // The triple has to match the slices the tree's products were built for.
    let deploymentTarget = ScanPlatformResolver.deploymentTarget(
      projectURLs: projectURLs, packageManifestText: nil) ?? "17.0"
    let productDirectories = packageRoots.flatMap { packageRoot -> [URL] in
      let buildRoot = packageRoot.appendingPathComponent(".build")
      var found: [URL] = []
      for productName in ["Debug-iphonesimulator", "debug-iphonesimulator"] {
        let candidate = buildRoot.appendingPathComponent("out/Products/\(productName)")
        if FileManager.default.fileExists(atPath: candidate.path) { found.append(candidate) }
        let legacy = buildRoot.appendingPathComponent("debug-iphonesimulator")
        if FileManager.default.fileExists(atPath: legacy.path) { found.append(legacy) }
      }
      return found
    }
    var triple: String?
    for directory in productDirectories {
      if let candidate = ScanSliceDetector.iosSimulatorTriple(
        inProductsDirectory: directory, deploymentTarget: deploymentTarget) {
        triple = candidate
        break
      }
    }
    let resolved = triple ?? "arm64-apple-ios\(deploymentTarget)-simulator"
    emit(.phase("Targets iOS Simulator (\(resolved))"))
    if triple == nil {
      warnings.append(
        "no iOS Simulator build products found under .build — the extraction assumes \(resolved); "
          + "run the package's iOS build once (Xcode or swift build --sdk iphonesimulator) "
          + "if modules come back missing.")
    }
    return .iosSimulator(doubleTarget: resolved)
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
