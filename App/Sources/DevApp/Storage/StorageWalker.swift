//
//  StorageWalker.swift
//  Dev
//

import Foundation
import PlatformDiskUsage

/// One pass over the folders you work in, picking out what lives inside
/// projects and downloads rather than in a tool's fixed location: build
/// outputs and dependencies, VM bundles, disk images, installers, media, model
/// files and database data directories.
///
/// The walk prunes every match (a `node_modules` is one item, not ten thousand
/// files) and every path an earlier rule already owns, so it reads the project
/// trees once and never the bulk it found.
nonisolated extension StorageDiscovery {
  /// The folders walked by default: every visible folder in the home folder
  /// except Library and Applications, which the rules and the app sweep read.
  /// Symlinks are left out: the walk is physical and reports them as files.
  var defaultWalkRoots: [String] {
    children(of: home).filter { path in
      let name = (path as NSString).lastPathComponent
      let isLink = (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
      return !isLink && isDirectory(path) && !["Library", "Applications"].contains(name)
    }
  }

  mutating func walk(roots: [String]) {
    var found = WalkFindings()
    let skipped = claimed.union(comfyRoots)
    let rootSet = Set(roots)
    // The folders of the current branch, two levels below the root, and the
    // bytes no item takes under each: what "Other Files" reports.
    var branch: [String] = []
    var leftover: [String: Int64] = [:]

    DiskUsage.walk(roots) { entry in
      let name = entry.name
      if entry.isDirectory {
        let level = entry.level
        guard level > 0 else {
          if skipped.contains(entry.path) { return .skip }
          branch = [entry.path]
          leftover[entry.path, default: 0] += entry.allocatedBytes
          return .descend
        }
        if name.first == "." && Self.skippedHiddenFolders.contains(name) { return .skip }
        let path = entry.path
        if skipped.contains(path) { return .skip }
        // Bundles are opaque: their insides are never separate items.
        if Self.opaqueExtensions.contains((name as NSString).pathExtension.lowercased()) { return .skip }
        if let match = classifyFolder(name: name, path: path) {
          found.items.append(match)
          return .skip
        }
        if name.lowercased().hasPrefix("comfyui"), isDirectory(path + "/models"),
          exists(path + "/main.py") || isDirectory(path + "/comfy") {
          found.comfyUI.append(path)
          return .skip
        }
        if level <= 2 {
          branch.removeSubrange(min(level, branch.count)...)
          branch.append(path)
        }
        leftover[branch[min(level, 2)], default: 0] += entry.allocatedBytes
        return .descend
      }
      // A root that is not a folder (a file, or a symlink the walk won't follow).
      guard entry.level > 0, !branch.isEmpty else { return .descend }
      let bucket = branch[min(entry.level - 1, 2, branch.count - 1)]

      // Files: database markers at any size, everything else only when large.
      if let engine = Self.databaseMarkers[name] {
        found.databases[(entry.path as NSString).deletingLastPathComponent] = engine
        return .descend
      }
      let ext = (name as NSString).pathExtension.lowercased()
      if entry.logicalBytes >= Self.largeFile, let kind = Self.fileKinds[ext] {
        found.files.append(LargeFile(path: entry.path, kind: kind))
      } else {
        leftover[bucket, default: 0] += entry.allocatedBytes
      }
      return .descend
    }

    for root in found.comfyUI { addComfyUI(at: root) }
    for item in Self.outermost(found.items) { add(item) }
    for (path, engine) in found.databases.sorted(by: { $0.key < $1.key })
    where !found.databases.keys.contains(where: { $0 != path && path.isInside($0) }) {
      add(StorageItem(
        id: path, category: .databases, group: "Data directories",
        title: (path as NSString).lastPathComponent, detail: "\(engine) · \(path.abbreviatingHome)",
        paths: [path], safety: .data, cleanup: .trash))
    }
    addLargeFiles(found.files, roots: rootSet)
    addOtherFiles(leftover, roots: roots)
  }

  // MARK: Other files

  /// Lists the folders whose files fit no category, two levels deep: a
  /// project folder of its own when it is large, otherwise rolled up into its
  /// parent, and what is left at the top as "everything else". The walk's
  /// totals only pick which folders to list; each is measured like any item,
  /// minus the items inside it, and keeps its row only if that is still large.
  private mutating func addOtherFiles(_ leftover: [String: Int64], roots: [String]) {
    let threshold: Int64 = 300_000_000
    var rolled = leftover
    var listed = Set<String>()
    func level(_ path: String) -> Int {
      guard let root = roots.first(where: { path.isInside($0) }) else { return 0 }
      return path.dropFirst(root.count).split(separator: "/").count
    }
    for depth in [2, 1, 0] {
      for (path, bytes) in rolled where level(path) == depth {
        if bytes >= threshold {
          listed.insert(path)
        } else if depth > 0 {
          rolled[(path as NSString).deletingLastPathComponent, default: 0] += bytes
        }
      }
    }
    for path in listed.sorted() {
      let depth = level(path)
      let root = roots.first { path.isInside($0) } ?? path
      let rootName = (root as NSString).lastPathComponent
      let hasListedChildren = listed.contains { $0 != path && $0.isInside(path) }
      let relative = String(path.dropFirst(root.count + 1))
      let title = depth == 0
        ? "Everything else in \(rootName)"
        : hasListedChildren ? "\(relative) — everything else" : relative
      add(StorageItem(
        id: path, category: .files, group: rootName, title: title, detail: path.abbreviatingHome,
        paths: [path], safety: .data, cleanup: .trash, minBytes: threshold))
    }
  }

  // MARK: Folders

  /// What a folder is, judged by its name and, where the name is generic
  /// (`build`, `target`, `venv`), by the file beside it that says whose it is.
  private func classifyFolder(name: String, path: String) -> StorageItem? {
    let parent = (path as NSString).deletingLastPathComponent
    let project = (parent as NSString).lastPathComponent
    func item(
      _ category: StorageCategory, _ group: String, _ safety: StorageSafety = .rebuildable,
      title: String? = nil, detail: String? = nil, minBytes: Int64 = 1_000_000
    ) -> StorageItem {
      StorageItem(
        id: path, category: category, group: group, title: title ?? project,
        detail: detail ?? path.abbreviatingHome, paths: [path], safety: safety, cleanup: .trash,
        minBytes: minBytes)
    }

    switch name {
    case "node_modules":
      return item(.javascript, "Project node_modules")
    case ".next", ".nuxt", ".turbo", ".svelte-kit", ".parcel-cache", ".angular", ".expo", ".vite":
      return item(.javascript, "Project Build Outputs", title: "\(project)/\(name)")
    case ".build", ".build-android", "DerivedData":
      return item(.xcode, "Project Builds", title: "\(project)/\(name)")
    case "Pods" where exists(parent + "/Podfile"):
      return item(.xcode, "Project Builds", title: "\(project)/Pods")
    case ".gradle", ".cxx", ".externalNativeBuild", ".kotlin":
      return item(.android, "Project Builds", title: "\(project)/\(name)")
    case "build" where exists(parent + "/build.gradle") || exists(parent + "/build.gradle.kts"):
      return item(.android, "Project Builds", title: "\(project)/build")
    case "target" where exists(parent + "/Cargo.toml"):
      return item(.languages, "Rust", title: "\(project)/target")
    case ".dart_tool":
      return item(.languages, "Dart & Flutter", title: "\(project)/.dart_tool")
    case "bundle" where (parent as NSString).lastPathComponent == "vendor"
      && exists((parent as NSString).deletingLastPathComponent + "/Gemfile"):
      let app = ((parent as NSString).deletingLastPathComponent as NSString).lastPathComponent
      return item(.languages, "Ruby", title: "\(app)/vendor/bundle")
    case "vendor" where exists(parent + "/composer.json"):
      return item(.languages, "PHP", title: "\(project)/vendor")
    // One pattern per case: a `where` binds only to the pattern before it.
    case "deps" where exists(parent + "/mix.exs"):
      return item(.languages, "Elixir", title: "\(project)/deps")
    case "_build" where exists(parent + "/mix.exs"):
      return item(.languages, "Elixir", title: "\(project)/_build")
    case "__pycache__", ".git", ".hg", ".svn":
      return nil
    default:
      break
    }

    if exists(path + "/pyvenv.cfg") {
      return item(.python, "Virtual Environments", title: "\(project)/\(name)")
    }
    switch (name as NSString).pathExtension.lowercased() {
    case "utm":
      return item(.virtualMachines, "UTM", .data,
        title: (name as NSString).deletingPathExtension, detail: "UTM · \(path.abbreviatingHome)")
    case "pvm":
      return item(.virtualMachines, "Parallels", .data,
        title: (name as NSString).deletingPathExtension, detail: "Parallels · \(path.abbreviatingHome)")
    case "vmwarevm":
      return item(.virtualMachines, "VMware", .data,
        title: (name as NSString).deletingPathExtension, detail: "VMware · \(path.abbreviatingHome)")
    case "photoslibrary":
      return StorageItem(
        id: path, category: .media, group: "Libraries", title: name, detail: path.abbreviatingHome,
        paths: [path], safety: .data, cleanup: .revealOnly(reason: "Manage it from Photos"))
    case "fcpbundle", "imovielibrary", "tvlibrary", "musiclibrary":
      return StorageItem(
        id: path, category: .media, group: "Libraries", title: name, detail: path.abbreviatingHome,
        paths: [path], safety: .data, cleanup: .revealOnly(reason: "Manage it from its app"))
    default:
      return nil
    }
  }

  /// Keeps the outermost of nested finds (a `node_modules` inside a `.build`
  /// checkout belongs to the `.build`).
  private static func outermost(_ items: [StorageItem]) -> [StorageItem] {
    let sorted = items.sorted { $0.primaryPath < $1.primaryPath }
    var kept: [StorageItem] = []
    for item in sorted {
      if let last = kept.last, item.primaryPath.isInside(last.primaryPath) { continue }
      kept.append(item)
    }
    return kept
  }

  // MARK: Large files

  /// Large files by kind. Media that sits three or more to a folder becomes
  /// the folder (a season of a show is one thing to keep or remove), and
  /// sibling folders collapse into their parent the same way.
  private mutating func addLargeFiles(_ files: [LargeFile], roots: Set<String>) {
    var media: [LargeFile] = []
    for file in files {
      let path = file.path
      let name = (path as NSString).lastPathComponent
      let title = (name as NSString).deletingPathExtension
      let detail = (path as NSString).deletingLastPathComponent.abbreviatingHome
      switch file.kind {
      case .video, .audio, .image:
        media.append(file)
      case .diskImage(let reDownloadable):
        add(StorageItem(
          id: path, category: .virtualMachines, group: "Disk Images", title: name, detail: detail,
          paths: [path], safety: reDownloadable ? .rebuildable : .data, cleanup: .trash))
      case .installer:
        add(StorageItem(
          id: path, category: .installers, group: "Installers & Archives", title: name, detail: detail,
          paths: [path], safety: .rebuildable, cleanup: .trash))
      case .archive:
        add(StorageItem(
          id: path, category: .installers, group: "Installers & Archives", title: name, detail: detail,
          paths: [path], safety: .data, cleanup: .trash))
      case .database:
        add(StorageItem(
          id: path, category: .databases, group: "Database Files", title: name, detail: detail,
          paths: [path], safety: .data, cleanup: .trash))
      case .model:
        add(StorageItem(
          id: path, category: .aiModels, group: "Model Files", title: title,
          detail: "\((name as NSString).pathExtension.uppercased()) · \(detail)",
          paths: [path], safety: .data, cleanup: .trash))
      }
    }

    // Folder → its media files, then collapse upward.
    var byFolder: [String: [LargeFile]] = [:]
    for file in media {
      byFolder[(file.path as NSString).deletingLastPathComponent, default: []].append(file)
    }
    var folders = Set(byFolder.filter { !roots.contains($0.key) && $0.value.count >= 3 }.keys)
    var changed = true
    while changed {
      changed = false
      var parents: [String: Int] = [:]
      for folder in folders { parents[(folder as NSString).deletingLastPathComponent, default: 0] += 1 }
      for (parent, count) in parents where count >= 2 && !roots.contains(parent) && parent != home {
        folders = folders.filter { ($0 as NSString).deletingLastPathComponent != parent }
        folders.insert(parent)
        changed = true
      }
    }

    for folder in folders.sorted() {
      let inside = media.filter { $0.path.isInside(folder) }
      let kind = Dictionary(grouping: inside, by: \.kind).max { $0.value.count < $1.value.count }?.key
        ?? .video
      add(StorageItem(
        id: folder, category: .media, group: kind.mediaGroup,
        title: (folder as NSString).lastPathComponent,
        detail: "\(inside.count) \(kind.mediaNoun) · \((folder as NSString).deletingLastPathComponent.abbreviatingHome)",
        paths: [folder], safety: .data, cleanup: .trash))
    }
    for file in media where !folders.contains(where: { file.path.isInside($0) }) {
      let name = (file.path as NSString).lastPathComponent
      add(StorageItem(
        id: file.path, category: .media, group: file.kind.mediaGroup, title: name,
        detail: (file.path as NSString).deletingLastPathComponent.abbreviatingHome,
        paths: [file.path], safety: .data, cleanup: .trash))
    }
  }

  // MARK: Tables

  /// Files below this are not worth an item of their own.
  static let largeFile: Int64 = 50_000_000

  static let opaqueExtensions: Set<String> = ["app", "xcarchive", "bundle", "framework", "xcframework", "playground"]

  static let skippedHiddenFolders: Set<String> = [".git", ".hg", ".svn", ".Trash", ".DocumentRevisions-V100"]

  static let databaseMarkers: [String: String] = [
    "WiredTiger": "MongoDB", "PG_VERSION": "PostgreSQL", "ibdata1": "MySQL",
  ]

  static let fileKinds: [String: FileKind] = {
    var kinds: [String: FileKind] = [:]
    for ext in ["mp4", "mov", "mkv", "avi", "m4v", "webm", "wmv", "flv", "mpg", "mpeg", "m2ts", "mts", "prores"] {
      kinds[ext] = .video
    }
    for ext in ["mp3", "wav", "flac", "aac", "m4a", "aiff", "aif", "ogg", "opus", "alac"] { kinds[ext] = .audio }
    for ext in ["psd", "psb", "tif", "tiff", "raw", "dng", "cr2", "cr3", "nef", "arw", "exr", "heic", "png", "jpg",
      "jpeg"] {
      kinds[ext] = .image
    }
    for ext in ["iso"] { kinds[ext] = .diskImage(reDownloadable: true) }
    for ext in ["img", "qcow2", "vmdk", "vdi", "vhd", "vhdx", "hdd"] { kinds[ext] = .diskImage(reDownloadable: false) }
    for ext in ["dmg", "pkg", "mpkg", "xip", "ipsw", "apk", "aab", "msi", "exe"] { kinds[ext] = .installer }
    for ext in ["zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar"] { kinds[ext] = .archive }
    for ext in ["safetensors", "gguf", "ckpt", "pth", "onnx", "mlmodel"] { kinds[ext] = .model }
    for ext in ["sqlite", "sqlite3", "db", "duckdb", "realm"] { kinds[ext] = .database }
    return kinds
  }()

  enum FileKind: Hashable {
    case video, audio, image
    case diskImage(reDownloadable: Bool)
    case installer, archive, model, database

    var mediaGroup: String {
      switch self {
      case .audio: "Audio"
      case .image: "Images"
      default: "Videos"
      }
    }

    var mediaNoun: String {
      switch self {
      case .audio: "audio files"
      case .image: "images"
      default: "videos"
      }
    }
  }

  struct LargeFile {
    let path: String
    let kind: FileKind
  }

  private struct WalkFindings {
    var items: [StorageItem] = []
    var comfyUI: [String] = []
    var databases: [String: String] = [:]
    var files: [LargeFile] = []
  }
}
