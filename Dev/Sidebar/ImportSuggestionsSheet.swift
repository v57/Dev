//
//  ImportSuggestionsSheet.swift
//  Dev
//

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
    VStack(alignment: .leading, spacing: 12) {
      Text("Add these folders too?")
        .font(.headline)
      Text("They hold no git repository, so the drop skipped them. Ticked ones look like projects.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      List(suggestions) { item in
        Toggle(isOn: binding(for: item.url)) {
          VStack(alignment: .leading, spacing: 2) {
            Text(item.url.lastPathComponent)
            Text(item.url.deletingLastPathComponent().path(percentEncoded: false)
              .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
      .listStyle(.bordered)
      .frame(minHeight: 160, maxHeight: 320)
      HStack {
        Button(picked.count == suggestions.count ? "Select None" : "Select All") {
          picked = picked.count == suggestions.count ? [] : Set(suggestions.map(\.url))
        }
        Spacer()
        Button("Not Now") { onAdd([]) }
          .keyboardShortcut(.cancelAction)
        Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
          onAdd(suggestions.map(\.url).filter(picked.contains))
        }
        .keyboardShortcut(.defaultAction)
        .disabled(picked.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 440)
  }

  private func binding(for url: URL) -> Binding<Bool> {
    Binding(
      get: { picked.contains(url) },
      set: { if $0 { picked.insert(url) } else { picked.remove(url) } })
  }
}
