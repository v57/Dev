import Foundation
import VaultKit

/// Dev's side of the projects the v57 apps share through the vault (`../Vault`): the repositories added in Git
/// (or in Code, Markdown, Shell) appear in the sidebar as they're added, and folders dropped here are published
/// for the others.
///
/// A project removed in Dev stays in the other apps: Dev remembers it and doesn't bring it back. A project
/// removed in Git leaves Dev too, unless Dev holds translation work for it.
///
/// Dev lists only Xcode projects: the vault notes each project's kinds (`VaultProject.Kind`), and the others
/// stay in the other apps (Settings ▸ General ▸ Show only Xcode projects).
///
/// One per account (../Ideas/Accounts.md): a window lists the projects of the account it shows. Dev's own project
/// list (`TranslationData`) holds every account's; an account's window lists the folders its vault has, and
/// Personal's lists the rest, leaving out those only another account has.
@MainActor final class VaultProjects {
  /// Personal's: today's vault, and what screenshot mode and code outside a window use.
  static let shared = VaultProjects(vault: .shared)
  private static var accounts: [String: VaultProjects] = [:]

  /// The projects of the account `vault` belongs to.
  static func of(_ vault: Vault) -> VaultProjects {
    if vault.isPersonal { return shared }
    if let projects = accounts[vault.accountID], projects.vault === vault { return projects }
    let projects = VaultProjects(vault: vault)
    accounts[vault.accountID] = projects
    return projects
  }

  let vault: Vault
  private var observer: VaultChangeObserver?
  private weak var model: SidebarViewModel?

  private init(vault: Vault) {
    self.vault = vault
  }

  /// Personal keeps the keys it had before accounts.
  private func key(_ name: String) -> String { vault.isPersonal ? name : "\(name).\(vault.accountID)" }

  /// Vault projects removed in Dev, by id.
  private var dismissed: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: key("DismissedVaultProjects")) ?? []) }
    set { UserDefaults.standard.set(Array(newValue), forKey: key("DismissedVaultProjects")) }
  }

  /// Folders Dev added because the vault had them, so they leave when the vault drops them.
  private var adopted: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: key("AdoptedVaultProjects")) ?? []) }
    set { UserDefaults.standard.set(Array(newValue), forKey: key("AdoptedVaultProjects")) }
  }

  /// Starts following the vault for a window's sidebar (outside screenshot mode); the window's last model wins.
  func start(model: SidebarViewModel) {
    guard !LaunchOptions.isScreenshotMode else { return }
    self.model = model
    if observer == nil {
      observer = VaultChangeObserver { [weak self] in
        Task { @MainActor in
          self?.vault.reload()
          await self?.follow()
        }
      }
    }
    Task {
      model.refresh()
      publish(model.projects.compactMap(\.rootURL))
      await follow()
    }
  }

  /// The window switched to another account: stop adding this one's projects to its sidebar.
  func stop(model: SidebarViewModel) {
    if self.model === model { self.model = nil }
  }

  /// Which of Dev's project folders this account's window lists.
  func listing() -> Listing {
    guard !LaunchOptions.isScreenshotMode else { return Listing(isPersonal: true, own: [], others: []) }
    let vaults = Vaults.shared
    let others = vaults.allAccounts.filter { $0.id != vault.accountID }.compactMap { vaults.vault(for: $0) }
    return Listing(
      isPersonal: vault.isPersonal, own: Set(vault.localProjects.compactMap(\.localPath)),
      others: Set(others.flatMap { $0.localProjects.compactMap(\.localPath) }))
  }

  struct Listing {
    var isPersonal: Bool
    /// The folders this account's vault has on this Mac.
    var own: Set<String>
    /// The folders the other accounts' vaults have.
    var others: Set<String>

    /// An account lists its own folders; Personal also lists those no account has (a catalog without a folder
    /// too).
    func lists(_ root: URL?) -> Bool {
      guard let path = root?.standardizedFileURL.path else { return isPersonal }
      return own.contains(path) || (isPersonal && !others.contains(path))
    }
  }

  /// The account a project folder belongs to, whose GitHub sign-in its releases use: this window's account when
  /// its vault has the folder, else an account whose vault has it, else Personal (which lists the rest).
  func account(of root: URL) -> String {
    let path = root.standardizedFileURL.path
    func has(_ vault: Vault?) -> Bool { vault?.localProjects.contains { $0.localPath == path } == true }
    if has(vault) { return vault.accountID }
    let vaults = Vaults.shared
    return vaults.accounts.first { has(vaults.vault(for: $0)) }?.id ?? VaultAccount.personal.id
  }

  /// Whether Dev leaves out the projects that aren't Xcode projects (on unless turned off in Settings).
  var showsOnlyXcodeProjects: Bool {
    UserDefaults.standard.object(forKey: SidebarPreferences.onlyXcodeProjects) as? Bool ?? true
  }

  /// The folders of the projects Dev leaves out: the vault's projects on this Mac that aren't Xcode projects.
  func hiddenRoots() -> Set<String> {
    guard !LaunchOptions.isScreenshotMode, showsOnlyXcodeProjects else { return [] }
    return Set(vault.localProjects.filter { !$0.kinds.contains(.xcode) }.compactMap(\.localPath))
  }

  /// The app icons the vault keeps (see `Vault.findProjectIcons`), by project folder.
  func icons() -> [String: Data] {
    guard !LaunchOptions.isScreenshotMode else { return [:] }
    var icons: [String: Data] = [:]
    for project in vault.localProjects {
      if let path = project.localPath, let icon = project.icon { icons[path] = icon }
    }
    return icons
  }

  /// The vault's projects on this Mac that Dev could list but doesn't (removed here, or not followed yet), by name:
  /// the welcome's Projects list.
  func otherProjects(listed: Set<String>) -> [VaultProject] {
    guard !LaunchOptions.isScreenshotMode else { return [] }
    return vault.localProjects
      .filter { project in
        guard let path = project.localPath else { return false }
        return !listed.contains(path) && (!showsOnlyXcodeProjects || project.kinds.contains(.xcode))
      }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Adds a vault project to Dev, taking back an earlier removal here; returns its id in the sidebar.
  func add(_ project: VaultProject, model: SidebarViewModel) async -> Int64? {
    guard let path = project.localPath else { return nil }
    dismissed.remove(project.id)
    return await model.addSuggestedDirectories([URL(fileURLWithPath: path, isDirectory: true)], publishing: false)
  }

  /// Follows the vault again after Show only Xcode projects changed.
  func preferencesChanged() {
    guard observer != nil else { return }
    Task { await follow() }
  }

  /// Notes the kinds of this Mac's projects, adds the vault's Xcode projects on this Mac that Dev doesn't list,
  /// and removes adopted ones the vault no longer has.
  private func follow() async {
    guard let model else { return }
    vault.perform { try $0.refreshProjectKinds() }
    let fileManager = FileManager.default
    let local = vault.localProjects.filter { project in
      !dismissed.contains(project.id) && (!showsOnlyXcodeProjects || project.kinds.contains(.xcode))
    }
    let known = Set(model.projects.compactMap { $0.rootURL?.standardizedFileURL.path })
    let missing = local.compactMap(\.localPath).filter { path in
      !known.contains(path) && fileManager.fileExists(atPath: path)
    }
    if !missing.isEmpty {
      adopted.formUnion(missing)
      await model.addSuggestedDirectories(missing.map { URL(fileURLWithPath: $0, isDirectory: true) }, publishing: false)
    }
    let inVault = Set(vault.localProjects.compactMap(\.localPath))
    for path in adopted where !inVault.contains(path) {
      if model.removeUnusedProject(rootPath: path) { adopted.remove(path) }
    }
    model.refresh()
  }

  /// Publishes project folders for the other apps.
  func publish(_ roots: [URL]) {
    guard !LaunchOptions.isScreenshotMode, !roots.isEmpty else { return }
    vault.perform { store in
      for root in roots { try store.addProject(path: root.standardizedFileURL.path) }
    }
  }

  /// The user removed a project in Dev: keep it out of Dev, but leave it in the other apps.
  func dismiss(rootURL: URL?) {
    guard let path = rootURL?.standardizedFileURL.path,
      let project = vault.localProjects.first(where: { $0.localPath == path })
    else { return }
    dismissed.insert(project.id)
    adopted.remove(path)
  }
}
