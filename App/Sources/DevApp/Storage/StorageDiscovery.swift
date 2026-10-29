//
//  StorageDiscovery.swift
//  Dev
//

import Foundation
import PlatformDiskUsage

/// Builds the list of items a scan measures. Each source adds what it finds;
/// an exact path is owned by the first source that names it, so a specific
/// rule (the Claude VM bundles, in AI) always wins over a generic sweep that
/// reaches the same folder later (the Claude app's support data, in Apps).
///
/// Nested items are allowed — `~/.hermes` and its `cache` are both listed —
/// and the scanner excludes the inner one from the outer one's size, so no
/// byte is counted twice.
nonisolated struct StorageDiscovery {
  let home: String
  let fileManager = FileManager.default
  private(set) var items: [StorageItem] = []
  private(set) var claimed: Set<String> = []
  /// ComfyUI installs already split into model items: the folder walk passes
  /// over them instead of finding their venv or loose models again.
  var comfyRoots: Set<String> = []
  /// True when the app has Full Disk Access: protected folders are scanned
  /// and apps' containers count as their support data.
  var fullDiskAccess = false
  /// What `addApps` found installed, so the Library sweep can tell a deleted
  /// app's leftovers from an installed app's data.
  var installedIdentifiers: Set<String> = []
  var installedNames: Set<String> = []

  init(home: String = NSHomeDirectory()) {
    self.home = home
  }

  /// `~/`-relative path → absolute path. Absolute input passes through.
  func h(_ relative: String) -> String {
    relative.hasPrefix("/") ? relative : home + "/" + relative
  }

  func exists(_ path: String) -> Bool { fileManager.fileExists(atPath: path) }

  func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  /// The visible entries of a folder, as absolute paths, or none.
  func children(of path: String) -> [String] {
    guard let names = try? fileManager.contentsOfDirectory(atPath: path) else { return [] }
    return names
      .filter { !$0.hasPrefix(".") && $0 != "Icon\r" }
      .sorted()
      .map { path + "/" + $0 }
  }

  /// The path with its folder's symlinks resolved, so `~/.swiftpm/swift-sdks`
  /// and the `~/Library/org.swift.swiftpm/swift-sdks` it points at are one
  /// item. The last component is kept as is: a symlink item is the link.
  func canonical(_ path: String) -> String {
    let parent = (path as NSString).deletingLastPathComponent
    let resolved = Self.realPath(parent)
    return resolved == parent ? path : resolved + "/" + (path as NSString).lastPathComponent
  }

  /// `realpath(3)`: unlike `NSString.resolvingSymlinksInPath` it keeps
  /// `/private` on `/private/tmp` and `/private/var`, the form `du` reports.
  static func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// True when this account can move `path`: write permission on its folder
  /// and, for a folder, on the folder itself (moving it rewrites its `..`).
  ///
  /// Read from ownership and mode bits, not `access(2)`: that also answers no
  /// for an app bundle macOS guards with App Management, which root does not
  /// get past either — that refusal is reported when the move fails.
  static func isMovable(_ path: String) -> Bool {
    FileAccess.isMovable(path)
  }

  /// True when `path` is exactly one of the items' paths.
  func isClaimed(_ path: String) -> Bool { claimed.contains(path) }

  /// True when `path` is an item or lies inside one.
  func isCovered(_ path: String) -> Bool {
    var current = path
    while current.count > 1 {
      if claimed.contains(current) { return true }
      current = (current as NSString).deletingLastPathComponent
    }
    return false
  }

  // MARK: Adding

  /// Adds an item whose paths exist and are not already someone else's.
  /// Tool-reported items (a simulator runtime) may have no paths on disk.
  mutating func add(_ item: StorageItem) {
    var item = item
    if !item.reportedSize {
      let original = item.paths.first
      item.paths = item.paths.map(canonical).filter(exists)
      guard let first = item.paths.first else { return }
      if item.id == original { item.id = first }
    }
    guard !item.paths.contains(where: claimed.contains) else { return }
    guard !items.contains(where: { $0.id == item.id }) else { return }
    switch item.cleanup {
    case .trash, .trashContents:
      item.needsAdmin = item.paths.contains { !Self.isMovable($0) }
    default:
      break
    }
    claimed.formUnion(item.paths)
    items.append(item)
  }

  /// One folder (or file) as one item.
  mutating func folder(
    _ category: StorageCategory, _ group: String, _ title: String, _ path: String,
    _ safety: StorageSafety, detail: String? = nil, cleanup: StorageCleanup = .trash,
    minBytes: Int64 = 1_000_000
  ) {
    let path = h(path)
    add(StorageItem(
      id: path, category: category, group: group, title: title, detail: detail,
      paths: [path], safety: safety, cleanup: cleanup, minBytes: minBytes))
  }

  /// Every visible child of a folder as its own item: one DerivedData folder
  /// per project, one Gradle distribution per version.
  mutating func eachChild(
    _ category: StorageCategory, _ group: String, of parent: String, _ safety: StorageSafety,
    detail: String? = nil, cleanup: StorageCleanup = .trash, minBytes: Int64 = 1_000_000,
    include: (String) -> Bool = { _ in true }, title: (String) -> String = { $0 }
  ) {
    for child in children(of: h(parent)) {
      let name = (child as NSString).lastPathComponent
      guard include(name) else { continue }
      add(StorageItem(
        id: child, category: category, group: group, title: title(name), detail: detail,
        paths: [child], safety: safety, cleanup: cleanup, minBytes: minBytes))
    }
  }
}

// MARK: - Title helpers

nonisolated enum StorageNames {
  /// `Dev-abcdefghijklmnopqrstuvwxyzab` → `Dev`: DerivedData's hash suffix.
  static func derivedData(_ name: String) -> String {
    guard let dash = name.lastIndex(of: "-") else { return name }
    let suffix = name[name.index(after: dash)...]
    return suffix.count >= 20 && suffix.allSatisfy(\.isLowercase) ? String(name[..<dash]) : name
  }

  /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `iOS 27.0`.
  static func simRuntime(_ identifier: String) -> String {
    let tail = identifier.components(separatedBy: "SimRuntime.").last ?? identifier
    var parts = tail.split(separator: "-").map(String.init)
    guard parts.count > 1 else { return tail }
    let platform = parts.removeFirst()
    return platform + " " + parts.joined(separator: ".")
  }

  static func relative(_ date: Date?) -> String? {
    guard let date else { return nil }
    return date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
  }

  /// The executable a tool installs under, or nil when it is not installed.
  static func tool(_ name: String, extra: [String] = []) -> String? {
    let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"] + extra
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
