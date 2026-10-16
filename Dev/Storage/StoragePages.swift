//
//  StoragePages.swift
//  Dev
//

import AppKit
import ComponentKit
import SwiftUI

// MARK: - Storage

/// Where the Storage tool is: Smart Scan, one category, or the Languages view.
enum StoragePage: Hashable {
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
          systemImage: "internaldrive", title: "See What Fills This Mac",
          message: "Scan sorts the disk into Xcode, Android, virtual machines, AI models, Node, apps, language versions and more. Nothing is removed until you pick it and confirm."
        ) {
          Button("Scan") { store.scan() }
            .buttonStyle(.kitPrimary)
        }
      }
    }
    .toolbar { StorageToolbar() }
    .sheet(isPresented: $isConfirming) {
      StorageCleanSheet()
    }
    .alert(
      store.report.map(Self.reportTitle) ?? "",
      isPresented: Binding(get: { store.report != nil }, set: { if !$0 { store.report = nil } })
    ) {
      if (store.report?.trashedBytes ?? 0) > 0 {
        Button("Open Trash") { store.openTrash() }
      }
      if store.report?.failures.contains(where: { $0.message.contains("App Management") }) == true {
        Button("Open App Management") { FullDiskAccess.openAppManagementSettings() }
      }
      Button("OK") { store.report = nil }
    } message: {
      Text(store.report.map(Self.reportMessage) ?? "")
    }
    .alert(
      "Couldn't scan system folders",
      isPresented: Binding(get: { store.systemScanError != nil }, set: { if !$0 { store.systemScanError = nil } })
    ) {
      Button("OK") { store.systemScanError = nil }
    } message: {
      Text(store.systemScanError ?? "")
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

/// Scan progress, or Scan System Folders and Scan Again.
private struct StorageToolbar: ToolbarContent {
  @Environment(StorageStore.self) private var store

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      switch store.phase {
      case .scanning(let text):
        HStack(spacing: 8) {
          if store.discoveredCount > 0 && store.measuredCount < store.discoveredCount {
            ProgressView(value: Double(store.measuredCount), total: Double(store.discoveredCount))
              .frame(width: 100)
            Text("\(text) \(store.measuredCount)/\(store.discoveredCount)")
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
          } else {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
          }
        }
        Button("Cancel") { store.cancelScan() }
      case .cleaning:
        ProgressView().controlSize(.small)
      case .idle:
        if store.hasResults {
          Button {
            store.scanSystem()
          } label: {
            Label("Scan System Folders…", systemImage: "lock.shield")
          }
          .help("Asks for your administrator password, then measures the whole disk as root: system logs and caches, other accounts, and whatever no category explains")
        }
        Button {
          store.scan()
        } label: {
          Label(store.hasResults ? "Scan Again" : "Scan", systemImage: "arrow.clockwise")
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
    List(selection: Binding(get: { Optional(page) }, set: { if let value = $0 { page = value } })) {
      row(.smartScan, title: "Smart Scan", symbol: "sparkles", color: .accentColor,
          trailing: store.selectedBytes > 0 ? store.selectedBytes.byteString : nil, bold: true)
      ForEach(StorageSection.allCases) { section in
        let categories = section.categories.filter { store.hasItems($0) || $0 == .applications }
        if !categories.isEmpty {
          Section(section.title) {
            ForEach(categories) { category in
              row(.category(category), title: category.title, symbol: category.systemImage, color: section.color,
                  trailing: trailing(category))
              if category == .applications {
                row(.languages, title: "Languages", symbol: "chevron.left.forwardslash.chevron.right",
                    color: section.color, trailing: nil)
              }
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
  }

  private func trailing(_ category: StorageCategory) -> String? {
    let items = store.items(in: category)
    if category == .applications { return items.isEmpty ? nil : "\(items.count) apps" }
    let picked = items.filter(store.isSelected).reduce(0) { $0 + $1.bytes }
    return picked > 0 ? picked.byteString : store.bytes(in: category).byteString
  }

  private func row(
    _ value: StoragePage, title: String, symbol: String, color: Color, trailing: String?, bold: Bool = false
  ) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(color, in: RoundedRectangle(cornerRadius: 5))
      Text(title)
        .fontWeight(bold ? .semibold : .regular)
        .lineLimit(1)
      Spacer(minLength: 4)
      if let trailing {
        Text(trailing)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .tag(value)
  }
}

// MARK: - Shared pieces

/// Off, on or mixed, as a round check: the cleaner's checkbox.
struct RoundCheck: View {
  enum State { case off, on, mixed }
  let state: State
  var size: CGFloat = 20
  var disabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(state == .off ? Color.clear : Color.accentColor)
        Circle()
          .strokeBorder(state == .off ? Color.secondary.opacity(0.6) : Color.accentColor, lineWidth: 1.5)
        if state == .on {
          Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
        } else if state == .mixed {
          Image(systemName: "minus").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
        }
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .opacity(disabled ? 0.4 : 1)
    .accessibilityValue(state == .on ? "checked" : (state == .mixed ? "partly checked" : "unchecked"))
  }
}

extension StorageStore {
  /// The check state of a set of items: the cleanable, unlocked ones count.
  func checkState(_ items: [StorageItem]) -> RoundCheck.State {
    let pickable = items.filter { $0.cleanup.isCleanable && !$0.isLocked }
    let on = pickable.filter(isSelected).count
    if on == 0 { return .off }
    return on == pickable.count ? .on : .mixed
  }

  /// Unticks everything ticked, or ticks the recommended ones (else all).
  func toggleGroup(_ items: [StorageItem], preferring prefer: (StorageItem) -> Bool = { $0.safety != .data }) {
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
    }
    return uninstalls ? "Uninstall" : "Clean"
  }

  var body: some View {
    let items = store.selectedItems
    let none = items.isEmpty
    let label = label(items)
    HStack(spacing: 14) {
      Button(action: action) {
        Text(label)
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 72, height: 72)
          .background(Circle().fill(none ? Color.secondary.opacity(0.4) : Color.accentColor))
          .shadow(color: none ? .clear : Color.accentColor.opacity(0.35), radius: 10, y: 4)
          .overlay(Circle().strokeBorder(Color.accentColor.opacity(none ? 0 : 0.18), lineWidth: 6).padding(-6))
      }
      .buttonStyle(.plain)
      .disabled(none || store.isBusy)
      .keyboardShortcut(.return, modifiers: .command)
      VStack(alignment: .leading, spacing: 1) {
        Text(none ? "Nothing picked" : store.selectedBytes.byteString)
          .font(.title3.weight(.bold).monospacedDigit())
        Text(none ? "Tick what to remove" : "\(items.count) items from every category")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.leading, 8)
    .padding(.trailing, 20)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(.quaternary))
    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
  }
}

/// A coloured squircle with a symbol or two letters: a category's or a
/// language's icon.
struct BadgeIcon: View {
  var symbol: String?
  var text: String?
  let color: Color
  var size: CGFloat = 36

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.25).fill(color)
      if let symbol {
        Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(.white)
      } else if let text {
        Text(text).font(.system(size: size * 0.34, weight: .bold, design: .monospaced)).foregroundStyle(.white)
      }
    }
    .frame(width: size, height: size)
  }
}

/// One file of an item group: check, title, detail, path, size, Show in Finder.
struct StorageFileRow: View {
  let item: StorageItem
  @Environment(StorageStore.self) private var store

  var body: some View {
    HStack(spacing: 12) {
      RoundCheck(state: store.isSelected(item) ? .on : .off, size: 18,
                 disabled: !item.cleanup.isCleanable || item.isLocked || store.isBusy) {
        store.setSelected(!store.isSelected(item), [item])
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(item.title).fontWeight(.medium).lineLimit(1).layoutPriority(1)
          if let reason = item.lockReason {
            Text(reason).font(.caption).foregroundStyle(Color.accentColor)
          } else if let detail = item.detail {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Text(item.primaryPath.abbreviatingHome)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 8)
      if case .command(_, _, let verb) = item.cleanup {
        Text(verb).font(.caption).foregroundStyle(.secondary)
      } else if case .cloneDuplicates = item.cleanup {
        Text(item.cleanup.verb).font(.caption).foregroundStyle(.secondary)
      } else if case .revealOnly(let reason) = item.cleanup {
        Image(systemName: "info.circle").foregroundStyle(.secondary).help(reason)
      }
      Text(item.bytes.byteString)
        .monospacedDigit()
        .frame(width: 80, alignment: .trailing)
      Button {
        store.reveal(item)
      } label: {
        Image(systemName: "magnifyingglass")
      }
      .buttonStyle(.borderless)
      .help("Show in Finder")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(store.isSelected(item) ? Color.accentColor.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
    .opacity(item.isLocked ? 0.6 : 1)
    .contextMenu {
      Button("Show in Finder") { store.reveal(item) }
      Button("Copy Path") {
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
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 28) {
          StorageRing(segments: segments, used: used, total: store.volumeTotal)
            .frame(width: 140, height: 140)
          VStack(alignment: .leading, spacing: 8) {
            Text("\(store.recommendedBytes.byteString) is safe to clean")
              .font(.largeTitle.weight(.bold))
            Text("Caches, build output and leftovers of deleted apps, which your tools make again on their own. Your own data, your apps and language versions are never picked for you.")
              .font(.title3)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if let date = store.lastScan {
              Text("Scanned \(date.formatted(.relative(presentation: .named)))")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
        }
        VStack(spacing: 0) {
          ForEach(Array(sections.enumerated()), id: \.element) { index, section in
            if index > 0 { Divider() }
            sectionRow(section)
          }
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
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

  private var segments: [StorageRing.Segment] {
    sections.map { .init(color: $0.color, bytes: store.bytes(in: .section($0))) }
  }

  private var used: Int64 { max(0, store.volumeTotal - store.volumeAvailable) }

  private func sectionRow(_ section: StorageSection) -> some View {
    let items = section.categories.flatMap { store.items(in: $0) }
    let recommended = items.filter { $0.safety != .data && $0.cleanup.isCleanable && !$0.isLocked }
    let picked = items.filter(store.isSelected).reduce(0) { $0 + $1.bytes }
    return HStack(spacing: 14) {
      RoundCheck(state: store.checkState(recommended), disabled: recommended.isEmpty || store.isBusy) {
        store.toggleGroup(recommended)
      }
      BadgeIcon(symbol: section.systemImage, color: section.color)
      VStack(alignment: .leading, spacing: 2) {
        Text(section.title).fontWeight(.semibold)
        Text(section.categories.filter(store.hasItems).map(\.title).joined(separator: ", "))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Text(picked.byteString)
        .font(.title3.weight(.bold).monospacedDigit())
        .foregroundStyle(picked > 0 ? .primary : .secondary)
      Button("Review") {
        if let first = section.categories.first(where: store.hasItems) { page = .category(first) }
      }
      .buttonStyle(.link)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private func tip(_ title: String, _ names: String, symbol: String, button: String, action: @escaping () -> Void) -> some View {
    HStack(spacing: 12) {
      BadgeIcon(symbol: symbol, color: .orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).fontWeight(.semibold)
        Text(names).font(.callout).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Button(button, action: action)
    }
    .padding(14)
    .frame(maxWidth: .infinity)
    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
  }
}

/// The disk as an Apple Watch–style ring: one segment per section with round
/// ends, each drawn over the one before with a soft shadow at its head, then
/// the free space as the track.
struct StorageRing: View {
  struct Segment {
    let color: Color
    let bytes: Int64
  }

  let segments: [Segment]
  let used: Int64
  let total: Int64

  var body: some View {
    GeometryReader { geometry in
      let line = geometry.size.width * 0.1
      let total = Double(max(self.total, 1))
      // Round caps reach half the line past each end: the used arc is scaled so
      // the outermost caps stay inside it.
      let circumference = Double.pi * (geometry.size.width - line)
      let cap = Double(line / 2) / circumference
      let usedFraction = min(1, Double(used) / total)
      let measured = Double(segments.reduce(0) { $0 + $1.bytes })
      let scale = measured > 0 ? max(0, usedFraction - 2 * cap) / (measured / total) : 0
      ZStack {
        Circle()
          .stroke(Color.secondary.opacity(0.15), lineWidth: line)
        ForEach(Array(arcs(total: total, scale: scale, cap: cap).enumerated()), id: \.offset) { index, arc in
          if index > 0 {
            Circle()
              .trim(from: arc.from, to: arc.from + 0.0001)
              .stroke(arc.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
              .shadow(color: .black.opacity(0.4), radius: 2)
          }
          Circle()
            .trim(from: arc.from, to: max(arc.from + 0.0001, arc.to))
            .stroke(arc.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
        }
        .rotationEffect(.degrees(-90))
        VStack(spacing: 2) {
          Text(used.byteString)
            .font(.title3.weight(.bold).monospacedDigit())
          Text("of \(self.total.byteString)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(line / 2)
    }
    .aspectRatio(1, contentMode: .fit)
  }

  private func arcs(total: Double, scale: Double, cap: Double) -> [(from: Double, to: Double, color: Color)] {
    var start = cap
    return segments.map { segment in
      let length = Double(segment.bytes) / total * scale
      defer { start += length }
      return (start, start + length, segment.color)
    }
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
          Text(category.title).font(.title2.weight(.bold))
          Text(category.subtitle).font(.callout).foregroundStyle(.secondary)
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
          Text("Sorted by size").font(.caption).foregroundStyle(.secondary)
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
          .background(.background.secondary)
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
      RoundCheck(state: store.checkState(group.items), disabled: store.isBusy || group.items.allSatisfy(\.isLocked)) {
        store.toggleGroup(group.items)
      }
      Button {
        groupName = group.name
      } label: {
        HStack(spacing: 10) {
          BadgeIcon(symbol: category.systemImage, color: category.color)
          VStack(alignment: .leading, spacing: 2) {
            Text(group.name).fontWeight(selected ? .semibold : .medium).lineLimit(1)
            Text("\(safety.title) · \(group.items.count) item\(group.items.count == 1 ? "" : "s")")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 4)
          Text(picked > 0 && picked < group.bytes ? "\(picked.byteString) of \(group.bytes.byteString)" : group.bytes.byteString)
            .font(.callout.weight(.semibold).monospacedDigit())
            .foregroundStyle(picked > 0 ? .primary : .secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 8)
    .frame(height: 56)
    .background(selected ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder
  private func files(_ group: (name: String, bytes: Int64, items: [StorageItem])) -> some View {
    let safety = group.items.map(\.safety).max() ?? .cache
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text(group.name).font(.title2.weight(.bold))
        HStack(spacing: 8) {
          StorageSafetyBadge(safety: safety)
          Text(group.bytes.byteString).font(.callout).foregroundStyle(.secondary)
        }
        Text(about(safety))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)
      HStack {
        Text("\(group.items.count) item\(group.items.count == 1 ? "" : "s")")
        Spacer()
        Text("Sort by Size")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
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
          VStack(spacing: 2) {
            ForEach(group.items) { StorageFileRow(item: $0) }
          }
          .padding(.horizontal, 12)
          .padding(.bottom, 110)
        }
      }
    }
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
          .font(.system(.callout, design: .monospaced).weight(.semibold))
          .lineLimit(3)
        Spacer()
        RoundCheck(state: on ? .on : .off, disabled: !item.cleanup.isCleanable || store.isBusy) {
          store.setSelected(!on, [item])
        }
      }
      if let detail = item.detail {
        Text(detail)
          .font(.caption)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
          .foregroundStyle(.purple)
      }
      Text(item.bytes.byteString)
        .font(.title2.weight(.bold).monospacedDigit())
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: on ? 2 : 1))
    .contextMenu { Button("Show in Finder") { store.reveal(item) } }
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
    if let item = MDItemCreate(nil, bundlePath as CFString),
       let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
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
          Text("Uninstaller").font(.title2.weight(.bold))
          let unused = store.items(in: .applications).filter { infos[$0.id]?.isUnused == true }.count
          Text("\(store.items(in: .applications).count) apps · \(unused) unused for 6 months or more")
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        Picker("Show", selection: $filter) {
          Text("All").tag("all")
          Text("Unused").tag("unused")
          Text("Large").tag("large")
          Text("Developer").tag("dev")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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
          .background(.background.secondary)
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
      RoundCheck(state: store.isSelected(app) ? (store.partialPaths[app.id] == nil ? .on : .mixed) : .off,
                 disabled: store.isBusy) {
        store.setSelected(!store.isSelected(app), [app])
      }
      Button {
        appID = app.id
      } label: {
        HStack(spacing: 10) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: app.primaryPath))
            .resizable()
            .frame(width: 38, height: 38)
          VStack(alignment: .leading, spacing: 2) {
            Text(app.title).fontWeight(selected ? .semibold : .medium).lineLimit(1)
            Text(info?.lastUsedText ?? " ")
              .font(.caption)
              .foregroundStyle(info?.isUnused == true ? .orange : .secondary)
          }
          Spacer(minLength: 4)
          Text(app.bytes.byteString)
            .font(.callout.weight(.semibold).monospacedDigit())
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 8)
    .frame(height: 56)
    .background(selected ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
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
    let total = parts.reduce(0) { $0 + $1.bytes }
    let anyOn = store.isSelected(app)
    let appOn = store.isPathSelected(app.primaryPath, in: app)
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 16) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: app.primaryPath))
            .resizable()
            .frame(width: 72, height: 72)
          VStack(alignment: .leading, spacing: 4) {
            Text(app.title).font(.title.weight(.bold))
            Text(["Version \(info.version ?? "—")", info.source].joined(separator: " · "))
              .foregroundStyle(.secondary)
            Text(info.lastUsedText)
              .fontWeight(.medium)
              .foregroundStyle(info.isUnused ? .orange : .secondary)
          }
          Spacer()
          VStack(alignment: .trailing) {
            Text((total > 0 ? total : app.bytes).byteString).font(.title2.weight(.bold).monospacedDigit())
            Text("in all").font(.caption).foregroundStyle(.secondary)
          }
        }
        if total > 0 {
          VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
              HStack(spacing: 2) {
                ForEach(parts, id: \.name) { part in
                  Rectangle().fill(part.color)
                    .frame(width: max(2, geometry.size.width * CGFloat(part.bytes) / CGFloat(total)))
                }
              }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            HStack(spacing: 16) {
              ForEach(parts, id: \.name) { part in
                HStack(spacing: 5) {
                  RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 8, height: 8)
                  Text(part.name)
                  Text(part.bytes.byteString).foregroundStyle(.secondary)
                }
                .font(.callout)
              }
            }
          }
        }
        Label(
          !anyOn ? "Tick the app to uninstall it with all its files, or tick only its files to reset it and keep the app."
            : (appOn ? "Uninstall moves the app and the ticked files to the Trash. Quit it first if it is open."
                     : "Reset: the ticked files go, the app stays and starts fresh."),
          systemImage: "info.circle")
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(anyOn ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
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
      RoundCheck(state: on ? .on : .off, size: 18, disabled: store.isBusy) {
        store.setPath(path, of: app, selected: !on)
      }
      RoundedRectangle(cornerRadius: 2).fill(kind.color).frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 2) {
        Text(kind.title).fontWeight(.medium)
        Text(path.abbreviatingHome)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Text(store.pathSize(path)?.byteString ?? "…")
        .monospacedDigit()
        .frame(width: 80, alignment: .trailing)
      Button {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      } label: {
        Image(systemName: "magnifyingglass")
      }
      .buttonStyle(.borderless)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(on ? Color.accentColor.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
  }

  private var breakdown: [(name: String, color: Color, bytes: Int64)] {
    var sums: [String: Int64] = [:]
    for path in app.paths {
      sums[Self.kind(of: path, app: app).part, default: 0] += store.pathSize(path) ?? 0
    }
    let order: [(String, Color)] = [("App", .blue), ("Data", .purple), ("Caches", .green), ("Other", .gray)]
    return order.compactMap { name, color in
      guard let bytes = sums[name], bytes > 0 else { return nil }
      return (name, color, bytes)
    }
  }

  static func kind(of path: String, app: StorageItem) -> (title: String, part: String, color: Color) {
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
          Text("Languages").font(.title2.weight(.bold))
          let unused = languages.flatMap(\.unusedVersions)
          Text("\(unused.count) versions no project of yours uses · \(unused.reduce(0) { $0 + $1.bytes }.byteString)")
            .font(.callout).foregroundStyle(.secondary)
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
          Text("Sorted by size").font(.caption).foregroundStyle(.secondary)
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
          .background(.background.secondary)
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
      RoundCheck(state: store.checkState(all), disabled: store.isBusy) {
        store.toggleGroup(all) { item in
          language.caches.contains(item) || language.unusedVersions.contains(item)
        }
      }
      Button {
        name = language.name
      } label: {
        HStack(spacing: 10) {
          BadgeIcon(text: language.mono, color: .orange)
          VStack(alignment: .leading, spacing: 2) {
            Text(language.name).fontWeight(selected ? .semibold : .medium)
            Text("\(language.versions.count == 1 ? "1 version" : "\(language.versions.count) versions")\(unused > 0 ? " · \(unused) unused" : "") · \(language.caches.reduce(0) { $0 + $1.bytes }.byteString) caches")
              .font(.caption)
              .foregroundStyle(unused > 0 ? .orange : .secondary)
          }
          Spacer(minLength: 4)
          Text(language.bytes.byteString).font(.callout.weight(.semibold).monospacedDigit())
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 8)
    .frame(height: 54)
    .background(selected ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct LanguageDetail: View {
  let language: StorageLanguages.Language
  @Environment(StorageStore.self) private var store

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 14) {
          BadgeIcon(text: language.mono, color: .orange, size: 56)
          VStack(alignment: .leading, spacing: 3) {
            Text(language.name).font(.title.weight(.bold))
            Text("\(language.versions.count == 1 ? "1 version" : "\(language.versions.count) versions") · \(language.caches.count) caches and downloads")
              .foregroundStyle(.secondary)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 4) {
            Text(language.bytes.byteString).font(.title2.weight(.bold).monospacedDigit())
            Button("Pick All of \(language.name)") {
              store.setSelected(true, language.versions + language.caches)
            }
            .disabled(store.isBusy)
          }
        }
        Text("Versions a project of yours pins are marked with that project. Removing a version also removes the packages installed into it.")
          .foregroundStyle(.secondary)
        header("Versions", language.versions)
        VStack(spacing: 0) {
          ForEach(language.versions) { version in
            versionRow(version)
            Divider()
          }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        header("Caches and Downloaded Packages", language.caches)
        Text("Safe whether you keep the language or not: they download or build again when a project needs them.")
          .font(.callout)
          .foregroundStyle(.secondary)
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
      Text(title).font(.headline)
      Spacer()
      Text(items.reduce(0) { $0 + $1.bytes }.byteString).foregroundStyle(.secondary).monospacedDigit()
    }
    .padding(.top, 4)
  }

  private func versionRow(_ version: StorageItem) -> some View {
    let users = language.usedBy[version.id] ?? []
    let on = store.isSelected(version)
    return HStack(spacing: 12) {
      RoundCheck(state: on ? .on : .off, size: 18, disabled: version.isLocked || store.isBusy) {
        store.setSelected(!on, [version])
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(version.title).font(.system(.callout, design: .monospaced).weight(.semibold))
        Text(version.detail ?? version.group).font(.caption).foregroundStyle(.secondary)
      }
      .frame(width: 220, alignment: .leading)
      HStack(spacing: 4) {
        if users.isEmpty {
          Text(version.lockReason ?? "No project uses it")
            .font(.caption)
            .foregroundStyle(version.isLocked ? Color.accentColor : .orange)
        }
        ForEach(users.prefix(4), id: \.self) { user in
          Text(user)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
      }
      Spacer()
      Text(version.bytes.byteString).monospacedDigit()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(on ? Color.accentColor.opacity(0.07) : .clear)
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
          Text("Virtual Machines").font(.title2.weight(.bold))
          Text("Disk images grow as a guest writes and never shrink on their own. Compacting gives back the space the guest already deleted; machines your workflows run on are kept.")
            .foregroundStyle(.secondary)
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
    .background(.background.secondary)
    .task { if vms.machines.isEmpty { await vms.refresh() } }
  }

  /// A row of a card: a check, what it does, why it may be locked, its size.
  private func actionRow(_ item: StorageItem, title: String, detail: String) -> some View {
    let on = store.isSelected(item)
    return HStack(spacing: 10) {
      RoundCheck(state: on ? .on : .off, size: 18, disabled: item.isLocked || !item.cleanup.isCleanable || store.isBusy) {
        store.setSelected(!on, [item])
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(title).fontWeight(.medium)
        Text(item.lockReason ?? detail)
          .font(.caption)
          .foregroundStyle(item.isLocked ? Color.accentColor : .secondary)
      }
      Spacer()
      Text(item.bytes.byteString)
        .monospacedDigit()
        .fontWeight(.semibold)
        .foregroundStyle(on ? .primary : .secondary)
    }
    .opacity(item.isLocked ? 0.6 : 1)
  }

  private func actionCard(_ item: StorageItem) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        BadgeIcon(symbol: "shippingbox", color: .indigo, size: 40)
        Text("Docker").fontWeight(.semibold)
      }
      Divider()
      actionRow(item, title: "Prune images and build cache", detail: item.detail ?? "")
    }
    .padding(16)
    .background(.background, in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.2)))
  }

  private func card(_ item: StorageItem, actions: [StorageItem]) -> some View {
    let name = (item.title as NSString).deletingPathExtension
    let machine = vms.machines.first { $0.name == name }
    let on = store.isSelected(item)
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        BadgeIcon(symbol: "desktopcomputer", color: .indigo, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(name).fontWeight(.semibold)
          Text(item.group).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if item.isLocked {
          Text("CI runner")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
        if let machine {
          HStack(spacing: 5) {
            Circle().fill(machine.status.isRunning ? .green : .secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(machine.status.rawValue.capitalized).font(.caption)
          }
        }
      }
      Text(item.bytes.byteString).font(.title2.weight(.bold).monospacedDigit())
      Divider()
      ForEach(actions) { action in
        if action.id == "docker:prune" {
          actionRow(action, title: "Prune images and build cache", detail: action.detail ?? "")
        } else {
          actionRow(action, title: "Compact disk", detail: action.detail ?? "")
        }
      }
      HStack(spacing: 10) {
        RoundCheck(state: on ? .on : .off, size: 18, disabled: item.isLocked || store.isBusy) {
          store.setSelected(!on, [item])
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(item.group == "Containers" ? "Delete disk image" : "Delete virtual machine").fontWeight(.medium)
          Text(item.lockReason ?? (item.group == "Containers" ? "Containers and images inside it go too" : "Removes the machine and its disk"))
            .font(.caption)
            .foregroundStyle(item.isLocked ? Color.accentColor : .secondary)
        }
        Spacer()
        Button {
          store.reveal(item)
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
      }
      .opacity(item.isLocked ? 0.6 : 1)
    }
    .padding(16)
    .background(.background, in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: on ? 2 : 1))
  }
}
