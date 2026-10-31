//
//  StorageView.swift
//  Dev
//

import Foundation
import ComponentKit
import SwiftUI

// MARK: - Full Disk Access

/// Says what the scan cannot see and how to let it, or that a rescan would
/// see more now that access is on. Hidden once the scan on screen saw it all.
struct StorageAccessBanner: View {
  @Environment(StorageStore.self) private var store

  var body: some View {
    if !store.hasFullDiskAccess {
      Banner(
        "Full Disk Access is off",
        message: "Browser profiles, app containers, Mail and Messages attachments, iOS backups and the Trash can't be measured, and macOS may ask about Desktop, Documents and Downloads during a scan.",
        systemImage: "lock.fill", hue: .orange
      ) {
        Button("Open Settings…") { FullDiskAccess.openSettings() }
          .disabled(store.isBusy)
      }
      .padding([.horizontal, .top], KitMetrics.gutter)
    } else if store.rescanWouldSeeMore {
      Banner(
        "Full Disk Access is on",
        message: "The scan on screen was made without it. Rescan to include protected folders.",
        systemImage: "lock.open.fill", hue: .green
      ) {
        Button("Rescan") { store.scan() }
          .disabled(store.isBusy)
      }
      .padding([.horizontal, .top], KitMetrics.gutter)
    }
  }
}

struct StorageSafetyBadge: View {
  let safety: StorageSafety

  var body: some View {
    Chip(safety.title, hue: safety.hue)
      .controlSize(.small)
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
    let admin = items.filter(StorageCleaner.needsRoot)
    let clones = items.filter {
      if case .cloneDuplicates = $0.cleanup { return true }
      return false
    }
    KitSheet(
      title: "Clean \(items.count) items · \(store.selectedBytes.byteString)",
      meta: deleteImmediately ? "Deleted at once, without the Trash." : "Moved to the Trash.",
      systemImage: "trash", hue: .red, width: 560
    ) {
      ScrollView {
        LazyVStack(spacing: KitMetrics.gutter) {
          ForEach(StorageCategory.allCases) { category in
            let inCategory = items.filter { $0.category == category }.sorted { $0.bytes > $1.bytes }
            if !inCategory.isEmpty {
              FormCard(category.title) {
                ForEach(inCategory) { item in
                  HStack {
                    Text(item.title).lineLimit(1)
                    if item.safety == .data {
                      Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Hue.orange.text)
                        .help(StorageSafety.data.help)
                    }
                    Spacer()
                    Text(item.cleanup.verb)
                      .kitFont(.caption)
                    Text(item.bytes.byteString)
                      .monospacedDigit()
                      .frame(width: 80, alignment: .trailing)
                  }
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                }
              }
            }
          }
        }
      }
      .frame(height: 240)
      FormCard {
        if !data.isEmpty {
          FormRow(
            "\(data.count) of these are your data (\(data.reduce(0) { $0 + $1.bytes }.byteString))",
            help: "VMs, models, media, app state. They are not recreated on their own.",
            systemImage: "exclamationmark.triangle.fill", hue: .orange)
        }
        if !admin.isEmpty {
          FormRow(
            "\(admin.count) need your administrator password", help: "macOS asks once for all of them.",
            systemImage: "lock.fill", hue: .gray)
        }
        if !clones.isEmpty {
          FormRow(
            "Identical files become clones of one copy",
            help: "They keep their paths: nothing is removed, and the files are read again first, so it takes a while.",
            systemImage: "square.on.square", hue: .gray)
        }
        if !commands.isEmpty {
          FormRow(
            "\(commands.count) are removed by their own tool",
            help: "simctl, ollama and go remove them; they do not go through the Trash.",
            systemImage: "terminal", hue: .gray)
        }
        FormRow(
          "Delete immediately", help: "Frees the space now instead of moving to the Trash. The Trash is the only way back, so this cannot be undone.",
          systemImage: "trash.slash", hue: .red
        ) {
          Toggle("Delete immediately", isOn: $deleteImmediately)
            .labelsHidden()
            .toggleStyle(.kitSwitch)
        }
      }
    } footer: {
      Button("Cancel", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(deleteImmediately ? "Delete" : "Move to Trash", role: .destructive) {
        dismiss()
        Task { await store.cleanSelection(deleteImmediately: deleteImmediately) }
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(items.isEmpty)
    }
  }
}

// MARK: - Hues

extension StorageSection {
  var hue: Hue {
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
  /// A section's categories share its hue; the ones on their own have theirs.
  var hue: Hue {
    if let section { return section.hue }
    switch self {
    case .virtualMachines: return .indigo
    case .databases: return .teal
    case .media: return .pink
    default: return .gray
    }
  }
}

extension StorageSafety {
  var hue: Hue {
    switch self {
    case .lossless: .teal
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

  /// The toolbar title's status line: what the scan is doing (with the items measured so far), or the sidebar's line.
  var titleStatus: String {
    switch phase {
    case .scanning(let text) where isMeasuringItems:
      return "\(text) \(measuredCount)/\(discoveredCount)"
    case .scanning(let text):
      return text
    case .cleaning, .idle:
      return sidebarStatus
    }
  }

  /// A scan or a clean in flight, with the share of items measured once the scan has counted them: the live icons
  /// (the sidebar row's and the toolbar title's) carry it.
  var workStatus: WorkStatus {
    switch phase {
    case .scanning where isMeasuringItems: .working(progress: Double(measuredCount) / Double(discoveredCount))
    case .scanning, .cleaning: .working
    case .idle: .idle
    }
  }

  /// The scan has counted its items and is measuring them.
  private var isMeasuringItems: Bool { discoveredCount > 0 && measuredCount < discoveredCount }
}
