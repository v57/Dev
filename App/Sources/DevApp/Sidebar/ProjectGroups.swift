import Foundation
import VaultKit

/// The Projects section's tree for VaultUI's `VaultProjectsSection`: the vault's project tree (the groups made in
/// Git, shared with the other v57 apps and Macs) cut down to Dev's projects, with the ones the vault doesn't list at
/// the end of the top level, as projects of their own (`dev.project.<id>`). A search keeps the projects whose name
/// matches and the groups that hold one.
struct ProjectGroupsLayout {
  let tree: VaultProjectTree
  /// Dev's row of each project in `tree`, by its id there.
  let rows: [String: SidebarProjectRow]
  /// The id in `tree` of each of Dev's rows.
  let ids: [Int64: String]

  init(projects: [SidebarProjectRow], tree: VaultProjectTree, search: String) {
    let shown = search.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    let device = VaultDevice.id
    var byPath: [String: SidebarProjectRow] = [:]
    for project in shown {
      if let path = project.rootURL?.standardizedFileURL.path { byPath[path] = byPath[path] ?? project }
    }
    let listed = tree.filter { $0.paths[device].map { byPath[$0] != nil } ?? false }
    var rows: [String: SidebarProjectRow] = [:]
    var ids: [Int64: String] = [:]
    for project in listed.projects() {
      guard let row = project.paths[device].flatMap({ byPath[$0] }) else { continue }
      rows[project.id] = row
      if ids[row.id] == nil { ids[row.id] = project.id }
    }
    // The projects the vault doesn't list (a catalog without a folder, screenshot runs), after its own.
    let loose = shown.filter { ids[$0.id] == nil }.map { row in
      let id = "dev.project.\(row.id)"
      rows[id] = row
      ids[row.id] = id
      return VaultProject(
        id: id, name: row.name, order: .max,
        paths: row.rootURL.map { [device: $0.standardizedFileURL.path] } ?? [:], icon: row.vaultIcon, addedBy: nil,
        added: nil)
    }
    self.tree = VaultProjectTree(projects: listed.projects() + loose, groups: listed.groups)
    self.rows = rows
    self.ids = ids
  }
}
