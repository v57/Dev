//
//  WelcomeView.swift
//  Dev
//

import Foundation
import ComponentKit
import SwiftUI
import VaultKit

/// The main screen while nothing is selected: the kit's welcome with Dev's actions, its projects last opened first
/// (Recent), and the projects the other v57 apps share that Dev doesn't list yet (Projects). A folder dropped on it
/// is added like a drop on the sidebar.
struct WelcomeView: View {
  let model: SidebarViewModel
  @AppStorage("WelcomeSource") private var source = WelcomeSource.recent
  @State private var search = ""

  var body: some View {
    KitWelcome(
      emptyTitle: search.isEmpty ? "No Projects Yet" : "No Matches",
      emptyMessage: search.isEmpty
        ? "Drop a project folder here. Drop a folder of repos, like ~/Developer, and Dev adds each git repository inside it."
        : "No project is named “\(search)”.",
      source: $source, searchText: $search, searchPrompt: "Search Projects",
      onDrop: { urls in
        Task {
          if let first = await model.importDroppedURLs(urls) { model.selection = .project(first) }
        }
        return true
      }
    ) {
      WelcomeAction("Add Project…", detail: "A project folder, or a folder of repos", systemImage: "folder.badge.plus") {
        model.addProjectsFromPanel()
      }
      WelcomeAction("New Icon", detail: "An app icon from an SF Symbol, without a project", systemImage: "app.badge") {
        model.selection = .tool(.icon)
      }
      WelcomeAction("Storage", detail: "What fills this \(KitDevice.nameInSentence), and what can go", systemImage: "internaldrive") {
        model.selection = .storage
      }
    } recents: {
      ForEach(recentProjects) { row in
        RecentItem(
          row.name, subtitle: row.rootURL.map(Self.abbreviated), date: model.lastOpened(row.id).map(Self.day),
          status: row.needsReview > 0 ? "\(row.needsReview) to review" : nil, statusHue: .orange,
          systemImage: "folder", image: Self.icon(row), id: "\(row.id)"
        ) {
          model.selection = .project(row.id)
        }
      }
    } projects: {
      ForEach(otherProjects, id: \.id) { project in
        RecentItem(
          project.name, subtitle: project.localPath.map { Self.abbreviated(URL(fileURLWithPath: $0)) },
          status: project.addedBy, systemImage: "folder", image: project.icon.flatMap(Image.init(data:)),
          id: project.id
        ) {
          Task {
            if let id = await model.vaultProjects.add(project, model: model) { model.selection = .project(id) }
          }
        }
      }
    }
    .listTitle(source == .recent ? "Recent" : "In Your Other Apps")
    .kitPane()
  }

  /// Dev's projects matching the search, last opened first, then by name.
  private var recentProjects: [SidebarProjectRow] {
    model.projects
      .filter { matches($0.name, $0.rootURL?.path) }
      .sorted { a, b in
        switch (model.lastOpened(a.id), model.lastOpened(b.id)) {
        case let (x?, y?): x > y
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
      }
  }

  /// The vault's projects on this Mac that Dev could list but doesn't, matching the search.
  private var otherProjects: [VaultProject] {
    let listed = Set(model.projects.compactMap { $0.rootURL?.standardizedFileURL.path })
    return model.vaultProjects.otherProjects(listed: listed).filter { matches($0.name, $0.localPath) }
  }

  private func matches(_ name: String, _ path: String?) -> Bool {
    let query = search.trimmingCharacters(in: .whitespaces)
    return query.isEmpty || name.localizedCaseInsensitiveContains(query)
      || (path?.localizedCaseInsensitiveContains(query) ?? false)
  }

  private static func icon(_ row: SidebarProjectRow) -> Image? {
    if let data = row.vaultIcon, let image = Image(data: data) { return image }
    // The placeholder folder symbol isn't an icon: the item's own folder tile stands in.
    guard row.iconURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true, let image = row.iconImage
    else { return nil }
    return image
  }

  private static func abbreviated(_ url: URL) -> String {
    url.path(percentEncoded: false).abbreviatingHome
  }

  /// "Today", "Yesterday", or the date.
  private static func day(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(date: .abbreviated, time: .omitted)
  }
}
