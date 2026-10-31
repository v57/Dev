//
//  ImportSuggestionsSheet.swift
//  Dev
//

import ComponentKit
import SwiftUI

/// The directories a drop passed over, offered as projects. A drop adds the git
/// repos it finds; a folder beside them without git (demos, a design folder) is
/// listed here, ticked when it looks like a project, so nothing in the dropped
/// tree goes missing without the reader seeing it.
struct ImportSuggestionsSheet: View {
  let suggestions: [RepoDiscovery.Skipped]
  /// Called with the picked directories; an empty list means "Not Now".
  let onAdd: ([URL]) -> Void

  @State private var picked: Set<URL>

  init(suggestions: [RepoDiscovery.Skipped], onAdd: @escaping ([URL]) -> Void) {
    self.suggestions = suggestions
    self.onAdd = onAdd
    _picked = State(initialValue: Set(suggestions.filter(\.looksLikeProject).map(\.url)))
  }

  var body: some View {
    KitSheet(
      title: "Add these folders too?",
      meta: "They hold no git repository, so the drop skipped them. Ticked ones look like projects.",
      systemImage: "folder.badge.plus"
    ) {
      FormCard {
        ForEach(suggestions) { item in
          FormRow(
            item.url.lastPathComponent,
            help: item.url.deletingLastPathComponent().path(percentEncoded: false)
              .replacingOccurrences(of: NSHomeDirectory(), with: "~"),
            systemImage: "folder", hue: item.looksLikeProject ? .blue : .gray
          ) {
            Toggle(item.url.lastPathComponent, isOn: binding(for: item.url))
              .labelsHidden()
              .toggleStyle(.kitCheckbox)
          }
        }
      }
    } footer: {
      Button(picked.count == suggestions.count ? "Select None" : "Select All") {
        picked = picked.count == suggestions.count ? [] : Set(suggestions.map(\.url))
      }
      .buttonStyle(.kitPlain)
      Spacer()
      Button("Not Now") { onAdd([]) }
        .buttonStyle(.kit)
        .keyboardShortcut(.cancelAction)
      Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
        onAdd(suggestions.map(\.url).filter(picked.contains))
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(picked.isEmpty)
    }
  }

  private func binding(for url: URL) -> Binding<Bool> {
    Binding(
      get: { picked.contains(url) },
      set: { if $0 { picked.insert(url) } else { picked.remove(url) } })
  }
}
