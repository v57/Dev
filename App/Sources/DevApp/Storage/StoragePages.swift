//
//  StoragePages.swift
//  Dev
//

import Foundation
import ComponentKit
import DevDesktop
import SwiftUI

// MARK: - Storage

/// Where the Storage tool is: Smart Scan, one category, or the Languages view.
nonisolated enum StoragePage: Hashable, Sendable {
  case smartScan
  case category(StorageCategory)
  case languages
}

/// The Storage tool, laid out like a cleaner: the categories on the left
/// (Smart Scan first), the open category's groups in the middle and the open
/// group's files on the right, with one round Clean button floating at the foot.
/// Smart Scan ticks what is safe — caches and what tools rebuild — and never
/// your own data; the Uninstaller and Languages pages remove apps and language
/// versions with everything they keep.
struct StorageView: View {
  @Environment(StorageStore.self) private var store
  @State private var page: StoragePage = StorageView.launchPage
  @State private var isConfirming = false

  private static var launchPage: StoragePage {
    switch LaunchOptions.storagePage {
    case "languages": .languages
    case let name?: StorageCategory(rawValue: name).map(StoragePage.category) ?? .smartScan
    case nil: .smartScan
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      StorageAccessBanner()
      if store.hasResults || store.isScanning {
        HStack(spacing: 0) {
          StorageNav(page: $page)
            .frame(width: 220)
          Divider()
          ZStack(alignment: .bottom) {
            detail
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.phase != .cleaning {
              StorageActionButton {
                isConfirming = true
              }
              .padding(.bottom, 18)
            }
          }
        }
      } else {
        EmptyState(
          systemImage: "internaldrive", title: "See What Fills This \(KitDevice.name)",
          message: "Scan sorts the disk into Xcode, Android, virtual machines, AI models, Node, apps, language versions and more. Nothing is removed until you pick it and confirm."
        ) {
          Button("Scan") { store.scan() }
            .buttonStyle(.kitPrimary)
        }
      }
    }
    .toolbar { StorageToolbar() }
    .kitSheet(isPresented: $isConfirming) {
      StorageCleanSheet()
    }
    .kitNotice(
      store.report.map(Self.reportTitle) ?? "",
      isPresented: Binding(get: { store.report != nil }, set: { if !$0 { store.report = nil } }),
      message: store.report.map(Self.reportMessage), systemImage: "trash",
      hue: store.report?.failures.isEmpty == false ? .orange : .green,
      buttons: reportButtons)
    .kitNotice(
      "Couldn't scan system folders",
      isPresented: Binding(get: { store.systemScanError != nil }, set: { if !$0 { store.systemScanError = nil } }),
      message: store.systemScanError)
    .task {
      if LaunchOptions.isScreenshotMode, LaunchOptions.open == "storageClean" { isConfirming = true }
    }
    .task(id: store.lastScan) {
      let runners = await Task.detached { StorageStore.workflowRunnerNames() }.value
      store.applyLocks(runnerNames: runners)
      store.selectRecommendedIfNew()
    }
    .frame(minWidth: 860, minHeight: 480)
  }

  @ViewBuilder
  private var detail: some View {
    switch page {
    case .smartScan:
      SmartScanPage(page: $page)
    case .languages:
      LanguagesPage()
    case .category(.applications):
      UninstallerPage()
    case .category(.virtualMachines):
      MachinesPage()
    case .category(let category):
      GroupsPage(category: category)
        .id(category)
    }
  }

  /// The clean report's ways out before OK: the Trash when something went there, the setting a failure needs.
  private var reportButtons: [KitConfirmationButton] {
    var buttons: [KitConfirmationButton] = []
    if (store.report?.trashedBytes ?? 0) > 0 {
      buttons.append(KitConfirmationButton("Open Trash") { store.openTrash() })
    }
    if store.report?.failures.contains(where: { $0.message.contains("App Management") }) == true {
      buttons.append(KitConfirmationButton("Open App Management") { FullDiskAccess.openAppManagementSettings() })
    }
    return buttons
  }

  nonisolated static func reportTitle(_ report: StorageCleanReport) -> String {
    report.cleanedIDs.isEmpty ? "Nothing was cleaned" : "\(report.cleanedBytes.byteString) freed"
  }

  nonisolated static func reportMessage(_ report: StorageCleanReport) -> String {
    var lines: [String] = []
    if report.trashedBytes > 0 {
      lines.append("\(report.trashedBytes.byteString) is in the Trash — empty it to free the space. Your tools rebuild what they need on their next run.")
    }
    if !report.failures.isEmpty {
      lines.append("Not cleaned:")
      lines += report.failures.prefix(8).map { "• \($0.title): \($0.message)" }
      if report.failures.count > 8 { lines.append("…and \(report.failures.count - 8) more") }
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - Toolbar

/// Cancel while a scan can stop, or Export, Scan System Folders and Scan Again. The scan's progress is the title's:
/// its live icon and status line (`StorageStore.titleStatus`).
private struct StorageToolbar: ToolbarContent {
  @Environment(StorageStore.self) private var store

  var body: some ToolbarContent {
    if store.phase == .idle || store.canCancelScan {
      KitToolbarItem(placement: .primaryAction) {
        ToolGroup {
          if store.phase == .idle {
            if store.hasResults {
              Button("Export Selection…", systemImage: "square.and.arrow.up") { store.exportSelection() }
                .kitHelp("Export Selection", meta: "Saves what is picked, and what is not and why, as a Markdown report")
              Button("Scan System Folders…", systemImage: "lock.shield") { store.scanSystem() }
                .kitHelp("Scan System Folders", meta: "Asks for your administrator password, then measures the whole disk as root: system logs and caches, other accounts, and whatever no category explains")
            }
            Button(store.hasResults ? "Scan Again" : "Scan", systemImage: "arrow.clockwise") { store.scan() }
          } else {
            Button("Cancel", systemImage: "xmark") { store.cancelScan() }
          }
        }
      }
    }
  }
}

// MARK: - Navigation

/// Smart Scan, then each section's categories with what is picked in each.
private struct StorageNav: View {
  @Binding var page: StoragePage
  @Environment(StorageStore.self) private var store

  var body: some View {
    KitList(selection: $page) {
      SidebarRow(value: StoragePage.smartScan, "Smart Scan", systemImage: "sparkles", hue: .accent) {
        trailing(store.selectedBytes > 0 ? store.selectedBytes.byteString : nil)
      }
      ForEach(StorageSection.allCases) { section in
        let categories = section.categories.filter { store.hasItems($0) || $0 == .applications }
        if !categories.isEmpty {
          KitSection(section.title, systemImage: section.systemImage, hue: section.hue) {
            ForEach(categories) { category in
              SidebarRow(value: StoragePage.category(category), category.title, systemImage: category.systemImage,
                         hue: section.hue) {
                trailing(trailing(category))
              }
              if category == .applications {
                SidebarRow(value: StoragePage.languages, "Languages",
                           systemImage: "chevron.left.forwardslash.chevron.right", hue: section.hue)
              }
            }
          }
        }
      }
    }
    .kitSectionStyle(.plain)
    .kitPane(.secondary)
  }

  @ViewBuilder
  private func trailing(_ text: String?) -> some View {
    if let text {
      Text(text).kitFont(.caption).monospacedDigit().foregroundStyle(.kitSecondary)
    }
  }

  private func trailing(_ category: StorageCategory) -> String? {
    let items = store.items(in: category)
    if category == .applications { return items.isEmpty ? nil : "\(items.count) apps" }
    let picked = items.filter(store.isSelected).reduce(0) { $0 + $1.bytes }
    return picked > 0 ? picked.byteString : store.bytes(in: category).byteString
  }
}

// MARK: - Shared pieces

/// Off, on or mixed: the kit's checkbox for picking what to clean.
struct StorageCheck: View {
  enum State { case off, on, mixed }
  let state: State
  var disabled = false
  let action: () -> Void

  var body: some View {
    Toggle("Pick", isOn: Binding(get: { state != .off }, set: { _ in action() }))
      .labelsHidden()
      .toggleStyle(.kitCheckbox)
      .kitMixed(state == .mixed)
      .disabled(disabled)
  }
}

extension StorageStore {
  /// The check state of a set of items: the cleanable, unlocked ones count.
  func checkState(_ items: [StorageItem]) -> StorageCheck.State {
    let pickable = items.filter { $0.cleanup.isCleanable && !$0.isLocked }
    let on = pickable.filter(isSelected).count
    if on == 0 { return .off }
    return on == pickable.count ? .on : .mixed
  }

  /// Unticks everything ticked, or ticks the recommended ones (else all).
  func toggleGroup(_ items: [StorageItem], preferring prefer: (StorageItem) -> Bool = \.isRecommended) {
    let pickable = items.filter { $0.cleanup.isCleanable && !$0.isLocked }
    if pickable.contains(where: isSelected) {
      setSelected(false, pickable)
    } else {
      let preferred = pickable.filter(prefer)
      setSelected(true, preferred.isEmpty ? pickable : preferred)
    }
  }
}

/// The round Clean button with the total picked, floating over the pages.
private struct StorageActionButton: View {
  let action: () -> Void
  @Environment(StorageStore.self) private var store

  /// "Uninstall" when every pick is an app or a language version, else "Clean".
  private func label(_ items: [StorageItem]) -> String {
    guard !items.isEmpty else { return "Clean" }
    let uninstalls = items.allSatisfy { item in
      item.category == .applications || StorageLanguages.classify(item)?.isVersion == true
        || item.id.hasPrefix("runtime:") || item.parent.map(store.selection.contains) == true
    }
    return uninstalls ? "Uninstall" : "Clean"
  }

  var body: some View {
    let items = store.selectedItems
    let none = items.isEmpty
    let label = label(items)
    HStack(spacing: 14) {
      Button(action: action) {
        Text(label).kitFont(.headline).fontWeight(.bold)
      }
      .buttonStyle(KitRoundButtonStyle(prominent: true, size: 72))
      .disabled(none || store.isBusy)
      .keyboardShortcut(.return, modifiers: .command)
      .kitHelp(label, shortcut: "⌘↩", meta: none ? "Tick what to remove" : store.selectedBytes.byteString)
      VStack(alignment: .leading, spacing: 1) {
        Text(none ? "Nothing picked" : store.selectedBytes.byteString)
          .kitFont(.title3).fontWeight(.bold).monospacedDigit()
        Text(none ? "Tick what to remove" : "\(items.count) items from every category")
          .kitFont(.caption)
          .foregroundStyle(.kitSecondary)
      }
    }
    .padding(.leading, 8)
    .padding(.trailing, 20)
    .padding(.vertical, 8)
    .kitSurface(.floating, cornerRadius: 44)
  }
}

/// One file of an item group: check, title, detail, path, size, Show in Finder.
struct StorageFileRow: View {
  let item: StorageItem
  /// Indented under the item it is part of.
  var nested = false
  @Environment(StorageStore.self) private var store

  var body: some View {
    let cleanup = store.cleanup(of: item)
    HStack(spacing: 12) {
      StorageCheck(state: store.isSelected(item) ? .on : .off,
                   disabled: !item.cleanup.isCleanable || item.isLocked || store.isBusy) {
        store.setSelected(!store.isSelected(item), [item])
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(item.title).fontWeight(.medium).lineLimit(1).layoutPriority(1)
          if let reason = item.lockReason {
            Text(reason).kitFont(.caption).foregroundStyle(Hue.accent.text)
          } else if let detail = item.detail {
            Text(detail).kitFont(.caption).foregroundStyle(.kitSecondary).lineLimit(1)
          }
        }
        Text(item.primaryPath.abbreviatingHome)
          .kitFont(.monoSmall)
          .foregroundStyle(.kitSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 8)
      if case .command(_, _, let verb) = cleanup {
        Text(verb).kitFont(.caption).foregroundStyle(.kitSecondary)
      } else if case .cloneDuplicates = cleanup {
        Text(cleanup.verb).kitFont(.caption).foregroundStyle(.kitSecondary)
      } else if case .revealOnly(let reason) = cleanup {
        Image(systemName: "info.circle").foregroundStyle(.kitSecondary).help(reason)
      }
      Text(item.bytes.byteString)
        .monospacedDigit()
        .frame(width: 80, alignment: .trailing)
      Button {
        store.reveal(item)
      } label: {
        Image(systemName: "magnifyingglass")
      }
      .buttonStyle(.kitIcon)
      .help("Show in Finder")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Hue.accent.soft(store.isSelected(item) ? 0.07 : 0), in: RoundedRectangle(cornerRadius: KitMetrics.radiusLarge))
    .padding(.leading, nested ? 28 : 0)
    .opacity(item.isLocked ? 0.6 : 1)
    .kitContextMenu {
      KitOpenWithRow([
        KitOpenApp(
          KitDesktop.fileManagerName, icon: KitDesktop.fileManagerIcon,
          words: "Show in \(KitDesktop.fileManagerName)", id: "kit.files"
        ) { store.reveal(item) }
      ])
      Button("Copy Path", systemImage: "doc.on.doc") {
        KitPasteboard.copy(item.primaryPath)
      }
    }
  }
}

// MARK: - Smart Scan

/// The front page: the disk as an activity ring by section, how much is safe
/// to clean, a row per section with what Smart Scan picked in it, and pointers
/// to the apps and language versions nothing uses.
private struct SmartScanPage: View {
  @Binding var page: StoragePage
  @Environment(StorageStore.self) private var store
  @State private var unusedApps: [StorageItem] = []
  @State private var unusedVersions: [StorageItem] = []

  var body: some View {
    ScrollView {
      KitLazyStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("\(store.recommendedBytes.byteString) is safe to clean")
            .kitFont(.largeTitle)
          Text("Caches and build output, which your tools make again on their own. Your own data, what you installed and scratch space that may be in use are never picked for you.")
            .kitFont(.title3).fontWeight(.regular)
            .foregroundStyle(.kitSecondary)
            .fixedSize(horizontal: false, vertical: true)
          MeterBar(segments: segments, total: Double(store.volumeTotal))
            .padding(.top, 6)
          MetaLine(
            ["\(used.byteString) used of \(store.volumeTotal.byteString)"]
              + (store.lastScan.map { ["Scanned \($0.kitFormatted(.ago))"] } ?? []))
        }
        VStack(spacing: 0) {
          ForEach(Array(sections.enumerated()), id: \.element) { index, section in
            if index > 0 { Divider() }
            sectionRow(section)
          }
        }
        .kitSurface(.card)
        if !store.scratchItems.isEmpty {
          ScratchPicker()
        }
        HStack(alignment: .top, spacing: 12) {
          if !unusedApps.isEmpty {
            tip(
              "\(unusedApps.count) apps unused for months · \(unusedApps.reduce(0) { $0 + $1.bytes }.byteString)",
              unusedApps.prefix(4).map(\.title).joined(separator: ", "), symbol: "app.badge", button: "Uninstaller"
            ) { page = .category(.applications) }
          }
          if !unusedVersions.isEmpty {
            tip(
              "\(unusedVersions.count) language versions no project uses · \(unusedVersions.reduce(0) { $0 + $1.bytes }.byteString)",
              unusedVersions.prefix(4).map(\.title).joined(separator: ", "), symbol: "chevron.left.forwardslash.chevron.right",
              button: "Languages"
            ) { page = .languages }
          }
        }
      }
      .padding(24)
      .padding(.bottom, 100)
    }
    .task(id: store.lastScan) {
      let apps = store.items(in: .applications)
      let items = store.items
      let projects = KnownProjects.read().map { ($0.name, URL(fileURLWithPath: $0.root)) }
      let (unused, languages) = await Task.detached(priority: .utility) {
        (apps.filter { AppInfo.read($0.primaryPath).isUnused }, StorageLanguages.languages(from: items, projects: projects))
      }.value
      unusedApps = unused.sorted { $0.bytes > $1.bytes }
      unusedVersions = languages.flatMap(\.unusedVersions)
    }
  }

  private var sections: [StorageSection] {
    StorageSection.allCases.filter { store.bytes(in: .section($0)) > 0 }
  }

  /// The disk by section, then what is used that no section measured.
  private var segments: [MeterSegment] {
    var parts = sections.map { section in
      let bytes = store.bytes(in: .section(section))
      return MeterSegment(
        section.title, value: Double(bytes), hue: section.hue, systemImage: section.systemImage,
        valueText: bytes.byteString)
    }
    let other = used - sections.reduce(0) { $0 + store.bytes(in: .section($1)) }
    if other > 0 { parts.append(MeterSegment("Not in a category", value: Double(other), hue: .gray, valueText: other.byteString)) }
    return parts
  }

  private var used: Int64 { max(0, store.volumeTotal - store.volumeAvailable) }

  private func sectionRow(_ section: StorageSection) -> some View {
    let items = section.categories.flatMap { store.items(in: $0) }
    let recommended = items.filter(\.isRecommended)
    let picked = items.filter(store.isSelected).reduce(0) { $0 + $1.bytes }
    return HStack(spacing: 14) {
      StorageCheck(state: store.checkState(recommended), disabled: recommended.isEmpty || store.isBusy) {
        store.toggleGroup(recommended)
      }
      Tile(systemImage: section.systemImage, hue: section.hue, size: 36, style: .solid)
      VStack(alignment: .leading, spacing: 2) {
        Text(section.title).fontWeight(.semibold)
        Text(section.categories.filter(store.hasItems).map(\.title).joined(separator: ", "))
          .kitFont(.callout)
          .foregroundStyle(.kitSecondary)
          .lineLimit(1)
      }
      Spacer()
      Text(picked.byteString)
        .kitFont(.title3).fontWeight(.bold).monospacedDigit()
        .foregroundStyle(picked > 0 ? .kitLabel : .kitSecondary)
      Button("Review") {
        if let first = section.categories.first(where: store.hasItems) { page = .category(first) }
      }
      .buttonStyle(.kitPlain)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private func tip(_ title: String, _ names: String, symbol: String, button: String, action: @escaping () -> Void) -> some View {
    HStack(spacing: 12) {
      Tile(systemImage: symbol, hue: .orange, size: 36, style: .solid)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).fontWeight(.semibold)
        Text(names).kitFont(.callout).foregroundStyle(.kitSecondary).lineLimit(1)
      }
      Spacer()
      Button(button, action: action)
        .buttonStyle(.kit)
    }
    .padding(14)
    .frame(maxWidth: .infinity)
    .background(Hue.orange.soft(0.09), in: RoundedRectangle(cornerRadius: KitMetrics.radiusXL))
  }
}

/// Agents' scratchpads and temp folders, picked apart from Smart Scan by how
/// long they have gone untouched: what changed lately may still be in use.
private struct ScratchPicker: View {
  @Environment(StorageStore.self) private var store

  var body: some View {
    let items = store.scratchItems
    let picked = items.filter(store.isSelected)
    HStack(spacing: 14) {
      Tile(systemImage: "clock.arrow.circlepath", hue: .teal, size: 36, style: .solid)
      VStack(alignment: .leading, spacing: 2) {
        Text("Scratch and temp folders · \(items.reduce(0) { $0 + $1.bytes }.byteString)").fontWeight(.semibold)
        Text(picked.isEmpty
          ? "Agent scratchpads and temp files, \(items.count) folders. Some may be in use, so pick by age."
          : "\(picked.count) of \(items.count) folders picked · \(picked.reduce(0) { $0 + $1.bytes }.byteString)")
          .kitFont(.callout)
          .foregroundStyle(.kitSecondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      KitMenuButton(store.scratchPick?.title ?? "Pick") {
        KitMenuOptions(
          selection: Binding(get: { store.scratchPick }, set: { if let pick = $0 { store.pickScratch(pick) } }),
          segments: StorageStore.ScratchPick.allCases.map { KitSegment($0.title, value: Optional($0)) })
      }
      .disabled(store.isBusy)
    }
    .padding(14)
    .kitSurface(.card)
  }
}

// MARK: - A category: groups and files

/// One category: its groups in the middle, the open group's files (or, for
/// AI models, cards) on the right.
private struct GroupsPage: View {
  let category: StorageCategory
  @Environment(StorageStore.self) private var store
  @State private var groupName: String?

  var body: some View {
    let groups = store.groups(in: category)
    let current = groups.first { $0.name == groupName } ?? groups.first
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Text(category.title).kitFont(.title2).fontWeight(.bold)
          Text(category.subtitle).kitFont(.callout).foregroundStyle(.kitSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        let all = groups.flatMap(\.items)
        HStack {
          Button(all.contains(where: store.isSelected) ? "Deselect All" : "Select Recommended") {
            store.toggleGroup(all)
          }
          .disabled(all.isEmpty || store.isBusy)
          Spacer()
          Text("Sorted by size").kitFont(.caption).foregroundStyle(.kitSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        if category == .system, store.systemScanDate == nil, !store.isBusy {
          Button("Scan System Folders…") { store.scanSystem() }
            .padding(.horizontal, 16)
        }
        ScrollView {
          VStack(spacing: 2) {
            ForEach(groups, id: \.name) { group in
              groupRow(group, selected: current?.name == group.name)
            }
          }
          .padding(.horizontal, 8)
          .padding(.bottom, 110)
        }
      }
      .frame(width: 320)
      Divider()
      if let current {
        files(current)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .kitPane(.secondary)
      } else {
        EmptyState(
          systemImage: store.isScanning ? "hourglass" : "checkmark.circle",
          title: store.isScanning ? "Measuring…" : "Nothing Here",
          message: store.isScanning ? "Items appear as their sizes land." : "Nothing of this kind takes space on this Mac.")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func groupRow(_ group: (name: String, bytes: Int64, items: [StorageItem]), selected: Bool) -> some View {
    let picked = group.items.filter(store.isSelected).reduce(0) { $0 + $1.bytes }
    let safety = group.items.map(\.safety).max() ?? .cache
    return HStack(spacing: 10) {
      StorageCheck(state: store.checkState(group.items), disabled: store.isBusy || group.items.allSatisfy(\.isLocked)) {
        store.toggleGroup(group.items)
      }
      Button {
        groupName = group.name
      } label: {
        HStack(spacing: 10) {
          Tile(systemImage: category.systemImage, hue: category.hue, size: 36, style: .solid)
          VStack(alignment: .leading, spacing: 2) {
            Text(group.name).fontWeight(selected ? .semibold : .medium).lineLimit(1)
            Text("\(safety.title) · \(group.items.count) item\(group.items.count == 1 ? "" : "s")")
              .kitFont(.caption)
              .foregroundStyle(.kitSecondary)
          }
          Spacer(minLength: 4)
          Text(picked > 0 && picked < group.bytes ? "\(picked.byteString) of \(group.bytes.byteString)" : group.bytes.byteString)
            .kitFont(.callout).fontWeight(.semibold).monospacedDigit()
            .foregroundStyle(picked > 0 ? .kitLabel : .kitSecondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 8)
    .frame(height: 56)
    .background(Hue.accent.soft(selected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: KitMetrics.radiusLarge))
  }

  @ViewBuilder
  private func files(_ group: (name: String, bytes: Int64, items: [StorageItem])) -> some View {
    let safety = group.items.map(\.safety).max() ?? .cache
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text(group.name).kitFont(.title2).fontWeight(.bold)
        HStack(spacing: 8) {
          StorageSafetyBadge(safety: safety)
          Text(group.bytes.byteString).kitFont(.callout).foregroundStyle(.kitSecondary)
        }
        Text(about(safety))
          .foregroundStyle(.kitSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)
      HStack {
        Text("\(group.items.count) item\(group.items.count == 1 ? "" : "s")")
        Spacer()
        Text("Sort by Size")
      }
      .kitFont(.caption)
      .foregroundStyle(.kitSecondary)
      .padding(.horizontal, 20)
      .padding(.bottom, 6)
      ScrollView {
        if category == .aiModels {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            ForEach(group.items) { ModelCard(item: $0) }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 110)
        } else {
          // A group can hold hundreds of folders: rows are built as they scroll in.
          LazyVStack(spacing: 2) {
            ForEach(nested(group.items), id: \.item.id) { StorageFileRow(item: $0.item, nested: $0.nested) }
          }
          .padding(.horizontal, 12)
          .padding(.bottom, 110)
        }
      }
    }
  }

  /// The items with the ones that are part of another (a runtime's
  /// simulators) right under it, indented; a parent sorts by its size with theirs.
  private func nested(_ items: [StorageItem]) -> [(item: StorageItem, nested: Bool)] {
    let ids = Set(items.map(\.id))
    let children = Dictionary(grouping: items.filter { $0.parent.map(ids.contains) == true }) { $0.parent ?? "" }
    guard !children.isEmpty else { return items.map { ($0, false) } }
    func total(_ item: StorageItem) -> Int64 {
      item.bytes + (children[item.id] ?? []).reduce(0) { $0 + $1.bytes }
    }
    return items.filter { $0.parent.map(ids.contains) != true }
      .sorted { total($0) > total($1) }
      .flatMap { item in [(item, false)] + (children[item.id] ?? []).map { ($0, true) } }
  }

  private func about(_ safety: StorageSafety) -> String {
    switch safety {
    case .lossless:
      return "Copies of the same files. They become clones that share one copy's space and stay where they are, so nothing is removed and Smart Scan picks them."
    case .cache:
      return "Files kept to work faster. The tool that owns them fills them again on its own, so Smart Scan picks them."
    case .rebuildable:
      return "Build output and downloads your tools make again the next time they are needed, which takes a little longer once."
    case .data:
      return "Your own data: nothing brings it back on its own, so Dev never picks it. Look before you tick."
    }
  }
}

/// An AI model as a card: its name, what kind of model, size and last use.
private struct ModelCard: View {
  let item: StorageItem
  @Environment(StorageStore.self) private var store

  var body: some View {
    let on = store.isSelected(item)
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Text(item.title)
          .kitFont(.mono).fontWeight(.semibold)
          .lineLimit(3)
        Spacer()
        StorageCheck(state: on ? .on : .off, disabled: !item.cleanup.isCleanable || store.isBusy) {
          store.setSelected(!on, [item])
        }
      }
      if let detail = item.detail {
        Chip(detail, hue: .purple)
      }
      Text(item.bytes.byteString)
        .kitFont(.title2).fontWeight(.bold).monospacedDigit()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .kitSurface(.card)
    .overlay { if on { RoundedRectangle(cornerRadius: KitMetrics.radiusCard, style: .continuous).strokeBorder(Hue.accent.fill, lineWidth: 2) } }
    .kitContextMenu { Button("Show in Finder", systemImage: "folder") { store.reveal(item) } }
  }
}

// MARK: - Uninstaller

/// What Dev knows about an installed app beyond its size: version, where it
/// came from, when it was last opened.
nonisolated struct AppInfo: Sendable {
  var version: String?
  var source = "Downloaded"
  var lastUsed: Date?
  var isDeveloperTool = false

  /// Not opened for half a year (or never, as far as Spotlight knows).
  var isUnused: Bool {
    guard let lastUsed else { return false }
    return Date().timeIntervalSince(lastUsed) > 180 * 86_400
  }

  var lastUsedText: String {
    guard let lastUsed else { return "Never opened" }
    let days = Date().timeIntervalSince(lastUsed) / 86_400
    if days < 1 { return "Opened today" }
    if days < 7 { return "Opened this week" }
    return "Last opened \(lastUsed.formatted(.relative(presentation: .named)))"
  }

  static func read(_ bundlePath: String) -> AppInfo {
    var info = AppInfo()
    let plist = NSDictionary(contentsOfFile: bundlePath + "/Contents/Info.plist") as? [String: Any] ?? [:]
    info.version = plist["CFBundleShortVersionString"] as? String
    info.isDeveloperTool = (plist["LSApplicationCategoryType"] as? String) == "public.app-category.developer-tools"
    if FileManager.default.fileExists(atPath: bundlePath + "/Contents/_MASReceipt") {
      info.source = "App Store"
    } else if isHomebrewCask(bundlePath) {
      info.source = "Homebrew cask"
    }
    if let date = DevDesktop.lastUsed(bundlePath) {
      info.lastUsed = date
    }
    return info
  }

  private static func isHomebrewCask(_ bundlePath: String) -> Bool {
    let name = (bundlePath as NSString).lastPathComponent
    for caskroom in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
      guard let casks = try? FileManager.default.contentsOfDirectory(atPath: caskroom) else { continue }
      for cask in casks {
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: "\(caskroom)/\(cask)")) ?? []
        for version in versions where FileManager.default.fileExists(atPath: "\(caskroom)/\(cask)/\(version)/\(name)") {
          return true
        }
      }
    }
    return false
  }
}

/// The Uninstaller: apps, least recently opened first; the open app with
/// every file it keeps, which can go whole (uninstall) or without the app
/// itself (reset).
private struct UninstallerPage: View {
  @Environment(StorageStore.self) private var store
  @State private var infos: [String: AppInfo] = [:]
  @State private var filter = "all"
  @State private var appID: String?

  var body: some View {
    let apps = filtered(store.items(in: .applications))
    let current = apps.first { $0.id == appID } ?? apps.first
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Uninstaller").kitFont(.title2).fontWeight(.bold)
          let unused = store.items(in: .applications).filter { infos[$0.id]?.isUnused == true }.count
          Text("\(store.items(in: .applications).count) apps · \(unused) unused for 6 months or more")
            .kitFont(.callout).foregroundStyle(.kitSecondary)
        }
        .padding(16)
        KitSegmented(selection: $filter, options: [("All", "all"), ("Unused", "unused"), ("Large", "large"), ("Developer", "dev")])
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
        .padding(.bottom, 8)
        ScrollView {
          VStack(spacing: 2) {
            ForEach(apps) { app in appRow(app, selected: current?.id == app.id) }
          }
          .padding(.horizontal, 8)
          .padding(.bottom, 110)
        }
      }
      .frame(width: 320)
      Divider()
      if let current {
        AppDetail(app: current, info: infos[current.id] ?? AppInfo())
          .id(current.id)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .kitPane(.secondary)
      } else {
        EmptyState(systemImage: "app.dashed", title: "No Apps")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: store.lastScan) {
      let paths = store.items(in: .applications).map { ($0.id, $0.primaryPath) }
      infos = await Task.detached(priority: .utility) {
        Dictionary(uniqueKeysWithValues: paths.map { ($0.0, AppInfo.read($0.1)) })
      }.value
    }
  }

  private func filtered(_ apps: [StorageItem]) -> [StorageItem] {
    let kept: [StorageItem]
    switch filter {
    case "unused": kept = apps.filter { infos[$0.id]?.isUnused == true }
    case "large": kept = apps.filter { $0.bytes >= 2_000_000_000 }
    case "dev": kept = apps.filter { infos[$0.id]?.isDeveloperTool == true }
    default: kept = apps
    }
    return kept.sorted {
      let a = infos[$0.id]?.lastUsed ?? .distantPast, b = infos[$1.id]?.lastUsed ?? .distantPast
      return a == b ? $0.bytes > $1.bytes : a < b
    }
  }

  private func appRow(_ app: StorageItem, selected: Bool) -> some View {
    let info = infos[app.id]
    return HStack(spacing: 10) {
      StorageCheck(state: store.isSelected(app) ? (store.partialPaths[app.id] == nil ? .on : .mixed) : .off,
                 disabled: store.isBusy) {
        store.setSelected(!store.isSelected(app), [app])
      }
      Button {
        appID = app.id
      } label: {
        HStack(spacing: 10) {
          KitAppIcon(image: KitDesktop.icon(forFile: app.primaryPath), size: 38, isShaped: true)
          VStack(alignment: .leading, spacing: 2) {
            Text(app.title).fontWeight(selected ? .semibold : .medium).lineLimit(1)
            Text(info?.lastUsedText ?? " ")
              .kitFont(.caption)
              .foregroundStyle(info?.isUnused == true ? AnyShapeStyle(Hue.orange.text) : AnyShapeStyle(.kitSecondary))
          }
          Spacer(minLength: 4)
          Text(app.bytes.byteString)
            .kitFont(.callout).fontWeight(.semibold).monospacedDigit()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 8)
    .frame(height: 56)
    .background(Hue.accent.soft(selected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: KitMetrics.radiusLarge))
  }
}

/// One app: its icon, version, source and last use, where its space goes, and
/// each of its files with its own check.
private struct AppDetail: View {
  let app: StorageItem
  let info: AppInfo
  @Environment(StorageStore.self) private var store

  var body: some View {
    let parts = breakdown
    let total = Int64(parts.reduce(0) { $0 + $1.value })
    let anyOn = store.isSelected(app)
    let appOn = store.isPathSelected(app.primaryPath, in: app)
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 16) {
          KitAppIcon(image: KitDesktop.icon(forFile: app.primaryPath), size: 72, isShaped: true)
          VStack(alignment: .leading, spacing: 4) {
            Text(app.title).kitFont(.title1).fontWeight(.bold)
            Text(["Version \(info.version ?? "—")", info.source].joined(separator: " · "))
              .foregroundStyle(.kitSecondary)
            Text(info.lastUsedText)
              .fontWeight(.medium)
              .foregroundStyle(info.isUnused ? AnyShapeStyle(Hue.orange.text) : AnyShapeStyle(.kitSecondary))
          }
          Spacer()
          VStack(alignment: .trailing) {
            Text((total > 0 ? total : app.bytes).byteString).kitFont(.title2).fontWeight(.bold).monospacedDigit()
            Text("in all").kitFont(.caption).foregroundStyle(.kitSecondary)
          }
        }
        if total > 0 {
          VStack(alignment: .leading, spacing: 8) {
            MeterBar(segments: parts)
            HStack(spacing: 16) {
              ForEach(parts) { part in
                HStack(spacing: 5) {
                  RoundedRectangle(cornerRadius: 2).fill(part.hue.fill).frame(width: 8, height: 8)
                  Text(part.label)
                  Text(part.valueText ?? "").foregroundStyle(.kitSecondary)
                }
                .kitFont(.callout)
              }
            }
          }
        }
        Banner(
          !anyOn ? "Tick the app to uninstall it with all its files, or tick only its files to reset it and keep the app."
            : (appOn ? "Uninstall moves the app and the ticked files to the Trash. Quit it first if it is open."
                     : "Reset: the ticked files go, the app stays and starts fresh."),
          systemImage: "info.circle", hue: anyOn ? .accent : .gray)
        VStack(spacing: 2) {
          ForEach(app.paths, id: \.self) { path in fileRow(path) }
        }
      }
      .padding(22)
      .padding(.bottom, 100)
    }
    .task { await store.measurePaths(of: app) }
  }

  private func fileRow(_ path: String) -> some View {
    let on = store.isPathSelected(path, in: app)
    let kind = Self.kind(of: path, app: app)
    return HStack(spacing: 12) {
      StorageCheck(state: on ? .on : .off, disabled: store.isBusy) {
        store.setPath(path, of: app, selected: !on)
      }
      RoundedRectangle(cornerRadius: 2).fill(kind.hue.fill).frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 2) {
        Text(kind.title).fontWeight(.medium)
        Text(path.abbreviatingHome)
          .kitFont(.monoSmall)
          .foregroundStyle(.kitSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Text(store.pathSize(path)?.byteString ?? "…")
        .monospacedDigit()
        .frame(width: 80, alignment: .trailing)
      Button {
        KitDesktop.reveal([URL(fileURLWithPath: path)])
      } label: {
        Image(systemName: "magnifyingglass")
      }
      .buttonStyle(.kitIcon)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Hue.accent.soft(on ? 0.07 : 0), in: RoundedRectangle(cornerRadius: KitMetrics.radiusLarge))
  }

  private var breakdown: [MeterSegment] {
    var sums: [String: Int64] = [:]
    for path in app.paths {
      sums[Self.kind(of: path, app: app).part, default: 0] += store.pathSize(path) ?? 0
    }
    let order: [(String, Hue)] = [("App", .blue), ("Data", .purple), ("Caches", .green), ("Other", .gray)]
    return order.compactMap { name, hue in
      guard let bytes = sums[name], bytes > 0 else { return nil }
      return MeterSegment(name, value: Double(bytes), hue: hue, valueText: bytes.byteString)
    }
  }

  static func kind(of path: String, app: StorageItem) -> (title: String, part: String, hue: Hue) {
    if path == app.primaryPath { return ("\(app.title).app", "App", .blue) }
    let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    switch folder {
    case "Application Support": return ("Application Support", "Data", .purple)
    case "Containers", "Group Containers": return ("Container", "Data", .purple)
    case "Caches", "HTTPStorages", "WebKit": return (folder == "Caches" ? "Caches" : folder, "Caches", .green)
    case "Logs": return ("Logs", "Other", .gray)
    case "Preferences": return ("Preferences", "Other", .gray)
    case "Saved Application State": return ("Saved State", "Other", .gray)
    default: return (folder, "Other", .gray)
    }
  }
}

// MARK: - Languages

/// Every language's versions and caches, with the projects that pin each
/// version, so the versions nothing uses can go with everything they keep.
private struct LanguagesPage: View {
  @Environment(StorageStore.self) private var store
  @State private var languages: [StorageLanguages.Language] = []
  @State private var name: String?

  var body: some View {
    let current = languages.first { $0.name == name } ?? languages.first
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Languages").kitFont(.title2).fontWeight(.bold)
          let unused = languages.flatMap(\.unusedVersions)
          Text("\(unused.count) versions no project of yours uses · \(unused.reduce(0) { $0 + $1.bytes }.byteString)")
            .kitFont(.callout).foregroundStyle(.kitSecondary)
        }
        .padding(16)
        HStack {
          let picked = languages.contains { ($0.versions + $0.caches).contains(where: store.isSelected) }
          Button(picked ? "Deselect All" : "Select Unused") {
            if picked {
              store.setSelected(false, languages.flatMap { $0.versions + $0.caches })
            } else {
              store.setSelected(true, languages.flatMap { $0.unusedVersions + $0.caches })
            }
          }
          .disabled(store.isBusy)
          Spacer()
          Text("Sorted by size").kitFont(.caption).foregroundStyle(.kitSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        ScrollView {
          VStack(spacing: 2) {
            ForEach(languages) { language in languageRow(language, selected: current?.name == language.name) }
          }
          .padding(.horizontal, 8)
          .padding(.bottom, 110)
        }
      }
      .frame(width: 320)
      Divider()
      if let current {
        LanguageDetail(language: current)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .kitPane(.secondary)
      } else {
        EmptyState(systemImage: "chevron.left.forwardslash.chevron.right", title: "No Languages Found")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: store.lastScan) {
      let items = store.items
      let projects = KnownProjects.read().map { ($0.name, URL(fileURLWithPath: $0.root)) }
      languages = await Task.detached(priority: .userInitiated) {
        StorageLanguages.languages(from: items, projects: projects)
      }.value
    }
  }

  private func languageRow(_ language: StorageLanguages.Language, selected: Bool) -> some View {
    let all = language.versions + language.caches
    let unused = language.unusedVersions.count
    return HStack(spacing: 10) {
      StorageCheck(state: store.checkState(all), disabled: store.isBusy) {
        store.toggleGroup(all) { item in
          language.caches.contains(item) || language.unusedVersions.contains(item)
        }
      }
      Button {
        name = language.name
      } label: {
        HStack(spacing: 10) {
          Tile(letters: language.mono, hue: .orange, size: 36, style: .solid)
          VStack(alignment: .leading, spacing: 2) {
            Text(language.name).fontWeight(selected ? .semibold : .medium)
            Text("\(language.versions.count == 1 ? "1 version" : "\(language.versions.count) versions")\(unused > 0 ? " · \(unused) unused" : "") · \(language.caches.reduce(0) { $0 + $1.bytes }.byteString) caches")
              .kitFont(.caption)
              .foregroundStyle(unused > 0 ? AnyShapeStyle(Hue.orange.text) : AnyShapeStyle(.kitSecondary))
          }
          Spacer(minLength: 4)
          Text(language.bytes.byteString).kitFont(.callout).fontWeight(.semibold).monospacedDigit()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 8)
    .frame(height: 54)
    .background(Hue.accent.soft(selected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: KitMetrics.radiusLarge))
  }
}

private struct LanguageDetail: View {
  let language: StorageLanguages.Language
  @Environment(StorageStore.self) private var store

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 14) {
          Tile(letters: language.mono, hue: .orange, size: 56, style: .solid)
          VStack(alignment: .leading, spacing: 3) {
            Text(language.name).kitFont(.title1).fontWeight(.bold)
            Text("\(language.versions.count == 1 ? "1 version" : "\(language.versions.count) versions") · \(language.caches.count) caches and downloads")
              .foregroundStyle(.kitSecondary)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 4) {
            Text(language.bytes.byteString).kitFont(.title2).fontWeight(.bold).monospacedDigit()
            Button("Pick All of \(language.name)") {
              store.setSelected(true, language.versions + language.caches)
            }
            .disabled(store.isBusy)
          }
        }
        Text("Versions a project of yours pins are marked with that project. Removing a version also removes the packages installed into it.")
          .foregroundStyle(.kitSecondary)
        header("Versions", language.versions)
        VStack(spacing: 0) {
          ForEach(language.versions) { version in
            versionRow(version)
            Divider()
          }
        }
        .kitSurface(.card)
        header("Caches and Downloaded Packages", language.caches)
        Text("Safe whether you keep the language or not: they download or build again when a project needs them.")
          .kitFont(.callout)
          .foregroundStyle(.kitSecondary)
        VStack(spacing: 2) {
          ForEach(language.caches) { StorageFileRow(item: $0) }
        }
      }
      .padding(22)
      .padding(.bottom, 100)
    }
  }

  private func header(_ title: String, _ items: [StorageItem]) -> some View {
    HStack {
      Text(title).kitFont(.headline)
      Spacer()
      Text(items.reduce(0) { $0 + $1.bytes }.byteString).foregroundStyle(.kitSecondary).monospacedDigit()
    }
    .padding(.top, 4)
  }

  private func versionRow(_ version: StorageItem) -> some View {
    let users = language.usedBy[version.id] ?? []
    let on = store.isSelected(version)
    return HStack(spacing: 12) {
      StorageCheck(state: on ? .on : .off, disabled: version.isLocked || store.isBusy) {
        store.setSelected(!on, [version])
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(version.title).kitFont(.mono).fontWeight(.semibold)
        Text(version.detail ?? version.group).kitFont(.caption).foregroundStyle(.kitSecondary)
      }
      .frame(width: 220, alignment: .leading)
      HStack(spacing: 4) {
        if users.isEmpty {
          Text(version.lockReason ?? "No project uses it")
            .kitFont(.caption)
            .foregroundStyle(version.isLocked ? Hue.accent.text : Hue.orange.text)
        }
        ForEach(users.prefix(4), id: \.self) { user in
          Chip(user)
        }
      }
      Spacer()
      Text(version.bytes.byteString).monospacedDigit()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(Hue.accent.soft(on ? 0.07 : 0))
  }
}

// MARK: - CI machines

/// The virtual machines as cards: their size, whether they run, whether a
/// workflow uses them as a CI runner (then they cannot be picked).
private struct MachinesPage: View {
  @Environment(StorageStore.self) private var store
  @Environment(VMStore.self) private var vms

  var body: some View {
    let all = store.items(in: .virtualMachines)
    let actions = all.filter { $0.group == "Free Space Inside Disks" || $0.id == "docker:prune" }
    let machines = all.filter { !actions.contains($0) }.sorted { $0.bytes > $1.bytes }
    let prune = all.first { $0.id == "docker:prune" }
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Virtual Machines").kitFont(.title2).fontWeight(.bold)
          Text("Disk images grow as a guest writes and never shrink on their own. Compacting gives back the space the guest already deleted; machines your workflows run on are kept.")
            .foregroundStyle(.kitSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
          ForEach(machines) { item in
            let name = (item.title as NSString).deletingPathExtension
            let extra = actions.filter { $0.title == "Compact \(name)" }
              + (item.title.hasPrefix("Docker") ? [prune].compactMap { $0 } : [])
            card(item, actions: extra)
          }
          if let prune, !machines.contains(where: { $0.title.hasPrefix("Docker") }) {
            actionCard(prune)
          }
        }
      }
      .padding(22)
      .padding(.bottom, 100)
    }
    .kitPane(.secondary)
    .task { if vms.machines.isEmpty { await vms.refresh() } }
  }

  /// A row of a card: a check, what it does, why it may be locked, its size.
  private func actionRow(_ item: StorageItem, title: String, detail: String) -> some View {
    let on = store.isSelected(item)
    return HStack(spacing: 10) {
      StorageCheck(state: on ? .on : .off, disabled: item.isLocked || !item.cleanup.isCleanable || store.isBusy) {
        store.setSelected(!on, [item])
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(title).fontWeight(.medium)
        Text(item.lockReason ?? detail)
          .kitFont(.caption)
          .foregroundStyle(item.isLocked ? AnyShapeStyle(Hue.accent.text) : AnyShapeStyle(.kitSecondary))
      }
      Spacer()
      Text(item.bytes.byteString)
        .monospacedDigit()
        .fontWeight(.semibold)
        .foregroundStyle(on ? .kitLabel : .kitSecondary)
    }
    .opacity(item.isLocked ? 0.6 : 1)
  }

  private func actionCard(_ item: StorageItem) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Tile(systemImage: "shippingbox", hue: .indigo, size: 40, style: .solid)
        Text("Docker").fontWeight(.semibold)
      }
      Divider()
      actionRow(item, title: "Prune images and build cache", detail: item.detail ?? "")
    }
    .padding(16)
    .kitSurface(.card)
  }

  private func card(_ item: StorageItem, actions: [StorageItem]) -> some View {
    let name = (item.title as NSString).deletingPathExtension
    let machine = vms.machines.first { $0.name == name }
    let on = store.isSelected(item)
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Tile(systemImage: "desktopcomputer", hue: .indigo, size: 40, style: .solid)
        VStack(alignment: .leading, spacing: 2) {
          Text(name).fontWeight(.semibold)
          Text(item.group).kitFont(.caption).foregroundStyle(.kitSecondary)
        }
        Spacer()
        if item.isLocked {
          Chip("CI runner", hue: .accent)
        }
        if let machine {
          StatusLabel(machine.status.rawValue.capitalized, hue: machine.status.isRunning ? .green : .gray)
        }
      }
      Text(item.bytes.byteString).kitFont(.title2).fontWeight(.bold).monospacedDigit()
      Divider()
      ForEach(actions) { action in
        if action.id == "docker:prune" {
          actionRow(action, title: "Prune images and build cache", detail: action.detail ?? "")
        } else {
          actionRow(action, title: "Compact disk", detail: action.detail ?? "")
        }
      }
      HStack(spacing: 10) {
        StorageCheck(state: on ? .on : .off, disabled: item.isLocked || store.isBusy) {
          store.setSelected(!on, [item])
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(item.group == "Containers" ? "Delete disk image" : "Delete virtual machine").fontWeight(.medium)
          Text(item.lockReason ?? (item.group == "Containers" ? "Containers and images inside it go too" : "Removes the machine and its disk"))
            .kitFont(.caption)
            .foregroundStyle(item.isLocked ? AnyShapeStyle(Hue.accent.text) : AnyShapeStyle(.kitSecondary))
        }
        Spacer()
        Button {
          store.reveal(item)
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.kitIcon)
      }
      .opacity(item.isLocked ? 0.6 : 1)
    }
    .padding(16)
    .kitSurface(.card)
    .overlay { if on { RoundedRectangle(cornerRadius: KitMetrics.radiusCard, style: .continuous).strokeBorder(Hue.accent.fill, lineWidth: 2) } }
  }
}
