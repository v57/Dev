import Foundation
import VaultKit

/// Debug builds: `--vault-demo` (with `-DevScreenshotMode`) runs Dev on a vault of its own, so the sidebar's shared
/// projects section can be checked on real folders without the user's vault, keychain or projects.
///
///   --vault-demo              a fresh vault in a temporary folder, its secrets and keys in memory
///   --add-folder <folder>     adds the folder's Git repositories to it, in groups as Git adds them (repeatable);
///                             its Xcode projects are the run's demo projects
///
/// Settings go in as launch-argument defaults (`-SidebarProjectsLayout inline`).
enum VaultDemo {
  static let isOn: Bool = {
    #if DEBUG
      CommandLine.arguments.contains("--vault-demo")
    #else
      false
    #endif
  }()

  /// Before anything opens the vault: the demo's own store, with the `--add-folder` projects.
  @MainActor static func prepare() {
    guard isOn else { return }
    VaultSecrets.useInMemoryStore()
    let vault = FileManager.default.temporaryDirectory.appendingPathComponent("DevVaultDemo/Vault")
    try? FileManager.default.removeItem(at: vault)
    try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    setenv("VAULT_DIRECTORY", vault.path, 1)
    guard let store = Vaults.shared.vault(for: .personal)?.store else { return }
    let arguments = CommandLine.arguments
    for index in arguments.indices.dropLast() where arguments[index] == "--add-folder" {
      let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
      let found = VaultProjectDiscovery.scan(root)
      for repository in found.repositories { _ = try? store.addProject(path: repository.path) }
      try? store.arrangeProjects(found.repositories.map(\.path), roots: [root.path])
    }
    try? store.refreshProjectKinds()
  }

  /// The demo vault's Xcode projects on this Mac: the run's projects.
  @MainActor static var projects: [URL] {
    guard isOn else { return [] }
    Vault.shared.reload()
    return Vault.shared.localProjects.filter { $0.kinds.contains(.xcode) }.compactMap(\.localURL)
  }
}
