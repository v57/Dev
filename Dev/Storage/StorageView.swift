//
//  StorageView.swift
//  Dev
//

import AppKit
import ComponentKit
import SwiftUI

// MARK: - Full Disk Access

/// Says what the scan cannot see and how to let it, or that a rescan would
/// see more now that access is on. Hidden once the scan on screen saw it all.
struct StorageAccessBanner: View {
  @Environment(StorageStore.self) private var store

  var body: some View {
    if !store.hasFullDiskAccess {
      banner(
        icon: "lock.fill", tint: .orange,
        title: "Full Disk Access is off",
        message: "Browser profiles, app containers, Mail and Messages attachments, iOS backups and the Trash can't be measured, and macOS may ask about Desktop, Documents and Downloads during a scan.",
        action: "Open Settings…"
      ) {
        FullDiskAccess.openSettings()
      }
    } else if store.rescanWouldSeeMore {
      banner(
        icon: "lock.open.fill", tint: .green,
        title: "Full Disk Access is on",
        message: "The scan on screen was made without it. Rescan to include protected folders.",
        action: "Rescan"
      ) {
        store.scan()
      }
    }
  }

  private func banner(
    icon: String, tint: Color, title: String, message: String, action: String,
    perform: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .foregroundStyle(tint)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.semibold))
        // A line limit, not fixedSize: fixedSize lets the window's minimum-size
        // pass wrap this at near-zero width into a column taller than the screen.
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action, action: perform)
        .disabled(store.isBusy)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(tint.opacity(0.08))
  }
}

struct StorageSafetyBadge: View {
  let safety: StorageSafety

  var body: some View {
    Text(safety.title)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .foregroundStyle(safety.color)
      .background(safety.color.opacity(0.14), in: Capsule())
      .frame(width: 84)
      .help(safety.help)
  }
}

// MARK: - Confirmation

/// The one place anything is removed: what is about to go, by category, with
/// your own data called out, and where it goes (the Trash by default).
struct StorageCleanSheet: View {
  @Environment(StorageStore.self) private var store
  @Environment(\.kitDismiss) private var dismiss
  @State private var deleteImmediately = false

  var body: some View {
    let items = store.selectedItems
    let data = items.filter { $0.safety == .data }
    let commands = items.filter {
      if case .command = $0.cleanup { return true }
      return false
    }
    VStack(alignment: .leading, spacing: 14) {
      Text("Clean \(items.count) items · \(store.selectedBytes.byteString)")
        .font(.title2.weight(.semibold))

      List {
        ForEach(StorageCategory.allCases) { category in
          let inCategory = items.filter { $0.category == category }.sorted { $0.bytes > $1.bytes }
          if !inCategory.isEmpty {
            Section(category.title) {
              ForEach(inCategory) { item in
                HStack {
                  Text(item.title).lineLimit(1)
                  if item.safety == .data {
                    Image(systemName: "exclamationmark.triangle.fill")
                      .foregroundStyle(.orange)
                      .help(StorageSafety.data.help)
                  }
                  Spacer()
                  Text(item.cleanup.verb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Text(item.bytes.byteString)
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
                }
              }
            }
          }
        }
      }
      .frame(minHeight: 240)

      if !data.isEmpty {
        Label(
          "\(data.count) of these are your data (\(data.reduce(0) { $0 + $1.bytes }.byteString)) — VMs, models, media, app state. They are not recreated on their own.",
          systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
      let admin = items.filter(StorageCleaner.needsRoot)
      if !admin.isEmpty {
        Label(
          "\(admin.count) need your administrator password — macOS asks once for all of them.",
          systemImage: "lock.fill")
          .foregroundStyle(.secondary)
      }
      let clones = items.filter {
        if case .cloneDuplicates = $0.cleanup { return true }
        return false
      }
      if !clones.isEmpty {
        Label(
          "Identical files become clones of one copy and keep their paths: nothing is removed, and the files are read again first, so it takes a while.",
          systemImage: "square.on.square")
          .foregroundStyle(.secondary)
      }
      if !commands.isEmpty {
        Label(
          "\(commands.count) are removed by their own tool (simctl, ollama, go) and do not go through the Trash.",
          systemImage: "terminal")
          .foregroundStyle(.secondary)
      }
      Toggle("Delete immediately instead of moving to the Trash", isOn: $deleteImmediately)
        .help("Frees the space now. The Trash is the only way back, so this cannot be undone.")

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(deleteImmediately ? "Delete" : "Move to Trash", role: .destructive) {
          dismiss()
          Task { await store.cleanSelection(deleteImmediately: deleteImmediately) }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(items.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 560, height: 520)
  }
}

// MARK: - Colors

extension StorageSection {
  var color: Color {
    switch self {
    case .development: .orange
    case .ai: .purple
    case .installed: .blue
    case .other: .teal
    case .ci: .indigo
    }
  }
}

extension StorageCategory {
  /// A section's categories share its color; the ones on their own have theirs.
  var color: Color {
    if let section { return section.color }
    switch self {
    case .virtualMachines: return .indigo
    case .databases: return .cyan
    case .media: return .pink
    default: return .gray
    }
  }
}

extension StorageSidebarEntry {
  var color: Color {
    switch self {
    case .section(let section): section.color
    case .category(let category): category.color
    }
  }
}

extension StorageSafety {
  var color: Color {
    switch self {
    case .lossless: .mint
    case .cache: .green
    case .rebuildable: .blue
    case .data: .orange
    }
  }
}

// MARK: - Sidebar row

/// The sidebar's Storage row: what a clean would free, or the scan's progress.
struct StorageSidebarRow: View {
  @Environment(StorageStore.self) private var store

  var body: some View {
    SidebarRow(value: SidebarSelection.storage, "Storage") {
      LiveIcon(systemImage: "internaldrive", hue: .gray, status: store.workStatus, size: 18)
    } trailing: {
      Text(store.sidebarStatus).foregroundStyle(.kitSecondary).lineLimit(1)
    }
    .accessibilityIdentifier("sidebar.storage")
  }
}

extension StorageStore {
  /// One line for the sidebar: what the scan found to free, or what the volume has free.
  var sidebarStatus: String {
    switch phase {
    case .scanning:
      return "Scanning…"
    case .cleaning:
      return "Cleaning…"
    case .idle:
      let safe = recommendedBytes
      if hasResults, safe > 0 { return "\(safe.byteString) to free" }
      return "\(volumeAvailable.byteString) free"
    }
  }

  /// A scan or a clean in flight: the row's icon carries it.
  var workStatus: WorkStatus {
    switch phase {
    case .scanning, .cleaning: .working
    case .idle: .idle
    }
  }
}
