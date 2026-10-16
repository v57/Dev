//
//  WelcomeView.swift
//  Dev
//

import ComponentKit
import SwiftUI

/// The first screen, while there are no projects: one large drop area with
/// Choose Folder…, and what the project tools do.
struct WelcomeView: View {
  let model: SidebarViewModel
  @State private var isTargeted = false

  var body: some View {
    VStack(spacing: 28) {
      EmptyState(
        systemImage: "folder.badge.plus", title: "Add Your Projects",
        message: "Drop a project folder here. Drop a folder of repos, like ~/Developer, and Dev adds each git repository inside it."
      ) {
        Button("Choose Folder…") { model.addProjectsFromPanel() }
          .buttonStyle(.kitPrimary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: 600)
      .background(.kitField, in: RoundedRectangle(cornerRadius: KitMetrics.radiusOverlay, style: .continuous))
      .kitDropTarget(isTargeted, cornerRadius: KitMetrics.radiusOverlay)
      .dropDestination(for: URL.self) { urls, _ in
        Task {
          if let first = await model.importDroppedURLs(urls) { model.selection = .project(first) }
        }
        return true
      } isTargeted: {
        isTargeted = $0
      }

      HStack(alignment: .top, spacing: KitMetrics.gutter) {
        tile("Localization", "globe", .teal, "Translate the String Catalog with the model you choose, then review.")
        tile("App Icon", "app.badge", .pink, "Make an icon from an SF Symbol and export every size, plus a Liquid Glass file.")
        tile("Workflows", "shippingbox", .indigo, "Build, test, capture screenshots, notarize and publish, on this Mac and its VMs.")
      }
      .frame(width: 600)

      Text("Storage and Virtual Machines work without a project. Find them in the sidebar.")
        .kitFont(.callout)
        .foregroundStyle(.kitSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .kitPane()
  }

  private func tile(_ title: String, _ symbol: String, _ hue: Hue, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      RichHeader(title, systemImage: symbol, hue: hue)
      Text(text)
        .kitFont(.callout)
        .foregroundStyle(.kitSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding([.horizontal, .bottom], 6)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .kitCard()
  }
}
