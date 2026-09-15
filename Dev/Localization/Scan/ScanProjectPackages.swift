//
//  ScanProjectPackages.swift
//  Dev
//
//  Created by Dmitry on 11.09.26.
//

import Foundation

/// One package the project's workspace resolved, with the revision it pinned.
nonisolated struct ScanResolvedPin: Sendable {
  var identity: String
  var revision: String
  var version: String?
}

/// What happened to one requested package dependency.
nonisolated struct ScanPackageBuildOutcome: Sendable {
  enum Status: Sendable {
    /// Built for the scan's platform; its products are on the search path.
    case built
    /// Already built by an earlier scan, for the same revision and platform.
    case cached
    /// The project's sources never import it — nothing to build.
    case notImported
    /// Pinned, but no cached checkout on this machine to build from.
    case noCheckout
    case failed
  }

  var identity: String
  var status: Status
  /// The products that became available (importable module names).
  var modules: [String] = []
  /// Every target module the package builds, clang targets included.
  var targets: [String] = []
  var detail: String = ""
}

/// Builds a project's own Swift package dependencies — the ones Xcode's package
/// resolution provides and `swift build` never sees — so the project's targets
/// can be type-checked and their strings extracted.
///
/// Why not `xcodebuild` first: on the machine this was written for,
/// `xcodebuild -resolvePackageDependencies` FAILS for the target project
/// because the pinned version no longer exists upstream (swiftui-introspect was
/// retagged from `1.4.0-beta.x` to `26.x`, so the project's
/// `1.4.0-beta.2..<2.0.0` requirement matches no tag; verified 2026-09-11), and
/// a resolved-then-built app would also cost a full app build per scan. The
/// revision the project PINS is still in Xcode's local package cache, and that
/// cache builds fine for the simulator in seconds, so the scan materializes and
/// builds from there instead — no network, no repo writes (everything happens
/// in the scan's own work directory).
nonisolated enum ScanProjectPackages {
  /// The packages pinned by the project's workspace resolution.
  static func resolvedPins(forProjectAt projectURL: URL) -> [ScanResolvedPin] {
    let candidates = [
      projectURL.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
      projectURL.appendingPathComponent("xcshareddata/swiftpm/Package.resolved"),
    ]
    for url in candidates {
      guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      // Schema 2/3 keep `pins` at the top level; schema 1 nests it under `object`.
      let rawPins = (json["pins"] as? [[String: Any]])
        ?? ((json["object"] as? [String: Any])?["pins"] as? [[String: Any]])
        ?? []
      var pins: [ScanResolvedPin] = []
      for pin in rawPins {
        guard let identity = pin["identity"] as? String,
              let location = pin["location"] as? String
        else { continue }
        // Schema 1 keys the pin by the package name, not the identity.
        let resolvedIdentity = identity.isEmpty
          ? URL(string: location)?.lastPathComponent.replacingOccurrences(of: ".git", with: "")
            ?? location
          : identity
        guard let state = pin["state"] as? [String: Any],
              let revision = state["revision"] as? String
        else { continue }
        pins.append(ScanResolvedPin(
          identity: resolvedIdentity,
          revision: revision,
          version: state["version"] as? String))
      }
      if !pins.isEmpty { return pins.sorted { $0.identity < $1.identity } }
    }
    return []
  }

  /// Builds every pinned package the project's sources actually import, for the
  /// scan's platform. Returns the search paths to add: the product directories
  /// AND the clang modulemaps of the built dependency (a package can vend a C
  /// module the Swift side re-exports — avif.swift's `avifc` — and without its
  /// modulemap the consumer reports "missing required module 'avifc'").
  static func build(
    pins: [ScanResolvedPin],
    projectName: String,
    importedModules: Set<String>,
    toolchain: ScanToolchain,
    workDirectory: URL,
    cancellation: ScanCancellation,
    report: (ScanPackageBuildOutcome) -> Void
  ) -> (
    includeDirs: [String], moduleMapFiles: [String], clangIncludeDirs: [String],
    dependencies: [ScanDependencyModules]
  ) {
    guard !pins.isEmpty, !importedModules.isEmpty else { return ([], [], [], []) }
    guard let triple = toolchain.targetTriple, let sdk = toolchain.sdkPath else {
      // A host scan reads the same products from the project's derived data
      // (see `ScanExtractor.derivedDataIncludeDirs`); building a UIKit-free
      // package for the host is what `swift build` already does.
      return ([], [], [], [])
    }

    var includeDirs: [String] = []
    var moduleMapFiles: [String] = []
    var clangIncludeDirs: [String] = []
    var dependencies: [ScanDependencyModules] = []
    for pin in pins {
      if cancellation.isCancelled { break }
      let slot = cacheSlot(for: pin, cacheRoot: cacheRoot(workDirectory: workDirectory))
      let checkout = slot.appendingPathComponent("checkout", isDirectory: true)
      let scratch = slot.appendingPathComponent("scratch", isDirectory: true)

      // Reuse a previous scan's build for the same revision + platform: the
      // dependency builds are the slow part of a project scan (3 dependencies,
      // ~60 s on the tree this was measured on).
      if let marker = readMarker(slot), marker.format == BuildMarker.currentFormat,
         marker.revision == pin.revision,
         marker.triple == triple,
         marker.swiftVersion == ScanToolchain.compilerVersion(),
         FileManager.default.fileExists(
          atPath: marker.productsDirectory) {
        includeDirs.append(marker.productsDirectory)
        moduleMapFiles += marker.moduleMapFiles
        clangIncludeDirs += marker.clangIncludeDirs
        dependencies.append(ScanDependencyModules(
          identity: pin.identity, products: marker.modules, targets: marker.targets))
        report(ScanPackageBuildOutcome(
          identity: pin.identity, status: .cached, modules: marker.modules,
          detail: marker.productsDirectory))
        continue
      }

      guard let mirror = cachedMirror(identity: pin.identity, projectName: projectName) else {
        report(ScanPackageBuildOutcome(
          identity: pin.identity, status: .noCheckout,
          detail: "no cached checkout in Xcode's DerivedData or SwiftPM's cache"))
        continue
      }
      guard materialize(mirror: mirror, revision: pin.revision, into: checkout, cancellation: cancellation)
      else {
        report(ScanPackageBuildOutcome(
          identity: pin.identity, status: .failed,
          detail: "could not check out \(pin.revision.prefix(8)) from \(mirror.lastPathComponent)"))
        continue
      }

      let packageModules = packageModules(packageRoot: checkout)
      let wanted = packageModules.products.filter { importedModules.contains($0) }
      guard !wanted.isEmpty else {
        report(ScanPackageBuildOutcome(identity: pin.identity, status: .notImported))
        continue
      }

      let result = ScanShell.swift(
        ["build", "--sdk", sdk, "--triple", triple, "--scratch-path", scratch.path],
        currentDirectory: checkout, timeout: 900)
      guard result.succeeded else {
        report(ScanPackageBuildOutcome(
          identity: pin.identity, status: .failed, modules: wanted,
          detail: result.firstErrorLine))
        continue
      }
      // The package's own C/C++ targets ship their modulemaps under `include/` (avif.swift's
      // `avifc`), and a swiftbuild tree does NOT regenerate them: the scratch holds maps for the C
      // targets the Swift build itself compiles (`avif`, `avifnuke`, `Nuke`) and none for `avifc`,
      // whose map is the checkout's own file. A Swift module that REQUIRES such a clang module fails
      // outright — playgra's `Vijo` imports `avifnuke`, which requires `avifc` — and the salvage path
      // drops every importing file, so the app the scan exists for came back with 44 keys from 171
      // files (reader, 2026-09-15: "Make Vijo target compile. It's the most important one").
      let shippedMaps = shippedModuleMaps(checkout: checkout)
      let searchPaths = ScanExtractor.moduleSearchPaths(
        buildRoot: scratch, toolchain: toolchain)
      guard let productsDirectory = searchPaths.includeDirs.first else {
        report(ScanPackageBuildOutcome(
          identity: pin.identity, status: .failed, modules: wanted,
          detail: "build succeeded but no products directory was found"))
        continue
      }
      writeMarker(
        BuildMarker(
          revision: pin.revision, triple: triple, productsDirectory: productsDirectory,
          swiftVersion: ScanToolchain.compilerVersion(),
          modules: wanted, targets: packageModules.targets,
          moduleMapFiles: searchPaths.moduleMapFiles + shippedMaps.maps,
          clangIncludeDirs: shippedMaps.includes),
        slot: slot)
      includeDirs += searchPaths.includeDirs
      moduleMapFiles += searchPaths.moduleMapFiles
      moduleMapFiles += shippedMaps.maps
      clangIncludeDirs += shippedMaps.includes
      dependencies.append(ScanDependencyModules(
        identity: pin.identity, products: wanted, targets: packageModules.targets))
      report(ScanPackageBuildOutcome(
        identity: pin.identity, status: .built, modules: wanted,
        targets: packageModules.targets, detail: productsDirectory))
    }
    return (includeDirs, moduleMapFiles, clangIncludeDirs, dependencies)
  }

  /// The `include/module.modulemap` files a package's own C/C++ targets ship.
  ///
  /// One per target directory, sorted so the marker is stable. A target with no map of its own is
  /// skipped rather than invented: the products directory already carries clang's implicit one.
  private static func shippedModuleMaps(checkout: URL) -> (maps: [String], includes: [String]) {
    let sources = checkout.appendingPathComponent("Sources", isDirectory: true)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return ([], []) }
    var maps: [String] = []
    var includes: [String] = []
    for entry in entries.sorted(by: { $0.path < $1.path }) {
      let include = entry.appendingPathComponent("include", isDirectory: true)
      let map = include.appendingPathComponent("module.modulemap")
      guard FileManager.default.fileExists(atPath: map.path) else { continue }
      maps.append(map.path)
      includes.append(include.path)
    }
    return (maps, includes)
  }

  // MARK: - build cache

  /// What a previous build of one dependency wrote, so a later scan can reuse
  /// it. The build is keyed by revision + triple + THE COMPILER: a different pin, platform or
  /// toolchain builds again.
  ///
  /// The compiler is the one that was missing, and it is not fussiness: a `.swiftmodule` is
  /// readable only by a compiler that can read its format, and an Xcode/Swift update leaves every
  /// cached module stale — the reader's `Vijo` lost every key to "module 'Nuke' was compiled with a
  /// different version of Swift", with its own sources untouched (2026-09-15). A marker written
  /// before this field existed decodes as nil, which is not equal to any version, so it rebuilds
  /// once.
  private struct BuildMarker: Codable {
    /// Bumped whenever the way products/maps are collected changes: an old
    /// marker would otherwise hand out search paths that miss whatever the new
    /// logic adds (a real miss: `avifc`'s public-header modulemap — and again when that map started
    /// being collected AT ALL, from the checkout rather than the scratch).
    static let currentFormat = 4
    var format: Int = BuildMarker.currentFormat
    var revision: String
    var triple: String
    var productsDirectory: String
    /// `ScanToolchain.compilerVersion()` of the build that wrote these products.
    var swiftVersion: String?
    var modules: [String]
    var targets: [String] = []
    var moduleMapFiles: [String]
    /// `-Xcc -I` paths of the packages' own C targets: a clang module's headers do not resolve
    /// without them (`avifc` → `avif/avif.h`).
    var clangIncludeDirs: [String] = []
  }

  /// Where built dependencies live between scans. A user cache, not the repo
  /// and not the scan's temp directory: the scan must not write into the
  /// scanned project, and rebuilding ~60 s of dependencies per scan is waste.
  private static func cacheRoot(workDirectory: URL) -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? workDirectory
    return caches
      .appendingPathComponent("dev.v57.dev", isDirectory: true)
      .appendingPathComponent("scan-packages", isDirectory: true)
  }

  private static func cacheSlot(for pin: ScanResolvedPin, cacheRoot: URL) -> URL {
    let safe = pin.identity.replacingOccurrences(of: "/", with: "_")
    return cacheRoot.appendingPathComponent(safe, isDirectory: true)
  }

  private static func readMarker(_ slot: URL) -> BuildMarker? {
    let url = slot.appendingPathComponent("build.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(BuildMarker.self, from: data)
  }

  private static func writeMarker(_ marker: BuildMarker, slot: URL) {
    try? FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(marker) else { return }
    try? data.write(to: slot.appendingPathComponent("build.json"), options: .atomic)
  }

  // MARK: - cache lookup

  /// The cached bare clone of a package: Xcode keeps one per project's derived
  /// data (`SourcePackages/repositories`), SwiftPM one per user cache.
  private static func cachedMirror(identity: String, projectName: String) -> URL? {
    var roots: [URL] = []
    let derivedData = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    if let entries = try? FileManager.default.contentsOfDirectory(
      at: derivedData, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
      for entry in entries where entry.lastPathComponent.hasPrefix(projectName + "-") {
        roots.append(entry.appendingPathComponent("SourcePackages/repositories", isDirectory: true))
      }
      // Any project's cache is a valid source of the same public package.
      for entry in entries {
        roots.append(entry.appendingPathComponent("SourcePackages/repositories", isDirectory: true))
      }
    }
    roots.append(URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".cache/org.swift.swiftpm/repositories", isDirectory: true))
    roots.append(URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Caches/org.swift.swiftpm/repositories", isDirectory: true))

    for root in roots {
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
        continue
      }
      // Identities are lowercased in Package.resolved, the on-disk directory
      // keeps the package's own capitalization (`CombineExt-b54947e3` for
      // `combineext`), so the match is case-insensitive.
      for name in names.sorted()
      where name.lowercased() == identity.lowercased()
        || name.lowercased().hasPrefix(identity.lowercased() + "-") {
        let candidate = root.appendingPathComponent(name, isDirectory: true)
        // A bare/mirrored clone, not a working checkout.
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("HEAD").path) {
          return candidate
        }
      }
    }
    return nil
  }

  /// Checks the pinned revision out of a local mirror. `--shared` keeps it a
  /// hardlink clone: no network, no copy of the object store.
  private static func materialize(
    mirror: URL, revision: String, into directory: URL, cancellation: ScanCancellation
  ) -> Bool {
    try? FileManager.default.createDirectory(
      at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: directory)
    let clone = ScanShell.run(
      "/usr/bin/git",
      arguments: ["clone", "--quiet", "--shared", mirror.path, directory.path],
      currentDirectory: nil, timeout: 300)
    guard clone.succeeded else { return false }
    let checkout = ScanShell.run(
      "/usr/bin/git", arguments: ["checkout", "--quiet", revision],
      currentDirectory: directory, timeout: 300)
    return checkout.succeeded
  }

  // MARK: - manifest + products

  /// Module names a package offers: its products' names (a product IS a module
  /// for a Swift target) plus its target module names. `avif.swift` is the
  /// demonstration of why the manifest matters — the project imports
  /// `avifnuke`, which is a product name, not the package name.
  private static func packageModules(packageRoot: URL) -> (products: [String], targets: [String]) {
    guard let manifest = try? ScanPackageDumper.dump(packageRoot: packageRoot) else {
      return ([], [])
    }
    var names: Set<String> = []
    var targets: Set<String> = []
    // Products are not in `ScanPackageManifest` (it models targets for the
    // extraction), so read them straight from the dumped JSON.
    if let data = manifest.rawJSON,
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let products = json["products"] as? [[String: Any]] {
      for product in products {
        if let name = product["name"] as? String { names.insert(name) }
      }
    }
    for target in manifest.targets ?? [] {
      targets.insert(target.effectiveModuleName)
    }
    return (names.sorted(), targets.sorted())
  }

}
