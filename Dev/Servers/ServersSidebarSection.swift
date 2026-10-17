//
//  ServersSidebarSection.swift
//  Dev
//

import ComponentKit
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

  /// "2 servers · 1 online", or "None connected".
  private var meta: [String] {
    let count = store.servers.count
    guard count > 0 else { return ["None connected"] }
    let online = store.servers.filter { store.statuses[$0.id]?.isOnline == true }.count
    return ["\(count) server\(count == 1 ? "" : "s")", "\(online) online"]
  }

  var body: some View {
    KitSection("Localization Servers", meta: meta, systemImage: "server.rack", hue: .gray) {
      if let problem = store.alert {
        Label(problem, systemImage: "exclamationmark.triangle.fill")
          .kitFont(.caption)
          .foregroundStyle(Hue.orange.text)
          .padding(.horizontal, 6)
      }
      if store.servers.isEmpty {
        Button {
          onEdit(.add)
        } label: {
          SidebarRow("Add Connection", systemImage: "plus.circle")
            .foregroundStyle(.kitSecondary)
        }
        .buttonStyle(.plain)
        .help("Connect a server that serves its strings through the Localization Server API")
      } else {
        ForEach(store.servers) { row in
          ServerSidebarRow(row: row, status: store.statuses[row.id] ?? .unknown)
            .kitContextMenu {
              Button("Check Now", systemImage: "arrow.clockwise") { Task { await store.check(id: row.id) } }
              Button("Edit…", systemImage: "pencil") { onEdit(.edit(row.id)) }
              Divider()
              Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = row }
            }
        }
      }
    } accessory: {
      Button("Add Localization Server…", systemImage: "plus") { onEdit(.add) }
        .buttonStyle(.kitIcon)
        .help("Add a Localization Server")
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
    SidebarRow(value: SidebarSelection.server(row.id), row.name, subtitle: row.hostLabel, systemImage: "server.rack") {
      StatusDot(hue: dotHue, isHollow: status == .checking || status == .unknown)
        .help(status.short)
    }
    .help("\(row.endpoint)\n\(row.keySource.label)\n\(status.short)")
  }

  private var dotHue: Hue {
    switch status {
    case .online: return .green
    case .offline: return .red
    case .notConfigured: return .orange
    case .checking, .unknown: return .gray
    }
  }
}
