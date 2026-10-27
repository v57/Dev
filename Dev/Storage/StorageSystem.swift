//
//  StorageSystem.swift
//  Dev
//

import Foundation
import PlatformDiskUsage

// MARK: - Readable without the password

/// What sits outside the home folder but is still yours to read: temp folders,
/// macOS's downloaded assets, and the volumes the system keeps beside your data.
nonisolated extension StorageDiscovery {
  /// `/private/tmp` (agent scratch space lives here) and this account's own
  /// folder in `/private/var/folders` — its per-app caches (`C`) and temp
  /// files (`T`). macOS clears old temp files on its own; what is listed is
  /// what is still there.
  mutating func addTemporary() {
    let uid = FileAccess.userID
    // One item per session, so the ones still running can be told apart by
    // age from the ones long done.
    for project in children(of: "/private/tmp/claude-\(uid)") {
      let name = (project as NSString).lastPathComponent
      // Claude Code names a project's folder after its path, slashes as dashes.
      let homePrefix = "-Users-\(NSUserName())-"
      let title = name.hasPrefix(homePrefix)
        ? "~/" + name.dropFirst(homePrefix.count).replacingOccurrences(of: "-", with: "/")
        : name
      for session in children(of: project) {
        add(StorageItem(
          id: session, category: .claude, group: "Claude Code scratchpads", title: title,
          detail: "Session " + (session as NSString).lastPathComponent.prefix(8), paths: [session],
          safety: .cache, cleanup: .trash, minBytes: 10_000_000))
      }
    }
    // The sessions above are the scratch folder's items: the folder itself
    // is not one, or cleaning it would take every session, running or not.
    for path in children(of: "/private/tmp") where Self.isOwned(path, by: uid) && path != "/private/tmp/claude-\(uid)" {
      add(StorageItem(
        id: path, category: .caches, group: "Temporary Files",
        title: (path as NSString).lastPathComponent, detail: "/private/tmp", paths: [path],
        safety: .cache, cleanup: .trash, minBytes: 20_000_000))
    }

    let userTemp = Self.realPath((NSTemporaryDirectory() as NSString).deletingLastPathComponent)
    let known: [String: (StorageCategory, String, String)] = [
      "com.apple.dt.Instruments": (.xcode, "Xcode Caches", "Instruments cache"),
      "clang": (.xcode, "Xcode Caches", "Clang module cache"),
      "com.apple.dt.Xcode": (.xcode, "Xcode Caches", "Xcode temp cache"),
      "org.llvm.clang": (.xcode, "Xcode Caches", "Clang module cache (LLVM)"),
    ]
    for path in children(of: userTemp + "/C") {
      let name = (path as NSString).lastPathComponent
      let (category, group, title) = known[name] ?? (.caches, "App Caches", name)
      add(StorageItem(
        id: path, category: category, group: group, title: title,
        detail: "Per-app cache in /private/var/folders", paths: [path], safety: .cache,
        cleanup: .trash, minBytes: 20_000_000))
    }
    for path in children(of: userTemp + "/T") {
      add(StorageItem(
        id: path, category: .caches, group: "Temporary Files",
        title: (path as NSString).lastPathComponent, detail: "Your temp folder in /private/var/folders",
        paths: [path], safety: .cache, cleanup: .trash, minBytes: 20_000_000))
    }
  }

  static func isOwned(_ path: String, by uid: UInt32) -> Bool {
    FileAccess.owner(ofPath: path) == uid
  }

  /// macOS's own share: the assets it downloads (Siri, dictation, translation
  /// languages, Apple Intelligence, documentation), the volumes beside your
  /// Data volume, and the space it can purge by itself. None of it can be
  /// deleted by an app — macOS protects these even from root — so each says
  /// where it is turned off instead.
  mutating func addMacOS() {
    for path in children(of: "/System/Library/AssetsV2") where isDirectory(path) {
      let name = (path as NSString).lastPathComponent
      // The simulator runtime is already an item, removed through simctl.
      guard !name.contains("SimulatorRuntime") else { continue }
      let asset = Self.macOSAsset(name)
      add(StorageItem(
        id: path, category: asset.category, group: "macOS Assets", title: asset.title, detail: name,
        paths: [path], safety: .rebuildable, cleanup: .revealOnly(reason: asset.howTo),
        minBytes: 50_000_000))
    }

    for volume in Self.apfsVolumes() where volume.role != "Data" {
      add(StorageItem(
        id: "volume:" + volume.role, category: .system, group: "macOS Volumes", title: volume.title,
        detail: volume.detail, paths: [], safety: .data,
        cleanup: .revealOnly(reason: "A volume macOS manages; it is not files you can remove"),
        bytes: volume.bytes, reportedSize: true))
    }
  }

  /// Every volume in the Data volume's APFS container, Data included.
  static func apfsVolumes() -> [(role: String, title: String, detail: String, bytes: Int64)] {
    let result = ScanShell.run("/usr/sbin/diskutil", arguments: ["apfs", "list", "-plist"],
      currentDirectory: nil, timeout: 20)
    guard result.succeeded, let data = result.stdout.data(using: .utf8),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let containers = plist["Containers"] as? [[String: Any]]
    else { return [] }
    let titles = [
      "System": ("macOS system volume", "The sealed, read-only macOS install"),
      "Preboot": ("Preboot", "Boot files and Safari/OS cryptexes for each installed macOS"),
      "Recovery": ("Recovery", "macOS Recovery"),
      "VM": ("VM", "Swap and the sleep image"),
      "Update": ("Update", "Staged software updates"),
    ]
    for container in containers {
      let volumes = container["Volumes"] as? [[String: Any]] ?? []
      guard volumes.contains(where: { ($0["Roles"] as? [String])?.contains("Data") == true }) else { continue }
      return volumes.compactMap { volume in
        guard let role = (volume["Roles"] as? [String])?.first,
          let bytes = (volume["CapacityInUse"] as? NSNumber)?.int64Value
        else { return nil }
        let (title, detail) = titles[role] ?? (volume["Name"] as? String ?? role, "APFS volume")
        return (role, title, detail, bytes)
      }
    }
    return []
  }

  /// A readable name and where to turn it off, for a MobileAsset folder.
  /// A readable name, its category and where to turn it off, for a
  /// MobileAsset folder. The "UAF" assets (Apple's unified asset framework)
  /// are the on-device models behind Siri, Translation and Apple Intelligence.
  static func macOSAsset(_ folder: String) -> (title: String, category: StorageCategory, howTo: String) {
    let name = folder.replacingOccurrences(of: "com_apple_MobileAsset_", with: "")
    let intelligence = StorageCategory.appleIntelligence
    let rules: [(String, String, StorageCategory, String)] = [
      ("Translation", "Translation languages", intelligence,
        "System Settings › General › Language & Region › Translation Languages"),
      ("Siri_TextToSpeech", "Siri voices", intelligence, "System Settings › Siri › Voice — other voices download on demand"),
      ("TextToSpeech", "Spoken Content voices", intelligence,
        "System Settings › Accessibility › Spoken Content › System Voice › Manage Voices"),
      ("Siri", "Siri understanding models", intelligence, "Turning Siri off lets macOS remove them"),
      ("Speech", "Dictation and speech recognition", intelligence,
        "System Settings › Keyboard › Dictation — turning it off lets macOS remove them"),
      ("GenerativeModels", "Apple Intelligence models", intelligence,
        "System Settings › Apple Intelligence & Siri — turning it off lets macOS remove them"),
      ("FM_", "Apple Intelligence models", intelligence,
        "System Settings › Apple Intelligence & Siri — turning it off lets macOS remove them"),
      ("AppleDeveloperDocumentation", "Xcode documentation", .xcode, "Xcode › Settings › Components"),
      ("MetalToolchain", "Metal toolchain", .xcode, "Xcode › Settings › Components"),
      ("Font", "Downloadable fonts", .system, "Font Book — remove the downloaded fonts there"),
      ("Dictionary", "Dictionaries", .system, "Dictionary › Settings — untick the dictionaries you don't use"),
      ("MacSoftwareUpdate", "macOS update", .system, "Software Update removes it after installing"),
    ]
    for (key, title, category, howTo) in rules where name.contains(key) {
      return (title, category, howTo)
    }
    let title = name.replacingOccurrences(of: "UAF_", with: "").replacingOccurrences(of: "_", with: " ")
    return name.hasPrefix("UAF_")
      ? (title, intelligence, "Apple Intelligence & Siri settings — macOS downloads and removes it")
      : (title, .system, "Downloaded and removed by macOS")
  }
}

// MARK: - The password scan

/// The scan behind the administrator prompt: one `du` of the whole Data
/// volume as root, read for what only root can see (system logs, system
/// caches, other accounts) and for what is left once every item is counted —
/// so nothing on the disk is unexplained.
nonisolated enum StorageSystemScan {
  enum Failure: LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
      switch self {
      case .cancelled: "The password prompt was cancelled."
      case .failed(let message): message
      }
    }
  }

  static let dataRoot = "/System/Volumes/Data"

  /// Runs the root scan and turns it into items. `known` are the items the
  /// normal scan found: their bytes are subtracted so the leftovers are only
  /// what nothing explains.
  /// Root measures everything outside your home folder; Dev measures the home
  /// folder itself, at the same time. Root does not get Dev's Full Disk
  /// Access — privacy protection applies to root too — so a root `du` of the
  /// home folder silently misses Downloads, Desktop, Documents and the
  /// protected Library folders.
  static func run(
    known: [StorageItem], homeProgress: @escaping @Sendable (Int64?) -> Void = { _ in }
  ) async throws -> [StorageItem] {
    let home = NSHomeDirectory()
    let homeScan = Task.detached(priority: .utility) {
      let sizes = DiskUsage.directorySizes(of: home, maxDepth: 5, minBytes: 10_000_000, progress: homeProgress)
      homeProgress(nil)  // done
      return sizes
    }
    let output: String
    do {
      output = try await Task.detached(priority: .utility) { try runAsRoot(script(skipping: home)) }.value
    } catch {
      homeScan.cancel()
      throw error
    }
    let homeSizes = await homeScan.value
    return try items(fromOutput: output, home: home, homeSizes: homeSizes, known: known)
  }

  /// `du` of every top-level folder of the Data volume and of the other
  /// accounts' homes — not yours — with errors kept, so the folders macOS
  /// refused are named instead of silently missing.
  static func script(skipping home: String) -> String {
    """
      cd / || exit 1
      D='\(dataRoot)'
      ME=\(quoted(dataRoot + home))
      for p in "$D"/* "$D"/.[!.]*; do
        [ -e "$p" ] || continue
        if [ "$p" = "$D/Users" ]; then
          for u in "$p"/* "$p"/.[!.]*; do
            [ -e "$u" ] && [ "$u" != "$ME" ] && /usr/bin/du -kx -d 3 "$u" 2>&1
          done
        else
          /usr/bin/du -kx -d 4 "$p" 2>&1
        fi
      done | /usr/bin/awk -F'\\t' '($1 ~ /^[0-9]+$/ && $1 >= 10240) || /^du: /'
      for d in /private/var/folders/*/*; do printf 'OWNER\\t%s\\t%s\\n' "$(/usr/bin/stat -f %Su "$d")" "$d"; done
      """
  }

  /// Turns the root script's output and the home folder's sizes into items:
  /// separate from running them so the parsing can be checked without root.
  static func items(
    fromOutput output: String, home: String, homeSizes: (sizes: [String: Int64], denied: [String]),
    known: [StorageItem]
  ) throws -> [StorageItem] {
    var sizes: [String: Int64] = [:]
    var owners: [String: String] = [:]
    var denied = homeSizes.denied
    for line in output.split(separator: "\n") {
      let text = String(line)
      if text.hasPrefix("du: ") {
        if text.hasSuffix("Operation not permitted") || text.hasSuffix("Permission denied"),
          let colon = text.dropFirst(4).range(of: ": ", options: .backwards) {
          denied.append(normalize(String(text.dropFirst(4)[..<colon.lowerBound])))
        }
        continue
      }
      let fields = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      if fields.count == 3, fields[0] == "OWNER" {
        owners[fields[2]] = fields[1]
      } else if fields.count == 2, let kilobytes = Int64(fields[0]) {
        sizes[normalize(fields[1])] = kilobytes * 1024
      }
    }
    sizes.merge(homeSizes.sizes) { root, _ in root }
    guard let homeTotal = homeSizes.sizes[home], homeTotal > 0 else {
      throw Failure.failed("Couldn't measure your home folder")
    }

    // The tree's two top nodes, which the split runs never print themselves.
    let topLevel = sizes.filter { $0.key.split(separator: "/").count == 1 && $0.key != "/Users" }
    let accounts = sizes.filter { ($0.key as NSString).deletingLastPathComponent == "/Users" }
    sizes["/Users"] = accounts.values.reduce(0, +)
    let total = topLevel.values.reduce(0, +) + sizes["/Users"]!
    sizes["/"] = total

    var items = rootOnlyItems(sizes: sizes, owners: owners)
    items += unexplained(sizes: sizes, covered: known + items)

    // What APFS says the Data volume holds beyond every file that was read.
    // Folders nobody could read land here too, so they are named beside it.
    let unreadable = Array(Set(denied)).sorted()
    if let data = StorageDiscovery.apfsVolumes().first(where: { $0.role == "Data" }),
      data.bytes - total >= 1_000_000_000 {
      items.append(StorageItem(
        id: "system:invisible", category: .system, group: "Not in Any Category",
        title: unreadable.isEmpty ? "Not visible as files" : "Not visible as files, or unreadable",
        detail: unreadable.isEmpty
          ? "APFS snapshots, purgeable copies and file-system metadata"
          : "Snapshots, metadata, and \(unreadable.count) folder\(unreadable.count == 1 ? "" : "s") macOS wouldn't let the scan read",
        paths: [], safety: .data,
        cleanup: .revealOnly(reason: unreadable.isEmpty
          ? "Check snapshots with: tmutil listlocalsnapshots /"
          : "Unreadable: " + unreadable.prefix(6).map(\.abbreviatingHome).joined(separator: ", ")
            + (unreadable.count > 6 ? " …" : "")),
        bytes: data.bytes - total, reportedSize: true))
    }
    return items
  }

  /// `/System/Volumes/Data/Users/x` → `/Users/x`: the paths the rest of the
  /// app uses, through the firmlinks.
  static func normalize(_ path: String) -> String {
    guard path.hasPrefix(dataRoot) else { return path }
    let rest = String(path.dropFirst(dataRoot.count))
    return rest.isEmpty ? "/" : rest
  }

  // MARK: Known root-only places

  private static func rootOnlyItems(sizes: [String: Int64], owners: [String: String]) -> [StorageItem] {
    var items: [StorageItem] = []
    func item(
      _ path: String, _ group: String, _ title: String, _ safety: StorageSafety,
      category: StorageCategory = .system, detail: String? = nil,
      cleanup: StorageCleanup, minBytes: Int64 = 20_000_000
    ) {
      guard let bytes = sizes[path], bytes >= minBytes else { return }
      items.append(StorageItem(
        id: "system:" + path, category: category, group: group, title: title, detail: detail ?? path,
        paths: [path], safety: safety, cleanup: cleanup, minBytes: minBytes, bytes: bytes,
        reportedSize: true, needsAdmin: true))
    }
    func children(of parent: String) -> [String] {
      sizes.keys.filter { ($0 as NSString).deletingLastPathComponent == parent }.sorted()
    }

    item("/private/var/db/diagnostics", "System Logs", "Unified system log", .cache,
      detail: "What Console shows — macOS starts a fresh log",
      cleanup: .adminCommand(script: "/usr/bin/log erase --all", verb: "Erase logs"))
    item("/private/var/db/uuidtext", "System Logs", "Log symbol files", .cache,
      cleanup: .revealOnly(reason: "The unified log needs these to read its entries"))
    item("/private/var/db/powerlog", "System Logs", "Power log", .cache,
      detail: "Battery and energy history", cleanup: .trash)
    item("/private/var/log", "System Logs", "BSD logs", .cache,
      detail: "Rotated logs in /private/var/log",
      cleanup: .adminCommand(
        script: "/usr/bin/find /private/var/log -type f \\( -name '*.gz' -o -name '*.bz2' -o -name '*.[0-9]' \\) -delete",
        verb: "Delete rotated logs"))
    item("/private/var/vm", "Swap", "Swap and sleep image", .cache,
      cleanup: .revealOnly(reason: "macOS manages swap; quitting memory-heavy apps or restarting shrinks it"))
    item("/Library/Developer/CommandLineTools", "Command Line Tools", "Command Line Tools", .rebuildable,
      category: .xcode, detail: "Reinstall with xcode-select --install", cleanup: .trash)
    item("/Library/Updates", "Developer", "Staged updates", .rebuildable,
      cleanup: .revealOnly(reason: "Software Update manages it"))

    for (folder, group, safety) in [
      ("/Library/Caches", "System Caches", StorageSafety.cache),
      ("/Library/Logs", "System Logs", .cache),
      ("/Library/Application Support", "System App Data", .data),
      ("/Library/Java/JavaVirtualMachines", "JDKs", .rebuildable),
      ("/Library/Audio", "System App Data", .data),
    ] {
      for path in children(of: folder) {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("com.apple."), name != "Apple" else { continue }
        item(path, group, name, safety, category: group == "JDKs" ? .android : .system, cleanup: .trash,
          minBytes: safety == .data ? 50_000_000 : 10_000_000)
      }
    }

    // Other accounts and system services: their temp folders and homes.
    let me = NSUserName()
    for (path, owner) in owners where owner != me {
      item(path, "Other Accounts", owner.hasPrefix("_") ? "\(owner) (system service)" : owner,
        .cache, detail: "Temporary files in /private/var/folders",
        cleanup: .revealOnly(reason: "macOS clears these at restart; deleting them while services run can break them"),
        minBytes: 50_000_000)
    }
    for path in children(of: "/Users") where path != "/Users/\(me)" {
      let name = (path as NSString).lastPathComponent
      item(path, "Other Accounts", name == "Shared" ? "Shared folder" : "\(name)'s home folder", .data,
        cleanup: .revealOnly(reason: name == "Shared" ? "Files every account can see" : "Another account on this Mac"),
        minBytes: 100_000_000)
    }
    return items
  }

  // MARK: Leftovers

  /// The folders whose size nothing else explains, at least 1 GB each,
  /// reported at the deepest level that is still that large: the last
  /// answer to "what is the rest of my disk?".
  private static func unexplained(sizes: [String: Int64], covered: [StorageItem]) -> [StorageItem] {
    // An item's bytes count against the folders that hold its main path.
    // Items with no path (a volume, purgeable space) are not on this volume.
    // An app's support folders are paths of their own: each takes its `du`
    // size off its own folders, and the main path takes the rest.
    var coveredBelow: [String: Int64] = [:]
    var itemPaths = Set<String>()
    func attribute(_ bytes: Int64, to start: String) {
      var path = start
      while true {
        coveredBelow[path, default: 0] += bytes
        if path == "/" { break }
        path = (path as NSString).deletingLastPathComponent
      }
    }
    for item in covered {
      let paths = item.paths.filter { $0.hasPrefix("/") }
      guard let primary = paths.first else { continue }
      itemPaths.formUnion(paths)
      var rest = item.bytes
      for path in paths.dropFirst() {
        let bytes = min(sizes[path] ?? 0, rest)
        attribute(bytes, to: path)
        rest -= bytes
      }
      attribute(max(rest, 0), to: primary)
    }
    /// Anything inside an item is that item's, whatever `du` says.
    func isInsideItem(_ path: String) -> Bool {
      var current = path
      while current != "/" {
        if itemPaths.contains(current) { return true }
        current = (current as NSString).deletingLastPathComponent
      }
      return false
    }
    func uncovered(_ path: String) -> Int64 {
      isInsideItem(path) ? 0 : (sizes[path] ?? 0) - (coveredBelow[path] ?? 0)
    }

    var childrenOf: [String: [String]] = [:]
    for path in sizes.keys where path != "/" {
      childrenOf[(path as NSString).deletingLastPathComponent, default: []].append(path)
    }

    let threshold: Int64 = 1_000_000_000
    var found: [StorageItem] = []
    /// Reports `path` or, where its excess sits in large children, those
    /// children and whatever is left over in `path` itself.
    func visit(_ path: String) {
      let own = uncovered(path)
      guard own >= threshold else { return }
      let large = (childrenOf[path] ?? []).filter { uncovered($0) >= threshold }
      if large.isEmpty {
        found.append(leftover(path, bytes: own, rest: false))
        return
      }
      large.forEach(visit)
      let rest = own - large.reduce(0) { $0 + uncovered($1) }
      if rest >= threshold { found.append(leftover(path, bytes: rest, rest: true)) }
    }
    visit("/")
    return found
  }

  private static func leftover(_ path: String, bytes: Int64, rest: Bool) -> StorageItem {
    let name = path == "/" ? "Data volume" : (path as NSString).lastPathComponent
    return StorageItem(
      id: "system:unexplained:" + path, category: .system, group: "Not in Any Category",
      title: rest ? "\(name) — everything else" : name,
      detail: path.abbreviatingHome, paths: path == "/" ? [] : [path], safety: .data,
      cleanup: .revealOnly(reason: "Not recognised — look before removing anything here"),
      bytes: bytes, reportedSize: true, needsAdmin: true)
  }

  // MARK: Root

  /// Runs `script` as root through the standard administrator prompt.
  /// macOS remembers the password for a few minutes, so a scan and a clean
  /// right after it share one prompt.
  static func runAsRoot(_ script: String, timeout: TimeInterval = 900) throws -> String {
    let escaped = script
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
    let result = ScanShell.run("/usr/bin/osascript", arguments: ["-e", appleScript],
      currentDirectory: nil, timeout: timeout)
    if result.stderr.contains("-128") { throw Failure.cancelled }
    guard result.succeeded else {
      let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw Failure.failed(message.isEmpty ? "exit status \(result.status)" : message)
    }
    // `do shell script` hands back carriage returns for line breaks.
    return result.stdout.replacingOccurrences(of: "\r", with: "\n")
  }

  /// `'path'` for a shell script, whatever the path holds.
  static func quoted(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
