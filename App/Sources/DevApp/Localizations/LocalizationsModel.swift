//
//  LocalizationsModel.swift
//  Dev
//
//  The translations repository (`v57/Localizations`): one String Catalog per SOURCE — an app, or a kit whose strings
//  appear in apps — translated by Dev and compiled by the repository's own `Scripts/build`. Design: plans/
//  localizations-repo.md.
//
//  Everything here is pure (no UI, no main actor): which apps there are, what an app's build says it links and which
//  keys each linked module holds (`StringsDataScan`), which sources that makes (`LocalizationsPlan`), and how a
//  source's keys are merged into its catalog (`SourceCatalogMerge`).
//

import Foundation

// MARK: - Apps

/// An app whose strings go to the repository: built with its `-Local` workspace, so the kits it links are the
/// checkouts next to it.
nonisolated struct LocalizationsApp: Codable, Hashable, Sendable, Identifiable {
  /// The source name of the app's own strings ("Markdown"): its folder's name.
  var name: String
  /// The app's checkout.
  var folder: String
  /// The workspace (or project) the scan builds, relative to `folder`.
  var container: String
  /// The scheme the scan builds: the app's macOS target.
  var scheme: String
  /// Whether Scan and Translate All include it.
  var included = true
  /// Added by hand (Add App…): an app that isn't next to the repository, like Hub. Kept when the apps are re-read.
  var added: Bool?

  var id: String { name }
  var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }
}

nonisolated enum LocalizationsApps {
  /// Every app next to the repository: a folder holding `<Folder>-Local.xcworkspace` (each v57 app has one, over the
  /// sibling checkouts) and an application target named like the folder in `<Folder>.xcodeproj`.
  static func discover(near repo: URL) -> [LocalizationsApp] {
    let parent = repo.standardizedFileURL.deletingLastPathComponent()
    let folders = (try? FileManager.default.contentsOfDirectory(
      at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    return folders
      .filter { $0.lastPathComponent != repo.lastPathComponent }
      .compactMap { app(at: $0, requireFolderName: true) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// The app in `folder`: its `<Name>-Local.xcworkspace` (named like the folder, or — for an app added by hand, like
  /// Hub's `hub-app` — the only one there) and an application target in `<Name>.xcodeproj`, the one named like the
  /// app first. The source is named after the workspace.
  static func app(at folder: URL, requireFolderName: Bool = false) -> LocalizationsApp? {
    let manager = FileManager.default
    let suffix = "-Local.xcworkspace"
    var workspace = "\(folder.lastPathComponent)\(suffix)"
    if !manager.fileExists(atPath: folder.appendingPathComponent(workspace).path) {
      guard !requireFolderName,
        let only = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).filter({ $0.hasSuffix(suffix) })
          .sorted().first
      else { return nil }
      workspace = only
    }
    let name = String(workspace.dropLast(suffix.count))
    let project = folder.appendingPathComponent("\(name).xcodeproj/project.pbxproj")
    let targets = applicationTargets(pbxproj: (try? String(contentsOf: project, encoding: .utf8)) ?? "")
    guard let scheme = targets.first(where: { $0 == name }) ?? targets.first else { return nil }
    return LocalizationsApp(name: name, folder: folder.standardizedFileURL.path, container: workspace, scheme: scheme)
  }

  /// The names of a project's application targets, in file order.
  static func applicationTargets(pbxproj: String) -> [String] {
    var names: [String] = []
    var rest = pbxproj[...]
    while let start = rest.range(of: "isa = PBXNativeTarget;") {
      let after = rest[start.upperBound...]
      let end = after.range(of: "\n\t\t};")?.lowerBound ?? after.endIndex
      let block = after[..<end]
      rest = after[end...]
      guard block.contains("productType = \"com.apple.product-type.application\";") else { continue }
      guard let nameRange = block.range(of: #"\n\s*name = "?([^";]+)"?;"#, options: .regularExpression) else {
        continue
      }
      let line = block[nameRange]
      let value = line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
      names.append(value.trimmingCharacters(in: CharacterSet(charactersIn: " \";\n\t")))
    }
    return names
  }
}

// MARK: - What a build says

/// One module's keys, as an app's build extracted them.
nonisolated struct ModuleStrings: Codable, Hashable, Sendable {
  /// The module ("ComponentKit").
  var module: String
  /// The checkout its sources are in ("/…/v57/Component").
  var repo: String
  /// Key -> the comments the code gives it (empty when none).
  var keys: [String: [String]]
}

/// What one app's scan found: every module it links that holds keys, from v57's own checkouts.
nonisolated struct AppScan: Codable, Hashable, Sendable {
  var app: String
  var date: Date
  var modules: [ModuleStrings]
  var warnings: [String] = []
}

/// Reads the keys an Xcode build extracted (`SWIFT_EMIT_LOC_STRINGS=YES`, the compiler's `-emit-localized-strings`:
/// Xcode's own extraction, the same keys a String Catalog would get, `%lld`/`%@` included) from its derived data.
///
/// Which modules belong to the app is the app target's own link list (`<Target>.LinkFileList`): its object files and
/// one `<Module>.o` per package module it links. A module some other build left in the same derived data is not in it.
nonisolated enum StringsDataScan {
  static func read(derivedData: URL, app: LocalizationsApp, date: Date = Date()) -> AppScan {
    let intermediates = derivedData.appendingPathComponent("Build/Intermediates.noindex")
    var warnings: [String] = []
    let targetDirectories = buildDirectories(under: intermediates)
    let appDirectory = targetDirectories.first { $0.lastPathComponent == "\(app.scheme).build" }
    var linked: Set<String> = [moduleName(app.scheme)]
    if let appDirectory, let list = linkFileList(in: appDirectory),
      let text = try? String(contentsOf: list, encoding: .utf8)
    {
      for line in text.split(separator: "\n") where line.hasSuffix(".o") && line.contains("/Build/Products/") {
        linked.insert(String((line.split(separator: "/").last ?? "").dropLast(2)))
      }
    } else {
      warnings.append("No link list for \(app.scheme): every module in the build folder was read")
      linked = Set(targetDirectories.map { moduleName(directory: $0) })
    }
    let packages = derivedData.appendingPathComponent("SourcePackages").standardizedFileURL.path + "/"
    var modules: [ModuleStrings] = []
    var otherTables = 0
    for directory in targetDirectories {
      let module = directory == appDirectory ? moduleName(app.scheme) : moduleName(directory: directory)
      guard linked.contains(module) else { continue }
      var keys: [String: [String]] = [:]
      var repo: String?
      for file in stringsDataFiles(in: directory) {
        guard let data = try? Data(contentsOf: file),
          let document = try? JSONDecoder().decode(StringsData.self, from: data)
        else { continue }
        // A source that is gone, or newer than what the compiler last wrote for it, says nothing current.
        guard let source = document.source, let sourceDate = modified(URL(fileURLWithPath: source)) else { continue }
        if let written = modified(file), sourceDate > written { continue }
        if repo == nil { repo = checkout(of: URL(fileURLWithPath: source)) }
        for (table, entries) in document.tables ?? [:] {
          guard table == "Localizable" else {
            otherTables += entries.count
            continue
          }
          for entry in entries {
            let comment = entry.comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var comments = keys[entry.key] ?? []
            if !comment.isEmpty, !comments.contains(comment) { comments.append(comment) }
            keys[entry.key] = comments
          }
        }
      }
      // Only local checkouts are sources; a package Xcode fetched from GitHub ships its own strings.
      guard let repo, !keys.isEmpty, !(repo + "/").hasPrefix(packages), !repo.contains("/SourcePackages/checkouts/")
      else { continue }
      modules.append(ModuleStrings(module: module, repo: repo, keys: keys))
    }
    if otherTables > 0 { warnings.append("\(otherTables) key(s) in tables other than Localizable were left out") }
    return AppScan(app: app.name, date: date, modules: modules.sorted { $0.module < $1.module }, warnings: warnings)
  }

  /// `<Intermediates>/<Project>.build/<Configuration>/<Target>.build`, the macOS configuration's only.
  static func buildDirectories(under intermediates: URL) -> [URL] {
    let manager = FileManager.default
    var found: [URL] = []
    for project in (try? manager.contentsOfDirectory(at: intermediates, includingPropertiesForKeys: nil)) ?? []
    where project.pathExtension == "build" {
      for configuration in ["Debug", "Release"] {
        let folder = project.appendingPathComponent(configuration)
        for target in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where target.pathExtension == "build" {
          found.append(target)
        }
      }
    }
    return found.sorted { $0.path < $1.path }
  }

  /// The module a target folder builds: an Xcode target's folder is `<Target>.build`, a package target's
  /// `<Target>-t.build`.
  static func moduleName(directory: URL) -> String {
    var name = directory.deletingPathExtension().lastPathComponent
    if name.hasSuffix("-t") { name.removeLast(2) }
    return moduleName(name)
  }

  static func moduleName(_ target: String) -> String {
    target.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
  }

  private static func linkFileList(in target: URL) -> URL? {
    let objects = target.appendingPathComponent("Objects-normal")
    let manager = FileManager.default
    for arch in (try? manager.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil)) ?? [] {
      if let list = ((try? manager.contentsOfDirectory(at: arch, includingPropertiesForKeys: nil)) ?? [])
        .first(where: { $0.pathExtension == "LinkFileList" })
      {
        return list
      }
    }
    return nil
  }

  /// The target's `.stringsdata` files, one per source file (the first architecture folder that has any).
  private static func stringsDataFiles(in target: URL) -> [URL] {
    let objects = target.appendingPathComponent("Objects-normal")
    let manager = FileManager.default
    for arch in ((try? manager.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil)) ?? []).sorted(by: {
      $0.lastPathComponent < $1.lastPathComponent
    }) {
      let files = ((try? manager.contentsOfDirectory(at: arch, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "stringsdata" }
      if !files.isEmpty { return files.sorted { $0.path < $1.path } }
    }
    return []
  }

  private static func modified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }

  /// The git checkout holding `file`: the nearest folder above it with a `.git`.
  static func checkout(of file: URL) -> String {
    var folder = file.standardizedFileURL.deletingLastPathComponent()
    while folder.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return folder.path }
      folder.deleteLastPathComponent()
    }
    return file.deletingLastPathComponent().path
  }

  /// The compiler's `.stringsdata` document.
  struct StringsData: Decodable {
    var source: String?
    var tables: [String: [Entry]]?
    struct Entry: Decodable {
      var key: String
      var comment: String?
    }
  }
}

// MARK: - Sources

/// A source: one catalog in the repository.
nonisolated struct LocalizationsSource: Hashable, Sendable, Identifiable {
  enum Kind: String, Sendable { case app, kit }
  var name: String
  var kind: Kind
  /// The checkout its code is in.
  var repo: String
  /// The modules whose keys it holds.
  var modules: [String]
  /// The apps that look keys up in it.
  var usedBy: [String]
  /// Key -> the code's comments.
  var keys: [String: [String]]
  var id: String { name }
}

/// Which sources the scanned apps make, and the order each app looks them up in.
///
/// A module an app links from ANOTHER checkout next to the repository (`kitsFolder`, v57's) is a kit: it is its own
/// source, named after the module, and every app that links it shares it. Every other module (the app's checkout,
/// and checkouts elsewhere like Hub's own packages) belongs to the app's source. A key is in one
/// place per app: the app's source leaves out what the kits it links already hold, so a kit's string is translated
/// once. A module that one app links from another's checkout (Code's `CodeActionsUI` in Shell) is a kit for the app
/// it lives in too.
nonisolated struct LocalizationsPlan: Sendable {
  var sources: [LocalizationsSource]
  /// App -> its sources in lookup order: its own first, then its kits by name.
  var lookup: [String: [String]]

  init(apps: [LocalizationsApp], scans: [String: AppScan], kitsFolder: String? = nil) {
    let scanned = apps.filter(\.included).compactMap { app in scans[app.name].map { (app, $0) } }
    let appNames = Set(scanned.map(\.0.name))
    var kitModules: Set<String> = []
    for (app, scan) in scanned {
      for module in scan.modules where module.repo != app.folder {
        if let kitsFolder,
          URL(fileURLWithPath: module.repo).deletingLastPathComponent().standardizedFileURL.path != kitsFolder
        {
          continue
        }
        kitModules.insert(module.module)
      }
    }
    func kitName(_ module: String) -> String {
      appNames.contains(module) ? "\(module)Strings" : module
    }
    var kits: [String: LocalizationsSource] = [:]
    for (app, scan) in scanned {
      for module in scan.modules where kitModules.contains(module.module) {
        let name = kitName(module.module)
        var source =
          kits[name]
          ?? LocalizationsSource(
            name: name, kind: .kit, repo: module.repo, modules: [module.module], usedBy: [], keys: [:])
        if !source.usedBy.contains(app.name) { source.usedBy.append(app.name) }
        source.keys.merge(module.keys) { old, new in old + new.filter { !old.contains($0) } }
        kits[name] = source
      }
    }
    var sources: [LocalizationsSource] = []
    var lookup: [String: [String]] = [:]
    for (app, scan) in scanned {
      let linkedKits = scan.modules.filter { kitModules.contains($0.module) }.map { kitName($0.module) }
      let shared = Set(linkedKits.flatMap { kits[$0]?.keys.keys.map { $0 } ?? [] })
      var keys: [String: [String]] = [:]
      var modules: [String] = []
      for module in scan.modules where !kitModules.contains(module.module) {
        modules.append(module.module)
        for (key, comments) in module.keys where !shared.contains(key) {
          keys[key, default: []].append(contentsOf: comments.filter { !(keys[key] ?? []).contains($0) })
        }
      }
      if !keys.isEmpty {
        sources.append(
          LocalizationsSource(
            name: app.name, kind: .app, repo: app.folder, modules: modules, usedBy: [app.name], keys: keys))
      }
      lookup[app.name] = (keys.isEmpty ? [] : [app.name]) + Set(linkedKits).sorted()
    }
    for var kit in kits.values {
      kit.usedBy.sort()
      sources.append(kit)
    }
    self.sources = sources.sorted {
      $0.kind == $1.kind ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.kind == .app
    }
    self.lookup = lookup
  }
}

// MARK: - What a source is

/// What the model is told about a source, as `About:` lines of its translation project's rules: an app's own
/// description, or for a kit its description and the apps that show its strings, each with theirs. A source with
/// nothing to say gets no lines.
nonisolated enum LocalizationsAbout {
  static let prefix = "About: "

  static func lines(for source: String, in plan: LocalizationsPlan, descriptions: [String: String]) -> [String] {
    let own = descriptions[source] ?? ""
    guard let kit = plan.sources.first(where: { $0.name == source }), kit.kind == .kit else {
      return own.isEmpty ? [] : ["\(prefix)You are translating \(source), \(own)."]
    }
    var lines = [
      "\(prefix)You are translating \(source)" + (own.isEmpty ? "" : ", \(own)")
        + ". Its strings appear inside these apps, so keep them fitting for all of them:"
    ]
    for app in kit.usedBy {
      let text = descriptions[app] ?? ""
      lines.append("\(prefix)- \(app)" + (text.isEmpty ? "" : ": \(text)"))
    }
    return lines
  }
}

// MARK: - Merge

/// What a merge did to a catalog.
nonisolated struct SourceMergeCounts: Hashable, Sendable {
  var added = 0
  /// Stale keys the code has again.
  var revived = 0
  /// Keys the code no longer has, now `stale`.
  var staled = 0
  var commented = 0
  var total = 0
  var changed: Bool { added + revived + staled + commented > 0 }
}

/// A source's keys merged into its catalog, the way Xcode syncs a String Catalog: a new key comes in with the code's
/// comment and no translations; a key the code lost turns `stale` (translations kept); a stale key the code has again
/// comes back. Translations, states and every other field are left as they are. A key with no letters in it ("%lld",
/// "+%lld") is marked not to translate.
nonisolated enum SourceCatalogMerge {
  static func merge(
    _ existing: StringCatalog?, keys: [String: [String]], sourceLanguage: String = "en"
  ) -> (catalog: StringCatalog, counts: SourceMergeCounts) {
    var catalog = existing ?? StringCatalog(sourceLanguage: sourceLanguage, version: "1.0", strings: [:])
    var counts = SourceMergeCounts()
    for (key, comments) in keys {
      let comment = comments.isEmpty ? nil : comments.joined(separator: "\n")
      if var entry = catalog.strings[key] {
        if entry.extractionState == "stale" {
          entry.extractionState = nil
          counts.revived += 1
        }
        if let comment, entry.comment != comment {
          entry.comment = comment
          entry.isCommentAutoGenerated = nil
          counts.commented += 1
        }
        catalog.strings[key] = entry
      } else {
        var entry = StringCatalog.Entry()
        entry.comment = comment
        if !hasLetters(key) { entry.shouldTranslate = false }
        catalog.strings[key] = entry
        counts.added += 1
      }
    }
    for (key, var entry) in catalog.strings where keys[key] == nil {
      guard entry.extractionState != "stale", entry.extractionState != "manual" else { continue }
      entry.extractionState = "stale"
      catalog.strings[key] = entry
      counts.staled += 1
    }
    counts.total = catalog.strings.count
    return (catalog, counts)
  }

  static func hasLetters(_ key: String) -> Bool {
    // Format specifiers aren't words: "%lld" and "%@" are numbers and names filled in at run time.
    let stripped = key.replacingOccurrences(
      of: #"%(\d+\$)?[-+ #0]*\d*(\.\d+)?(hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA%]"#, with: "",
      options: .regularExpression)
    return stripped.unicodeScalars.contains { CharacterSet.letters.contains($0) }
  }
}

// MARK: - Progress

/// How far a source's catalog is translated.
nonisolated struct SourceProgress: Hashable, Sendable {
  /// Keys to translate: neither stale nor marked not to translate.
  var keys = 0
  var stale = 0
  /// Language -> keys with a value in it.
  var translated: [String: Int] = [:]
  /// Language -> of those, how many wait for a person's review (`needs_review`).
  var needsReview: [String: Int] = [:]

  init() {}

  init(_ catalog: StringCatalog) {
    for entry in catalog.strings.values {
      if entry.extractionState == "stale" {
        stale += 1
        continue
      }
      guard entry.shouldTranslate != false else { continue }
      keys += 1
      for (language, node) in entry.localizations ?? [:] where language != catalog.sourceLanguage {
        guard let state = Self.state(of: node) else { continue }
        translated[language, default: 0] += 1
        if state == "needs_review" { needsReview[language, default: 0] += 1 }
      }
    }
  }

  func fraction(_ language: String) -> Double {
    keys == 0 ? 0 : min(1, Double(translated[language] ?? 0) / Double(keys))
  }

  /// The node's state when it holds a value (a flat unit, or the `other` form of a plural), nil when it holds none.
  private static func state(of node: StringCatalog.Language) -> String? {
    if let unit = node.stringUnit, !(unit.value ?? "").isEmpty { return unit.state ?? "translated" }
    for case let forms? in [node.variations?["plural"], node.variations?["device"]] {
      if let unit = (forms["other"] ?? forms.values.first)?.stringUnit, !(unit.value ?? "").isEmpty {
        return unit.state ?? "translated"
      }
    }
    if let substitutions = node.substitutions, !substitutions.isEmpty { return "translated" }
    return nil
  }
}
