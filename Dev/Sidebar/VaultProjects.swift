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
@MainActor final class VaultProjects {
  static let shared = VaultProjects()

  private let vault = Vault.shared
  private var observer: VaultChangeObserver?
  private weak var model: SidebarViewModel?

  /// Vault projects removed in Dev, by id.
  private var dismissed: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: "DismissedVaultProjects") ?? []) }
    set { UserDefaults.standard.set(Array(newValue), forKey: "DismissedVaultProjects") }
  }

  /// Folders Dev added because the vault had them, so they leave when the vault drops them.
  private var adopted: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: "AdoptedVaultProjects") ?? []) }
    set { UserDefaults.standard.set(Array(newValue), forKey: "AdoptedVaultProjects") }
  }

  /// Starts following the vault for the sidebar (at launch, outside screenshot mode).
  func start(model: SidebarViewModel) {
    guard !LaunchOptions.isScreenshotMode, observer == nil else { return }
    self.model = model
    observer = VaultChangeObserver { [weak self] in
      Task { @MainActor in
        self?.vault.reload()
        await self?.follow()
      }
    }
    Task {
      model.refresh()
      publish(model.projects.compactMap(\.rootURL))
      await follow()
    }
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
    return await model.addSuggestedDirectories([URL(fileURLWithPath: path, isDirectory: true)])
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
      await model.addSuggestedDirectories(missing.map { URL(fileURLWithPath: $0, isDirectory: true) })
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
