//
//  StorageModel.swift
//  Dev
//

import Foundation

// MARK: - Category

/// The Storage tool's groups of categories, in the order of its list:
/// Development, AI, Applications (what you installed, the uninstallers and the
/// leftovers of deleted apps), Other, and CI (the virtual machines workflows run on).
nonisolated enum StorageSection: String, CaseIterable, Identifiable, Codable, Sendable {
  case development
  case ai
  case installed
  case other
  case ci

  var id: String { rawValue }

  var title: String {
    switch self {
    case .development: String(localized: "Development")
    case .ai: "AI"
    case .installed: String(localized: "Applications")
    case .other: String(localized: "Other")
    case .ci: "CI"
    }
  }

  var systemImage: String {
    switch self {
    case .development: "hammer"
    case .ai: "brain"
    case .installed: "shippingbox"
    case .other: "archivebox"
    case .ci: "server.rack"
    }
  }
}

nonisolated extension StorageSection {
  var categories: [StorageCategory] { StorageCategory.allCases.filter { $0.section == self } }
}

/// One line of the sidebar: a collapsible section, or a category that stands
/// on its own. The order here is the sidebar's.
nonisolated enum StorageSidebarEntry: Hashable, Identifiable, Sendable {
  case section(StorageSection)
  case category(StorageCategory)

  static let all: [StorageSidebarEntry] = [
    .section(.development), .section(.ai), .section(.installed), .section(.other), .section(.ci),
  ]

  var id: String {
    switch self {
    case .section(let section): "section:" + section.rawValue
    case .category(let category): "category:" + category.rawValue
    }
  }

  var title: String {
    switch self {
    case .section(let section): section.title
    case .category(let category): category.title
    }
  }

  var categories: [StorageCategory] {
    switch self {
    case .section(let section): section.categories
    case .category(let category): [category]
    }
  }
}

/// The developer-shaped buckets the Storage tool sorts the disk into. The order
/// here is the order of the sidebar and of the summary bar.
nonisolated enum StorageCategory: String, CaseIterable, Identifiable, Codable, Sendable {
  // Development: what building produces and caches.
  case xcode, android, web, javascript, python, languages
  // AI
  case aiModels, claude, hermes, codex, appleIntelligence, aiTools
  // Applications: what you installed, and what installing it left behind.
  case applications, leftovers, systemApps, homebrew, jsGlobal, pythonTools, toolchains, games
  // Other
  case caches, appData, installers, files, trash, databases, media, system
  // CI
  case virtualMachines

  var id: String { rawValue }

  var section: StorageSection? {
    switch self {
    case .xcode, .android, .web, .javascript, .python, .languages: .development
    case .aiModels, .claude, .hermes, .codex, .appleIntelligence, .aiTools: .ai
    case .applications, .leftovers, .systemApps, .homebrew, .jsGlobal, .pythonTools, .toolchains, .games: .installed
    case .caches, .appData, .installers, .files, .trash, .databases, .media, .system: .other
    case .virtualMachines: .ci
    }
  }

  var title: String {
    switch self {
    case .xcode: String(localized: "Xcode & Swift")
    case .android: String(localized: "Android & Gradle")
    case .web: String(localized: "Web & Browsers")
    case .javascript: String(localized: "Bun & Node")
    case .python: "Python"
    case .languages: String(localized: "Other Languages")
    case .aiModels: String(localized: "Models")
    case .claude: "Claude"
    case .hermes: "Hermes"
    case .codex: "Codex"
    case .appleIntelligence: "Apple Intelligence"
    case .aiTools: String(localized: "Other AI Tools")
    case .applications: String(localized: "Uninstaller")
    case .leftovers: String(localized: "Leftovers")
    case .systemApps: String(localized: "System Applications")
    case .homebrew: "Homebrew"
    case .jsGlobal: String(localized: "JS Globals")
    case .pythonTools: String(localized: "Python Tools")
    case .toolchains: String(localized: "Toolchains")
    case .games: String(localized: "Games")
    case .virtualMachines: String(localized: "Virtual Machines")
    case .databases: String(localized: "Databases")
    case .media: String(localized: "Media")
    case .system: String(localized: "System")
    case .caches: String(localized: "Caches & Temp")
    case .appData: String(localized: "App Data")
    case .installers: String(localized: "Installers & Archives")
    case .files: String(localized: "Other Files")
    case .trash: String(localized: "Trash")
    }
  }

  var subtitle: String {
    switch self {
    case .xcode: String(localized: "DerivedData, simulators, device support, SwiftPM, project builds, Command Line Tools")
    case .android: String(localized: "Emulators, SDK, Gradle caches, JDKs, project builds")
    case .web: String(localized: "Browser caches and profiles, Playwright and test browsers")
    case .javascript: String(localized: "Project node_modules and build outputs, Bun, npm, pnpm and Yarn caches")
    case .python: String(localized: "Virtual environments, uv, pip, Poetry and conda caches")
    case .languages: String(localized: "Rust, Go, .NET, Dart, Ruby, Zig: caches and project builds")
    case .aiModels: String(localized: "ComfyUI models by type, Ollama, Hugging Face, LM Studio, loose model files")
    case .claude: String(localized: "Claude desktop VM and caches, Claude Code transcripts, scratchpads and versions")
    case .hermes: String(localized: "Hermes agent, its cache and temp files")
    case .codex: String(localized: "Codex CLI and app data")
    case .appleIntelligence: String(localized: "Siri, Translation, Dictation and Apple Intelligence models macOS downloaded")
    case .aiTools: String(localized: "Cursor, Gemini CLI and other assistants")
    case .applications: String(localized: "Apps with everything they keep in your Library: support files, caches, preferences, logs")
    case .leftovers: String(localized: "Files of apps you already deleted. Nothing uses them any more.")
    case .systemApps: String(localized: "Apple's apps in /Applications, Xcode included")
    case .homebrew: String(localized: "Formulae, casks and Homebrew's download cache")
    case .jsGlobal: String(localized: "Global npm and Bun packages, npx, Node versions")
    case .pythonTools: String(localized: "pipx, pip --user packages, Python versions")
    case .toolchains: String(localized: "rustup, .NET SDK, rbenv and other installed toolchains")
    case .games: String(localized: "Steam games and caches")
    case .virtualMachines: String(localized: "UTM, Parallels, Docker, OrbStack, disk images")
    case .databases: String(localized: "Local database data directories and files")
    case .media: String(localized: "Videos, audio and large images")
    case .system: String(localized: "macOS volumes and assets, system logs and caches, swap, the rest of the disk")
    case .caches: String(localized: "App caches, logs and temporary files")
    case .appData: String(localized: "App support data and containers, iOS backups, Mail and Messages")
    case .installers: String(localized: "Disk images, packages and archives you downloaded")
    case .files: String(localized: "Your projects and files that fit no category")
    case .trash: String(localized: "What is already in the Trash")
    }
  }

  var systemImage: String {
    switch self {
    case .xcode: "swift"
    case .android: "apps.iphone"
    case .web: "globe"
    case .javascript: "curlybraces"
    case .python: "chevron.left.forwardslash.chevron.right"
    case .languages: "terminal"
    case .aiModels: "cube.transparent"
    case .claude: "sparkle"
    case .hermes: "bolt.horizontal"
    case .codex: "text.and.command.macwindow"
    case .appleIntelligence: "apple.intelligence"
    case .aiTools: "wand.and.stars"
    case .applications: "app.badge"
    case .leftovers: "archivebox"
    case .systemApps: "apple.logo"
    case .homebrew: "mug"
    case .jsGlobal: "shippingbox"
    case .pythonTools: "wrench.adjustable"
    case .toolchains: "wrench.and.screwdriver"
    case .games: "gamecontroller"
    case .virtualMachines: "server.rack"
    case .databases: "cylinder.split.1x2"
    case .media: "film"
    case .system: "gearshape.2"
    case .caches: "clock.arrow.circlepath"
    case .appData: "folder.badge.gearshape"
    case .installers: "shippingbox.and.arrow.backward"
    case .files: "folder"
    case .trash: "trash"
    }
  }
}

// MARK: - Safety

/// How much it costs to get an item back after it is cleaned. Drives the badge,
/// the confirmation wording and what "Select Safe" picks.
nonisolated enum StorageSafety: Int, Codable, Sendable, Comparable {
  /// Nothing is removed: identical copies become clones that share blocks.
  /// Below `cache` so it sorts as the safest without renumbering saved scans.
  case lossless = -1
  /// A cache the owning tool refills on its own.
  case cache = 0
  /// Rebuilt or re-downloaded on demand: build outputs, SDKs, node_modules.
  case rebuildable
  /// Your own data: VM disks, media, model downloads you picked, app state.
  case data

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  var title: String {
    switch self {
    case .lossless: String(localized: "Lossless")
    case .cache: String(localized: "Cache")
    case .rebuildable: String(localized: "Rebuildable")
    case .data: String(localized: "Your data")
    }
  }

  var help: String {
    switch self {
    case .lossless: String(localized: "Nothing is removed: identical copies share their space.")
    case .cache: String(localized: "Refilled automatically by the tool that owns it.")
    case .rebuildable: String(localized: "Rebuilt or re-downloaded the next time it is needed.")
    case .data: String(localized: "Not recreated on its own — review before removing.")
    }
  }
}

// MARK: - Cleanup

/// What cleaning an item does. Everything that removes files goes through the
/// Trash, so a mistake is one Put Back away; tools that keep their own index of
/// what is installed (simctl, ollama) are asked to remove it themselves.
nonisolated enum StorageCleanup: Codable, Sendable, Hashable {
  /// Move every path of the item to the Trash.
  case trash
  /// Move the folder's children to the Trash and keep the folder itself.
  case trashContents
  /// Run a tool: the executable and its arguments.
  case command(executable: String, arguments: [String], verb: String)
  /// Run a shell script as root, behind the administrator password prompt.
  case adminCommand(script: String, verb: String)
  /// Shown for understanding only; cleaned from its own app (Photos, Trash…).
  case revealOnly(reason: String)
  /// Replace identical files under these folders with APFS clones of one copy.
  case cloneDuplicates(roots: [String])

  var verb: String {
    switch self {
    case .trash, .trashContents: String(localized: "Move to Trash")
    case .cloneDuplicates: String(localized: "Replace with clones")
    case .command(_, _, let verb), .adminCommand(_, let verb): verb
    case .revealOnly: String(localized: "Reveal only")
    }
  }

  var isCleanable: Bool {
    if case .revealOnly = self { return false }
    return true
  }
}

// MARK: - Item

/// One cleanable chunk of disk: a folder, a few related folders (an AVD and its
/// .ini, an app and its support data), or a tool-managed thing (a simulator).
nonisolated struct StorageItem: Identifiable, Codable, Sendable, Hashable {
  /// Stable across scans so a selection survives a rescan: the first path, or a
  /// tool's own identifier (`sim:<udid>`).
  var id: String
  var category: StorageCategory
  /// The sub-heading inside the category ("Simulators", "Checkpoints"…).
  var group: String
  var title: String
  /// A short second line: runtime and state, model type, last use.
  var detail: String?
  /// Every path the item measures and, for `.trash`, removes.
  var paths: [String]
  var safety: StorageSafety
  var cleanup: StorageCleanup
  /// Below this the item is noise and is dropped after measuring.
  var minBytes: Int64 = 1_000_000
  /// Allocated bytes on disk (hard links counted once), filled by measuring.
  /// Some tools report their own size (simulator runtimes) and skip measuring.
  var bytes: Int64 = 0
  /// True when the size came from the owning tool rather than a walk.
  var reportedSize = false
  /// Bytes it shares with other items through clones or hard links, already
  /// counted in theirs. Removing it alone does not free them. Optional so
  /// scans saved before this existed still load.
  var sharedBytes: Int64?
  /// True when your account cannot move it (root-owned apps, system folders):
  /// cleaning it asks for the administrator password.
  var needsAdmin = false
  /// Paths under `paths` that another item owns: skipped while measuring so
  /// the same bytes are never counted twice.
  var excluded: [String] = []
  /// Why the item cannot be picked right now (a VM a workflow runs on, a
  /// runtime the installed Xcode uses), or nil. Optional so older scans load.
  var lockReason: String?
  /// When anything inside last changed, filled by measuring; nil for sizes a
  /// tool reported and for scans saved before this existed.
  var modified: Date?
  /// The item this one is part of (a simulator's runtime): listed under it,
  /// picked with it, and removed by `cleanupWithParent` when it goes. Optional
  /// so older scans load.
  var parent: String?
  /// How the item goes when its parent goes too (a simulator is deleted, not
  /// erased, with its runtime).
  var cleanupWithParent: StorageCleanup?
  /// Who still needs it (the devices that run this Device Support's OS):
  /// Smart Scan leaves it, though it can still be picked by hand. Optional so
  /// older scans load.
  var inUse: String?

  var isLocked: Bool { lockReason != nil }

  var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

  /// The item's main location, for Reveal in Finder and the path line.
  var primaryPath: String { paths.first ?? "" }
}

// MARK: - What Smart Scan picks

nonisolated extension StorageItem {
  /// Something installed rather than made: a formula, a language version or
  /// toolchain, a global package, a simulator runtime, the Command Line Tools,
  /// an app's own tools and VM. Only installing it again brings it back.
  var isInstalled: Bool {
    guard safety == .rebuildable else { return false }
    if category.section == .installed { return true }
    if StorageLanguages.classify(self)?.isVersion == true { return true }
    switch (category, group) {
    case (.xcode, "Command Line Tools"), (.claude, "Claude Code"),
      (.claude, "Claude desktop"), (.web, "Test Browsers"):
      return true
    default:
      return id.hasPrefix("runtime:")
    }
  }

  /// An agent session's scratchpad or a temp folder: often still in use by
  /// whatever made it, so it is picked by age on its own, not by Smart Scan.
  var isScratch: Bool {
    (category == .claude && group == "Claude Code scratchpads")
      || (category == .caches && group == "Temporary Files")
  }

  /// What Smart Scan picks: caches and build output. Never your data, never
  /// what you installed, never scratch space, never what a device still needs.
  var isRecommended: Bool {
    safety != .data && cleanup.isCleanable && !isLocked && !isInstalled && !isScratch && inUse == nil
  }
}

// MARK: - Snapshot

/// One finished scan, persisted so the tool opens on the last result instead of
/// an empty page.
nonisolated struct StorageSnapshot: Codable, Sendable {
  var date: Date
  var items: [StorageItem]
  var volumeTotal: Int64
  var volumeAvailable: Int64
  var roots: [String]
  /// Whether the scan could read protected folders. Optional so snapshots
  /// saved before this existed still load.
  var fullDiskAccess: Bool?
  /// The last system scan's items, kept across normal rescans: a normal scan
  /// never asks for the password, so it cannot refresh them.
  var systemItems: [StorageItem]?
  var systemDate: Date?
}

nonisolated extension Int64 {
  /// "12.4 GB" — the file-size style Finder uses.
  var byteString: String {
    ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
  }
}
