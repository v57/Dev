import Foundation
import VaultKit

/// The Projects section's arrangement: the vault's project tree (the groups made in Git, shared with the other v57
/// apps and Macs) cut down to Dev's projects, with the ones the vault doesn't list at the end of the top level.
/// Which groups are closed is Dev's own.
struct ProjectGroupsLayout {
  /// A row on screen: a group's header or a project, and how many groups it is in.
  struct Row: Identifiable {
    enum Item {
      /// A group, with Dev's projects in it and in the groups inside it.
      case group(VaultProjectGroup, projects: [SidebarProjectRow])
      case project(SidebarProjectRow)
    }

    let item: Item
    let depth: Int

    enum ID: Hashable {
      case group(String)
      case project(Int64)
    }

    var id: ID {
      switch item {
      case .group(let group, _): .group(group.id)
      case .project(let project): .project(project.id)
      }
    }
  }

  /// What is on screen, top to bottom. A search keeps the projects whose name matches, opens every group that
  /// holds one, and drops the rest.
  let rows: [Row]
  /// Whether any group is on screen: the projects then keep the chevron's slot, so their icons line up.
  var hasGroups: Bool {
    rows.contains { if case .group = $0.item { true } else { false } }
  }

  init(projects: [SidebarProjectRow], tree: VaultProjectTree, collapsed: Set<String>, search: String) {
    let shown = search.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    let device = VaultDevice.id
    var byPath: [String: SidebarProjectRow] = [:]
    for project in shown {
      if let path = project.rootURL?.standardizedFileURL.path { byPath[path] = byPath[path] ?? project }
    }
    let tree = tree.filter { $0.paths[device].map { byPath[$0] != nil } ?? false }
    func row(for project: VaultProject) -> SidebarProjectRow? { project.paths[device].flatMap { byPath[$0] } }

    func rows(_ nodes: [VaultProjectTree.Node], depth: Int) -> [Row] {
      nodes.flatMap { node -> [Row] in
        switch node {
        case .project(let project):
          return row(for: project).map { [Row(item: .project($0), depth: depth)] } ?? []
        case .group(let group, let children):
          let header = Row(item: .group(group, projects: node.projects.compactMap(row(for:))), depth: depth)
          let isOpen = !search.isEmpty || !collapsed.contains(group.id)
          return [header] + (isOpen ? rows(children, depth: depth + 1) : [])
        }
      }
    }
    let inTree = Set(tree.projects().compactMap { $0.paths[device] })
    let loose = shown.filter { project in
      project.rootURL.map { !inTree.contains($0.standardizedFileURL.path) } ?? true
    }
    self.rows = rows(tree.roots, depth: 0) + loose.map { Row(item: .project($0), depth: 0) }
  }
}

/// The ids of the closed groups, kept in one defaults string.
struct CollapsedGroups: RawRepresentable {
  var ids: Set<String>

  init() { ids = [] }

  init(rawValue: String) {
    ids = Set(rawValue.split(separator: "\n").map(String.init))
  }

  var rawValue: String { ids.sorted().joined(separator: "\n") }
}
