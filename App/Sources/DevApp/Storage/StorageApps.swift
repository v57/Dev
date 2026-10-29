//
//  StorageApps.swift
//  Dev
//

import Foundation

/// The last two sources, run after every specific rule so they only pick up
/// what nothing else claimed: applications with the support data they leave in
/// the Library, and the generic sweep of caches, logs and app data.
nonisolated extension StorageDiscovery {
  // MARK: Apps

  /// One item per app: the bundle plus its folders in the Library, the way an
  /// uninstaller removes it. Apple's own apps are listed apart, as System
  /// Applications, and without Library folders: macOS manages those.
  mutating func addApps(excludingBundle running: String) {
    var bundles: [String] = []
    for folder in ["/Applications", h("Applications")] {
      for path in children(of: folder) {
        if path.hasSuffix(".app") {
          bundles.append(path)
        } else if isDirectory(path) {
          bundles += children(of: path).filter { $0.hasSuffix(".app") }
        }
      }
    }

    let groupContainers = fullDiskAccess ? children(of: h("Library/Group Containers")) : []
    for bundle in bundles where bundle != running {
      let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist") as? [String: Any] ?? [:]
      let identifier = info["CFBundleIdentifier"] as? String ?? ""
      let isApple = identifier.hasPrefix("com.apple.")
      let fileName = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
      if !identifier.isEmpty { installedIdentifiers.insert(identifier.lowercased()) }
      installedNames.insert(fileName.lowercased())
      if let name = info["CFBundleName"] as? String { installedNames.insert(name.lowercased()) }
      let names = Set([fileName, info["CFBundleName"] as? String].compactMap { $0 }.filter { !$0.isEmpty })
      let leftovers = isApple
        ? [] : appLeftovers(identifier: identifier, names: names, groupContainers: groupContainers)
      let version = info["CFBundleShortVersionString"] as? String
      let detail = [version.map { "Version \($0)" },
        leftovers.isEmpty ? nil : "\(leftovers.count) support folder\(leftovers.count == 1 ? "" : "s")"]
        .compactMap { $0 }.joined(separator: " · ")
      add(StorageItem(
        id: bundle, category: isApple ? .systemApps : .applications,
        group: bundle.hasPrefix(home) ? "In your Applications folder" : "Applications", title: fileName,
        detail: detail.isEmpty ? nil : detail, paths: [bundle] + leftovers, safety: .data,
        cleanup: .trash, minBytes: 5_000_000))
    }

    let steam = h("Library/Application Support/Steam")
    eachChild(.games, "Games", of: steam + "/steamapps/common", .data, detail: "Steam game")
    for cache in ["appcache", "depotcache", "logs"] {
      folder(.games, "Games", "Steam \(cache)", steam + "/" + cache, .cache)
    }
  }

  /// The folders an app keeps in the Library under its name or identifier.
  /// Its sandbox containers count only with Full Disk Access: without it,
  /// reading another app's container asks for permission, once per app.
  private func appLeftovers(identifier: String, names: Set<String>, groupContainers: [String]) -> [String] {
    var candidates: [String] = []
    let library = h("Library")
    let keys = (identifier.isEmpty ? [] : [identifier]) + names.sorted()
    for key in keys {
      candidates.append("\(library)/Application Support/\(key)")
      candidates.append("\(library)/Caches/\(key)")
      candidates.append("\(library)/Logs/\(key)")
    }
    if !identifier.isEmpty {
      candidates.append("\(library)/HTTPStorages/\(identifier)")
      candidates.append("\(library)/WebKit/\(identifier)")
      candidates.append("\(library)/Saved Application State/\(identifier).savedState")
      candidates.append("\(library)/Preferences/\(identifier).plist")
      if fullDiskAccess {
        candidates.append("\(library)/Containers/\(identifier)")
        candidates += groupContainers.filter { $0.hasSuffix("." + identifier) }
      }
    }
    var seen = Set<String>()
    return candidates.filter { path in
      seen.insert(path).inserted && exists(path) && !isClaimed(path) && !isCovered(path)
    }
  }

  // MARK: Caches & other

  /// Whatever is left in the Library's caches, logs and app support, plus
  /// iOS backups and the Trash. Apple's own folders are skipped: the system
  /// manages them and several are protected.
  mutating func addOther() {
    let library = h("Library")
    addLeftovers(in: library)
    func sweep(
      _ folder: String, _ category: StorageCategory, _ group: String, _ safety: StorageSafety,
      minBytes: Int64, detail: String
    ) {
      for path in children(of: "\(library)/\(folder)") where isDirectory(path) {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("com.apple."), !Self.systemFolders.contains(name), !isCovered(path) else {
          continue
        }
        add(StorageItem(
          id: path, category: Self.assistant(named: name) ?? category, group: group, title: name,
          detail: detail, paths: [path],
          safety: safety, cleanup: .trash, minBytes: minBytes))
      }
    }
    sweep("Caches", .caches, "App Caches", .cache, minBytes: 5_000_000, detail: "Cache")
    sweep("Logs", .caches, "Logs", .cache, minBytes: 5_000_000, detail: "Logs")
    sweep("Application Support", .appData, "App Data", .data, minBytes: 50_000_000,
      detail: "Application support data")

    eachChild(.appData, "iOS Backups", of: "Library/Application Support/MobileSync/Backup", .data,
      detail: "Device backup")
    folder(.trash, "Trash", "Trash", ".Trash", .data,
      cleanup: .revealOnly(reason: "Empty it from the Finder"))
  }

  /// Library folders named like an app's bundle identifier (`com.vendor.App`)
  /// when no installed app has that identifier or name: what a deleted app
  /// left behind. Caches are safe to clean; support data and containers are
  /// listed as your data, since a reinstalled app would read them again.
  mutating func addLeftovers(in library: String) {
    let places: [(String, StorageSafety)] = [
      ("Caches", .cache), ("Application Support", .data), ("Logs", .cache),
      ("HTTPStorages", .cache), ("WebKit", .cache), ("Saved Application State", .cache),
    ] + (fullDiskAccess ? [("Containers", .data)] : [])
    for (folder, safety) in places {
      for path in children(of: "\(library)/\(folder)") where isDirectory(path) {
        var name = (path as NSString).lastPathComponent
        if name.hasSuffix(".savedState") { name = (name as NSString).deletingPathExtension }
        guard isLeftover(name), !isCovered(path), !isClaimed(path) else { continue }
        let app = Self.appName(fromIdentifier: name)
        add(StorageItem(
          id: path, category: .leftovers, group: app, title: folder, detail: name, paths: [path],
          safety: safety, cleanup: .trash, minBytes: 1_000_000))
      }
    }
  }

  /// A reverse-DNS name no installed app answers to.
  func isLeftover(_ name: String) -> Bool {
    let lowered = name.lowercased()
    let parts = lowered.split(separator: ".")
    guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }), !lowered.hasPrefix("com.apple."),
          ["com", "org", "net", "io", "dev", "app", "co", "us", "de", "me"].contains(String(parts[0]))
    else { return false }
    if installedIdentifiers.contains(lowered) { return false }
    // An AI tool's folder belongs to the AI section, whatever its name.
    if Self.assistant(named: name) != nil { return false }
    // Names under a code host belong to libraries any app may use.
    if lowered.hasPrefix("com.github.") || lowered.hasPrefix("io.github.") { return false }
    // A vendor that still has an app here keeps its helpers and updaters
    // (`com.figma.agent` beside Figma, `com.google.GoogleUpdater` beside Chrome).
    let vendor = parts.prefix(2).joined(separator: ".")
    if installedIdentifiers.contains(where: { $0.hasPrefix(vendor + ".") }) { return false }
    if let last = parts.last.map(String.init) {
      if installedNames.contains(last) { return false }
      // A command-line tool that is still installed (`swiftformat`).
      if ["/opt/homebrew/bin/", "/usr/local/bin/"].contains(where: { fileManager.fileExists(atPath: $0 + last) }) {
        return false
      }
    }
    return true
  }

  /// `com.bohemiancoding.sketch3` → `Sketch3`.
  static func appName(fromIdentifier identifier: String) -> String {
    // The last component that names something: `com.duckduckgo.macos.browser`
    // is DuckDuckGo's, `com.gamemac.www` is gamemac's.
    let generic: Set<String> = ["www", "app", "macos", "mac", "osx", "browser", "desktop", "client", "helper"]
    let parts = identifier.split(separator: ".").map(String.init)
    let name = parts.dropFirst().last { !generic.contains($0.lowercased()) } ?? parts.last ?? identifier
    return name.prefix(1).uppercased() + name.dropFirst()
  }

  /// The AI category a Library folder belongs to by name (Codex's cache,
  /// the Claude CLI's), or nil for any other app.
  static func assistant(named name: String) -> StorageCategory? {
    let lowered = name.lowercased()
    if lowered.contains("claude") || lowered.contains("anthropic") { return .claude }
    if lowered.contains("codex") || lowered.contains("openai") { return .codex }
    if lowered.contains("hermes") { return .hermes }
    if lowered.contains("cursor") || lowered.contains("gemini") || lowered.contains("copilot") { return .aiTools }
    return nil
  }

  /// Library folders that belong to macOS rather than an app.
  static let systemFolders: Set<String> = [
    "AddressBook", "CallHistoryDB", "CallHistoryTransactions", "CloudDocs", "CrashReporter",
    "DiskImages", "Dock", "FileProvider", "iCloud", "Knowledge", "MobileSync", "Animoji",
    "networkserviceproxy", "familycircled", "icdd", "identityservicesd", "DiagnosticReports",
    "GeoServices", "SyncServices", "Mail",
  ]
}
