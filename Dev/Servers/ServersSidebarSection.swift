//
//  ServersSidebarSection.swift
//  Dev
//

import SwiftUI

/// What the servers sheet is doing: adding one, or editing an existing row.
/// One sheet for both, so the form (and its validation) exists once.
enum ServerSheet: Identifiable {
  case add
  case edit(String)

  var id: String {
    switch self {
    case .add: return "add"
    case .edit(let id): return "edit-\(id)"
    }
  }
}

/// The sidebar's Servers section: one row per Localization Server, plus
/// the "Add Connection" row when there is nowhere to click yet.
///
/// A row is a normal sidebar destination (`.server(id)`), so selecting one fills
/// the detail pane with that server's own pane. The context menu carries the two
/// per-server actions that do not belong in the pane's own buttons: a manual
/// check and the removal (which is destructive and therefore asks first).
struct ServersSidebarSection: View {
  let store: ServerStore
  @Binding var selection: SidebarSelection?
  /// Opens the add/edit sheet, owned by the sidebar so one sheet serves the
  /// toolbar button, the empty-state row and a row's Edit….
  let onEdit: (ServerSheet) -> Void
  /// Asks before removing a server that has its own stored key.
  @State private var pendingRemoval: ServerRow?

  var body: some View {
    Section("Servers") {
      if let problem = store.alert {
        Label(problem, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      if store.servers.isEmpty {
        Button {
          onEdit(.add)
        } label: {
          Label("Add Connection", systemImage: "plus.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Connect a server that serves its strings through the Localization Server API")
      } else {
        ForEach(store.servers) { row in
          NavigationLink(value: SidebarSelection.server(row.id)) {
            ServerSidebarRow(row: row, status: store.statuses[row.id] ?? .unknown)
          }
          .contextMenu {
            Button("Check Now") { Task { await store.check(id: row.id) } }
            Button("Edit…") { onEdit(.edit(row.id)) }
            Divider()
            Button("Remove", role: .destructive) { pendingRemoval = row }
          }
        }
      }
    }
    .confirmationDialog(
      "Remove \(pendingRemoval?.name ?? "")?",
      isPresented: Binding(
        get: { pendingRemoval != nil },
        set: { if !$0 { pendingRemoval = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove Server", role: .destructive) {
        if let row = pendingRemoval {
          if selection == .server(row.id) { selection = nil }
          store.remove(id: row.id)
        }
        pendingRemoval = nil
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text("The server's key is removed from the login keychain. Nothing on the server itself is touched.")
    }
  }
}

/// One server row: its name, the endpoint it points at, and the last check's
/// outcome as a dot whose colour carries the difference between "reachable",
/// "refused" and "not configured".
struct ServerSidebarRow: View {
  let row: ServerRow
  let status: ServerStatus

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "server.rack")
        .foregroundStyle(.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.name)
          .lineLimit(1)
        Text(row.hostLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      Circle()
        .fill(dotColor)
        .frame(width: 7, height: 7)
        .help(status.short)
    }
    .help("\(row.endpoint)\n\(row.keySource.label)\n\(status.short)")
  }

  private var dotColor: Color {
    switch status {
    case .online: return .green
    case .offline: return .red
    case .notConfigured: return .orange
    case .checking, .unknown: return .secondary.opacity(0.5)
    }
  }
}
