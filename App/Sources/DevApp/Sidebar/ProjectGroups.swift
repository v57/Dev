import Foundation
import ComponentKit
import VaultKit

/// The Projects section's arrangement: the vault's project tree (the groups made in Git, shared with the other v57
/// apps and Macs) cut down to Dev's projects, with the ones the vault doesn't list at the end of the top level.
/// Which groups are closed is Dev's own (a `KitIDSet`); the sidebar draws the tree as a `KitOutline`.
struct ProjectGroupsLayout {
  /// A group with what is in it, or a project.
  struct Node: Identifiable {
    enum Item {
      /// A group, with Dev's projects in it and in the groups inside it.
      case group(VaultProjectGroup, projects: [SidebarProjectRow])
      case project(SidebarProjectRow)
    }

    let item: Item
    /// A group's nodes; `nil` for a project.
    let children: [Node]?

    /// A group's own id (what `KitIDSet` keeps for a closed one), or the project's, prefixed.
    var id: String {
      switch item {
      case .group(let group, _): group.id
      case .project(let project): "project:\(project.id)"
      }
    }
  }

  /// The top level. A search keeps the projects whose name matches and the groups that hold one.
  let roots: [Node]
  /// The rows on screen with `collapsed` closed (every group is open during a search), for the sidebar's animation.
  let visibleIDs: [String]
  init(projects: [SidebarProjectRow], tree: VaultProjectTree, collapsed: Set<String>, search: String) {
    let shown = search.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    let device = VaultDevice.id
    var byPath: [String: SidebarProjectRow] = [:]
    for project in shown {
      if let path = project.rootURL?.standardizedFileURL.path { byPath[path] = byPath[path] ?? project }
    }
    let tree = tree.filter { $0.paths[device].map { byPath[$0] != nil } ?? false }
    func row(for project: VaultProject) -> SidebarProjectRow? { project.paths[device].flatMap { byPath[$0] } }

    func nodes(_ vault: [VaultProjectTree.Node]) -> [Node] {
      vault.compactMap { node -> Node? in
        switch node {
        case .project(let project):
          return row(for: project).map { Node(item: .project($0), children: nil) }
        case .group(let group, let children):
          return Node(item: .group(group, projects: node.projects.compactMap(row(for:))), children: nodes(children))
        }
      }
    }
    let inTree = Set(tree.projects().compactMap { $0.paths[device] })
    let loose = shown.filter { project in
      project.rootURL.map { !inTree.contains($0.standardizedFileURL.path) } ?? true
    }
    roots = nodes(tree.roots) + loose.map { Node(item: .project($0), children: nil) }

    func visible(_ nodes: [Node]) -> [String] {
      nodes.flatMap { node -> [String] in
        guard case .group(let group, _) = node.item, let children = node.children,
              !search.isEmpty || !collapsed.contains(group.id)
        else { return [node.id] }
        return [node.id] + visible(children)
      }
    }
    visibleIDs = visible(roots)
  }
}
