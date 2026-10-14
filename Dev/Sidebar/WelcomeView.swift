//
//  WelcomeView.swift
//  Dev
//

import SwiftUI

/// The first screen, while there are no projects: one large drop area with
/// Choose Folder…, and what the project tools do.
struct WelcomeView: View {
  let model: SidebarViewModel
  @State private var isTargeted = false

  var body: some View {
    VStack(spacing: 28) {
      VStack(spacing: 14) {
        Image(systemName: "folder.badge.plus")
          .font(.system(size: 52, weight: .regular))
          .foregroundStyle(Color.accentColor)
        Text("Add Your Projects")
          .font(.largeTitle.weight(.bold))
        Text("Drop a project folder here. Drop a folder of repos, like ~/Developer, and Dev adds each git repository inside it.")
          .font(.title3)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 440)
        Button("Choose Folder…") { model.addProjectsFromPanel() }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .padding(.top, 6)
      }
      .padding(.horizontal, 40)
      .padding(.vertical, 40)
      .frame(width: 600)
      .background(
        RoundedRectangle(cornerRadius: 28)
          .fill(isTargeted ? Color.accentColor.opacity(0.06) : Color.clear))
      .overlay(
        RoundedRectangle(cornerRadius: 28)
          .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, dash: [8])))
      .dropDestination(for: URL.self) { urls, _ in
        Task {
          if let first = await model.importDroppedURLs(urls) { model.selection = .project(first) }
        }
        return true
      } isTargeted: {
        isTargeted = $0
      }

      HStack(alignment: .top, spacing: 14) {
        tile("Localization", "globe", "Translate the String Catalog with the model you choose, then review.")
        tile("App Icon", "app.badge", "Make an icon from an SF Symbol and export every size, plus a Liquid Glass file.")
        tile("Workflows", "shippingbox", "Build, test, capture screenshots, notarize and publish, on this Mac and its VMs.")
      }
      .frame(width: 600)

      Text("Storage and Virtual Machines work without a project. Find them in the sidebar.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func tile(_ title: String, _ symbol: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Image(systemName: symbol)
        .font(.title2)
        .foregroundStyle(Color.accentColor)
      Text(title).font(.headline)
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
  }
}
