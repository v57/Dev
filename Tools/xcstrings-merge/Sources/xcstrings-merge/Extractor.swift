import Foundation

/// Result of extracting localizable keys from one Swift target's sources.
struct ModuleResult {
  var targetName: String
  var moduleName: String
  var swiftFileCount: Int
  var keys: [String: Set<String>] = [:]
  var failed: Bool = false
  var detail: String = ""
  var skippedTableKeys: Int = 0
}

/// Result of processing one Swift package.
struct PackageResult {
  var packageRoot: URL
  var packageName: String
  var modules: [ModuleResult] = []
  var buildWarning: String = ""
  /// Unique keys across the package's modules (comment sets merged).
  var uniqueKeys: [String: Set<String>] = [:]

  var totalKeyCount: Int { uniqueKeys.count }
}

/// Search context for compiling one target's sources standalone.
struct ModuleSearchPaths {
  /// `-I` roots holding sibling `.swiftmodule` products.
  var includeDirs: [String]
  /// SwiftPM-generated `<Module>.modulemap` files for C/ObjC targets.
  var moduleMapFiles: [String]
}

/// Drives key extraction for one package: refreshes the build so sibling
/// module products exist, then compiles each target's sources once with
/// `-emit-localized-strings` and parses the emitted `.stringsdata`.
enum Extractor {
  /// Artifact/foreign directories never searched for module products.
  private static let moduleSkipComponents = [
    "checkouts", "SwiftExplicitPrecompiledModules",
    "Debug-iphonesimulator", "Release-iphonesimulator",
    "Debug-maccatalyst", "Release-maccatalyst",
  ]

  static let maxConcurrentCompiles = 4

  // MARK: - Package-level orchestration

  static func processPackage(
    _ packageRoot: URL,
    workDirectory: URL
  ) -> PackageResult {
    var result = PackageResult(packageRoot: packageRoot, packageName: packageRoot.lastPathComponent)

    // 1. Learn targets + module source paths.
    let manifest: PackageManifest
    do {
      manifest = try PackageDumper.dump(packageRoot: packageRoot)
    } catch {
      result.buildWarning = "dump-package failed: \(error)"
      return result
    }
    if let name = manifest.name, !name.isEmpty {
      result.packageName = name
    }

    // 2. Refresh the build so every sibling module's .swiftmodule is current.
    result.buildWarning = buildWarning(for: packageRoot)

    // 3. Module search paths (-I dirs + C module maps) from the .build tree.
    let searchPaths = moduleSearchPaths(packageRoot: packageRoot)

    // 4. Extract per target, in parallel (each compile is its own process).
    let targets = (manifest.targets ?? []).filter { !$0.isSkippable }
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = maxConcurrentCompiles
    queue.name = "xcstrings-merge.extract.\(result.packageName)"

    let lock = NSLock()
    var modules: [ModuleResult] = []

    for target in targets {
      queue.addOperation {
        let module = extractOne(
          target: target,
          packageRoot: packageRoot,
          searchPaths: searchPaths,
          workDirectory: workDirectory
        )
        lock.lock()
        modules.append(module)
        lock.unlock()
      }
    }
    queue.waitUntilAllOperationsAreFinished()

    result.modules = modules
      .filter { $0.swiftFileCount > 0 }
      .sorted { $0.moduleName < $1.moduleName }

    // 5. Union keys across the package's modules.
    for module in result.modules {
      for (key, comments) in module.keys {
        result.uniqueKeys[key, default: []].formUnion(comments)
      }
    }
    return result
  }

  // MARK: - Build refresh

  private static func buildWarning(for packageRoot: URL) -> String {
    let result = Shell.swift(
      ["build"],
      currentDirectory: packageRoot,
      timeout: 1800
    )
    if result.succeeded {
      return ""
    }
    let snippet = (result.stderr.isEmpty ? result.stdout : result.stderr)
      .split(separator: "\n")
      .filter { $0.contains("error:") }
      .prefix(3)
      .joined(separator: "\n")
    return "swift build failed (\(result.status)); extraction will use existing module products.\n\(snippet)"
  }

  // MARK: - Module product discovery

  /// Search paths that let target sources import sibling modules during a
  /// standalone compile:
  /// - include dirs: unique parent directories of `*.swiftmodule` files
  ///   under the package's `.build` tree (foreign slices — iOS simulator,
  ///   explicit precompiled system modules, dependency checkouts — excluded);
  /// - module maps: every `<Module>.modulemap` SwiftPM generated for the
  ///   package's C/ObjC targets, passed via `-fmodule-map-file` so
  ///   `import SomeC`-style imports resolve without a SwiftPM build context.
  static func moduleSearchPaths(packageRoot: URL) -> ModuleSearchPaths {
    let buildRoot = packageRoot.appendingPathComponent(".build")
    let enumerator = FileManager.default.enumerator(
      at: buildRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    var parents: Set<String> = []
    var moduleMaps: [String: String] = [:] // module name -> file path
    while let url = enumerator?.nextObject() as? URL {
      let path = url.path
      let components = path.split(separator: "/").map(String.init)
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
            moduleMaps[moduleName] = path
          }
        }
      default:
        break
      }
    }
    return ModuleSearchPaths(
      includeDirs: parents.sorted(),
      moduleMapFiles: moduleMaps.values.sorted()
    )
  }

  // MARK: - Per-target extraction

  private static func extractOne(
    target: TargetManifest,
    packageRoot: URL,
    searchPaths: ModuleSearchPaths,
    workDirectory: URL
  ) -> ModuleResult {
    var module = ModuleResult(
      targetName: target.name,
      moduleName: target.effectiveModuleName,
      swiftFileCount: 0
    )

    let files = targetSourceFiles(for: target, packageRoot: packageRoot)
    module.swiftFileCount = files.count
    guard !files.isEmpty else { return module }

    // Per-target scratch: emitted module + .stringsdata output directory.
    let moduleOut = workDirectory.appendingPathComponent("\(target.effectiveModuleName).swiftmodule")
    let stringsOut = workDirectory.appendingPathComponent("out-\(target.effectiveModuleName)")
    try? FileManager.default.createDirectory(at: stringsOut, withIntermediateDirectories: true)

    var baseArgs = [
      "-emit-module", "-emit-module-path", moduleOut.path,
      "-parse-as-library",
      "-module-name", target.effectiveModuleName,
    ]
    baseArgs += files.map { $0.path }
    baseArgs += [
      "-emit-localized-strings",
      "-emit-localized-strings-path", stringsOut.path,
    ]
    for dir in searchPaths.includeDirs {
      baseArgs += ["-I", dir]
    }
    for mapFile in searchPaths.moduleMapFiles {
      baseArgs += ["-Xcc", "-fmodule-map-file=\(mapFile)"]
    }

    var result = Shell.swiftc(baseArgs, currentDirectory: packageRoot, timeout: 600)
    if !result.succeeded {
      // Executables with a top-level main.swift fail under -parse-as-library;
      // retry in main-file semantics.
      let fallbackArgs = baseArgs.filter { $0 != "-parse-as-library" }
      let retry = Shell.swiftc(fallbackArgs, currentDirectory: packageRoot, timeout: 600)
      if retry.succeeded {
        result = retry
      } else {
        // SwiftPM synthesizes `Bundle.module` for targets that declare
        // resources; standalone swiftc does not. Retry with a typecheck-only
        // shim when that is the missing piece.
        let combined = retry.stderr + "\n" + retry.stdout
        if combined.contains("no member 'module'"), combined.contains("Bundle") {
          let shim = bundleModuleShim(in: workDirectory)
          let shimArgs = baseArgs + [shim.path]
          let shimRun = Shell.swiftc(shimArgs, currentDirectory: packageRoot, timeout: 600)
          if shimRun.succeeded {
            result = shimRun
          } else {
            module.failed = true
            module.detail = firstErrorLine(of: shimRun.stderr.isEmpty ? shimRun.stdout : shimRun.stderr)
          }
        } else {
          module.failed = true
          module.detail = firstErrorLine(of: retry.stderr.isEmpty ? retry.stdout : retry.stderr)
        }
      }
    }
    if result.timedOut {
      module.failed = true
      module.detail = "compile timed out"
    }

    let parsed = StringsData.parse(directory: stringsOut)
    module.keys = parsed.keys
    module.skippedTableKeys = parsed.skippedTableKeys
    return module
  }

  private static func firstErrorLine(of output: String) -> String {
    let lines = output.split(separator: "\n")
    // Skip generic driver summaries; prefer the first specific source error.
    for line in lines where line.contains("error:") {
      let text = String(line)
      let generic = text.contains("emit-module command failed")
        || text.contains("failed with a nonzero exit code")
        || text.contains("Command line")
      if !generic {
        return String(text.prefix(200))
      }
    }
    if let line = lines.first(where: { $0.contains("error:") }) {
      return String(line.prefix(200))
    }
    return "compile failed"
  }

  private static var bundleModuleShimURL: URL?

  /// Writes (once per run) a typecheck-only stand-in for the `Bundle.module`
  /// accessor SwiftPM synthesizes for resource-bearing targets.
  private static func bundleModuleShim(in workDirectory: URL) -> URL {
    if let existing = bundleModuleShimURL { return existing }
    let url = workDirectory.appendingPathComponent("BundleModuleShim.swift")
    let source = """
    import Foundation
    extension Bundle {
      static var module: Bundle { Bundle.main }
    }
    """
    try? source.write(to: url, atomically: true, encoding: .utf8)
    bundleModuleShimURL = url
    return url
  }

  // MARK: - Source file discovery

  /// The .swift sources belonging to a target: either the manifest's
  /// explicit `sources` list or a recursive walk of the target directory,
  /// honoring `exclude` and `resources`.
  static func targetSourceFiles(for target: TargetManifest, packageRoot: URL) -> [URL] {
    let targetDir: URL
    if let path = target.path, !path.isEmpty {
      targetDir = packageRoot.appendingPathComponent(path).standardizedFileURL
    } else {
      targetDir = packageRoot.appendingPathComponent("Sources/\(target.name)").standardizedFileURL
    }

    let excluded = excludedPaths(for: target, targetDir: targetDir)

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
      var stack: [URL] = [targetDir]
      while let directory = stack.popLast() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles]
        ) else {
          continue
        }
        for item in contents {
          let path = item.standardizedFileURL.path
          guard !isExcluded(path, excludedPaths: excluded) else { continue }
          let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
          if isDirectory {
            let isLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if !isLink {
              stack.append(item)
            }
          } else if item.pathExtension == "swift" {
            files.append(item)
          }
        }
      }
    }
    return files.sorted { $0.path < $1.path }
  }

  private static func excludedPaths(for target: TargetManifest, targetDir: URL) -> [String] {
    var paths: [String] = []
    for entry in (target.exclude ?? []) {
      paths.append(targetDir.appendingPathComponent(entry).standardizedFileURL.path)
    }
    for resource in (target.resources ?? []) {
      paths.append(targetDir.appendingPathComponent(resource.path).standardizedFileURL.path)
    }
    return paths
  }

  private static func isExcluded(_ path: String, excludedPaths: [String]) -> Bool {
    for excluded in excludedPaths where path == excluded || path.hasPrefix(excluded + "/") {
      return true
    }
    return false
  }
}
