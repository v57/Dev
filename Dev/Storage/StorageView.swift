//
//  StorageView.swift
//  Dev
//

import AppKit
import SwiftUI

/// The Storage tool: a disk bar split by category on top, the categories on
/// the left, the selected category's items grouped on the right, and the
/// selection's total with the one destructive button at the foot.
struct StorageView: View {
  @Environment(StorageStore.self) private var store
  @State private var isConfirming = false

  var body: some View {
    VStack(spacing: 0) {
      StorageHeader()
      StorageAccessBanner()
      Divider()
      if store.hasResults || store.isScanning {
        HStack(spacing: 0) {
          StorageCategoryList()
            .frame(width: 280)
          Divider()
          Group {
            if let category = store.category {
              StorageCategoryDetail(category: category)
            } else {
              ContentUnavailableView(
                "Select a category", systemImage: "square.grid.2x2",
                description: Text("Open a section on the left to see its categories."))
            }
          }
          // Fills the rest of the row either way: a placeholder that only took
          // its own width let the row center itself and push the list right.
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        ContentUnavailableView {
          Label("See what fills this Mac", systemImage: "internaldrive")
        } description: {
          Text("Scan sorts the disk into Swift, Android, virtual machines, AI models, Node, media, apps and more. Nothing is removed until you pick it and confirm.")
        } actions: {
          Button("Scan") { store.scan() }
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .safeAreaBar(edge: .bottom) {
      if !store.selection.isEmpty {
        selectionBar
      }
    }
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
    .frame(minWidth: 720, minHeight: 420)
    .navigationTitle("Storage")
  }

  private var selectionBar: some View {
    HStack(spacing: 12) {
      Text("\(store.selectedItems.count) selected")
        .foregroundStyle(.secondary)
      Text(store.selectedBytes.byteString)
        .font(.headline.monospacedDigit())
      Spacer()
      Button("Deselect All") { store.selection.removeAll() }
        .disabled(store.isBusy)
      Button("Review & Clean…") { isConfirming = true }
        .buttonStyle(.borderedProminent)
        .disabled(store.isBusy || store.selectedItems.isEmpty)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  nonisolated private static func reportTitle(_ report: StorageCleanReport) -> String {
    report.cleanedIDs.isEmpty ? "Nothing was cleaned" : "Cleaned \(report.cleanedBytes.byteString)"
  }

  nonisolated private static func reportMessage(_ report: StorageCleanReport) -> String {
    var lines: [String] = []
    if report.trashedBytes > 0 {
      lines.append("\(report.trashedBytes.byteString) is in the Trash — empty it to free the space.")
    }
    if !report.failures.isEmpty {
      lines.append("Not cleaned:")
      lines += report.failures.prefix(8).map { "• \($0.title): \($0.message)" }
      if report.failures.count > 8 { lines.append("…and \(report.failures.count - 8) more") }
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - Header

/// Disk used vs free, the found bytes split by category, and the scan control.
private struct StorageHeader: View {
  @Environment(StorageStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(store.totalBytes.byteString + " found")
            .font(.title2.weight(.semibold).monospacedDigit())
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        scanControl
      }
      StorageDiskBar()
        .frame(height: 14)
      if store.totalBytes > 0 {
        StorageSafetyBar()
      }
    }
    .padding(16)
  }

  private var subtitle: String {
    let used = max(0, store.volumeTotal - store.volumeAvailable)
    var parts = ["\(used.byteString) used of \(store.volumeTotal.byteString)",
      "\(store.volumeAvailable.byteString) available"]
    if store.purgeable >= 1_000_000_000 {
      parts.append("\(store.purgeable.byteString) purgeable")
    }
    if !store.isScanning, let date = store.lastScan {
      parts.append("scanned \(date.formatted(.relative(presentation: .named)))")
    }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private var scanControl: some View {
    switch store.phase {
    case .scanning(let text):
      HStack(spacing: 10) {
        if store.discoveredCount > 0 && store.measuredCount < store.discoveredCount {
          ProgressView(value: Double(store.measuredCount), total: Double(store.discoveredCount))
            .frame(width: 120)
        } else {
          ProgressView().controlSize(.small)
        }
        Text(store.discoveredCount > 0 && store.measuredCount < store.discoveredCount
          ? "\(text) \(store.measuredCount)/\(store.discoveredCount)" : text)
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
        if store.discoveredCount > 0 && store.measuredCount < store.discoveredCount {
          Button("Cancel") { store.cancelScan() }
        }
      }
    case .cleaning:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Cleaning…").foregroundStyle(.secondary)
      }
    case .idle:
      HStack(spacing: 8) {
        if store.hasResults {
          Button {
            store.scanSystem()
          } label: {
            Label("Scan System Folders…", systemImage: "lock.shield")
          }
          .help("Asks for your administrator password, then measures the whole disk as root (about a minute): system logs and caches, other accounts, and whatever no category explains")
        }
        Button {
          store.scan()
        } label: {
          Label(store.hasResults ? "Rescan" : "Scan", systemImage: "arrow.clockwise")
        }
        .help("Measure every category again")
      }
    }
  }
}

/// The whole volume as one bar: a segment per category, the rest of what is
/// used (the system, everything not categorised) in grey, and the free space.
private struct StorageDiskBar: View {
  @Environment(StorageStore.self) private var store

  var body: some View {
    let total = max(store.volumeTotal, 1)
    // One segment per sidebar entry — a section, or a category standing on its
    // own — so the bar reads like the list beside it.
    let segments = StorageSidebarEntry.all.map { ($0, store.bytes(in: $0)) }.filter { $0.1 > 0 }
    let found = segments.reduce(0) { $0 + $1.1 }
    let used = max(store.volumeTotal - store.volumeAvailable, found)
    GeometryReader { geometry in
      let width = geometry.size.width
      HStack(spacing: 1) {
        ForEach(segments, id: \.0) { entry, bytes in
          Rectangle()
            .fill(entry.color)
            .frame(width: max(1, width * CGFloat(bytes) / CGFloat(total)))
            .help("\(entry.title): \(bytes.byteString)")
        }
        Rectangle()
          .fill(Color.secondary.opacity(0.35))
          .frame(width: max(0, width * CGFloat(used - found) / CGFloat(total)))
          .help("Not measured yet: \((used - found).byteString) — Scan System Folders accounts for the rest")
        Rectangle()
          .fill(Color.secondary.opacity(0.1))
          .help("Available: \(store.volumeAvailable.byteString)")
      }
    }
    .clipShape(Capsule())
  }
}

/// What was found, by how costly it is to lose: caches, rebuildable, your
/// data. Each tag's selected share sits first, faded — what is about to go —
/// and follows every checkbox. Clicking Cache or Rebuildable selects all of
/// it across categories (or deselects it once it all is); your data never
/// goes in bulk.
private struct StorageSafetyBar: View {
  @Environment(StorageStore.self) private var store
  private let tags: [StorageSafety] = [.cache, .rebuildable, .data]

  var body: some View {
    let total = max(store.totalBytes, 1)
    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { geometry in
        HStack(spacing: 1) {
          ForEach(tags, id: \.self) { tag in
            let bytes = store.bytes(tagged: tag)
            if bytes.total > 0 {
              segment(tag, bytes: bytes, width: geometry.size.width * CGFloat(bytes.total) / CGFloat(total))
            }
          }
        }
      }
      .frame(height: 10)
      .clipShape(Capsule())

      HStack(spacing: 18) {
        ForEach(tags, id: \.self) { tag in
          let bytes = store.bytes(tagged: tag)
          if bytes.total > 0 { legend(tag, bytes: bytes) }
        }
        Spacer(minLength: 0)
      }
      .font(.callout)
    }
  }

  private func segment(_ tag: StorageSafety, bytes: (total: Int64, selected: Int64), width: CGFloat) -> some View {
    let selectedWidth = width * CGFloat(bytes.selected) / CGFloat(max(bytes.total, 1))
    return HStack(spacing: 0) {
      Rectangle()
        .fill(tag.color.opacity(0.4))
        .frame(width: selectedWidth)
      Rectangle()
        .fill(tag.color)
    }
    .frame(width: max(1, width))
    .contentShape(Rectangle())
    .help(help(tag, bytes: bytes))
    .modifier(TagAction(tag: tag, store: store))
  }

  private func legend(_ tag: StorageSafety, bytes: (total: Int64, selected: Int64)) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(tag.color)
        .frame(width: 8, height: 8)
      Text(tag.title)
      Text(bytes.total.byteString)
        .monospacedDigit()
        .foregroundStyle(.secondary)
      if bytes.selected > 0 {
        Text("· \(bytes.selected.byteString) selected")
          .monospacedDigit()
          .foregroundStyle(tag.color)
      }
    }
    .contentShape(Rectangle())
    .help(help(tag, bytes: bytes))
    .modifier(TagAction(tag: tag, store: store))
  }

  private func help(_ tag: StorageSafety, bytes: (total: Int64, selected: Int64)) -> String {
    let action: String
    switch tag {
    case .data: action = "Your data is chosen item by item, never in bulk."
    default: action = store.isAllSelected(tagged: tag)
      ? "Click to deselect all of it." : "Click to select all of it, in every category."
    }
    return "\(tag.title): \(bytes.total.byteString), \(bytes.selected.byteString) selected. \(tag.help) \(action)"
  }

  /// Cache and Rebuildable act on a click; Your data shows, but does not act.
  private struct TagAction: ViewModifier {
    let tag: StorageSafety
    let store: StorageStore

    func body(content: Content) -> some View {
      if tag == .data {
        content
      } else {
        content
          .onTapGesture { store.toggleAll(tagged: tag) }
          .pointerStyle(.link)
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { store.toggleAll(tagged: tag) }
          .disabled(store.isBusy)
      }
    }
  }
}

// MARK: - Full Disk Access

/// Says what the scan cannot see and how to let it, or that a rescan would
/// see more now that access is on. Hidden once the scan on screen saw it all.
private struct StorageAccessBanner: View {
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

// MARK: - Categories

private struct StorageCategoryList: View {
  @Environment(StorageStore.self) private var store
  /// Sections start collapsed; this is the set the reader opened.
  @State private var expanded: Set<StorageSection> = []

  var body: some View {
    @Bindable var store = store
    // One scale for every bar, so a section, a category on its own and a
    // category inside a section compare at a glance.
    let largest = StorageSidebarEntry.all.map { store.bytes(in: $0) }.max() ?? 1
    List(selection: $store.category) {
      ForEach(StorageSidebarEntry.all) { entry in
        switch entry {
        case .section(let section):
          let categories = section.categories.filter(store.hasItems)
          if !categories.isEmpty {
            let isExpanded = expanded.contains(section)
            // A section is a row like any other, not a list header: it opens
            // and closes, and is never the selection itself.
            StorageEntryRow(
              title: section.title, systemImage: section.systemImage, color: section.color,
              bytes: store.bytes(in: entry), largest: largest,
              disclosure: isExpanded ? .open : .closed)
              .contentShape(Rectangle())
              .onTapGesture { toggle(section) }
              .selectionDisabled()
              .accessibilityAddTraits(.isButton)
              .accessibilityHint(isExpanded ? "Collapses \(section.title)" : "Expands \(section.title)")
            if isExpanded {
              ForEach(categories) { category in
                StorageEntryRow(
                  title: category.title, systemImage: category.systemImage, color: category.color,
                  bytes: store.bytes(in: category), largest: largest, disclosure: .child)
                  .tag(category)
              }
            }
          }
        case .category(let category):
          if store.hasItems(category) {
            StorageEntryRow(
              title: category.title, systemImage: category.systemImage, color: category.color,
              bytes: store.bytes(in: category), largest: largest, disclosure: .none)
              .tag(category)
          }
        }
      }
    }
    .listStyle(.sidebar)
    // Selecting a category inside a collapsed section (from the system scan,
    // say) opens that section so the selection is visible.
    .onChange(of: store.category) { _, category in
      if let section = category?.section { expanded.insert(section) }
    }
  }

  private func toggle(_ section: StorageSection) {
    withAnimation(.snappy(duration: 0.2)) {
      if expanded.contains(section) {
        expanded.remove(section)
        // Closing the section that holds the selection would hide it.
        if store.category?.section == section { store.category = nil }
      } else {
        expanded.insert(section)
      }
    }
  }
}

/// One sidebar line, the same for a section, a category on its own and a
/// category inside a section: icon, title, size and a bar on a shared scale.
private struct StorageEntryRow: View {
  enum Disclosure {
    /// A row with nothing to open: an empty chevron column keeps it aligned.
    case none
    case closed
    /// An open section: its own size and bar step back, since the rows
    /// beneath it carry the detail.
    case open
    /// A category inside a section, indented under the section's title.
    case child
  }

  let title: String
  let systemImage: String
  let color: Color
  let bytes: Int64
  let largest: Int64
  let disclosure: Disclosure

  var body: some View {
    let faded = disclosure == .open
    HStack(spacing: 8) {
      Image(systemName: "chevron.right")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(disclosure == .open ? 90 : 0))
        .opacity(disclosure == .closed || disclosure == .open ? 1 : 0)
        .frame(width: 10)
      Image(systemName: systemImage)
        .foregroundStyle(color)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(title)
            .lineLimit(1)
          Spacer()
          Text(bytes.byteString)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .opacity(faded ? 0.45 : 1)
        }
        GeometryReader { geometry in
          Capsule()
            .fill(color.opacity(0.8))
            .frame(width: max(2, geometry.size.width * CGFloat(bytes) / CGFloat(max(largest, 1))))
        }
        .frame(height: 3)
        .opacity(faded ? 0.3 : 1)
      }
    }
    .padding(.leading, disclosure == .child ? 12 : 0)
    .padding(.vertical, 3)
  }
}

private struct StorageCategoryDetail: View {
  let category: StorageCategory
  @Environment(StorageStore.self) private var store

  var body: some View {
    let groups = store.groups(in: category)
    let all = groups.flatMap(\.items)
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: category.systemImage)
          .font(.title)
          .foregroundStyle(category.color)
          .frame(width: 36)
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline) {
            Text(category.title).font(.title3.weight(.semibold))
            Text(store.bytes(in: category).byteString)
              .font(.title3.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Menu("Select") {
          Button("Caches") { store.selectCaches(in: category) }
          Button("Caches and Rebuildable") {
            store.setSelected(true, all.filter { $0.safety <= .rebuildable })
          }
          Button("Everything in \(category.title)") { store.setSelected(true, all) }
          Divider()
          Button("None") { store.setSelected(false, all) }
        }
        .fixedSize()
        .disabled(all.isEmpty)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      Divider()

      if category == .system, store.systemScanDate == nil, !store.isBusy {
        systemScanPrompt
      }
      if groups.isEmpty {
        ContentUnavailableView(
          store.isScanning ? "Measuring…" : "Nothing here",
          systemImage: store.isScanning ? "hourglass" : "checkmark.circle",
          description: Text(store.isScanning ? "Items appear as their sizes land." : "Nothing of this kind takes space on this Mac."))
      } else {
        List {
          ForEach(groups, id: \.name) { group in
            Section {
              ForEach(group.items) { item in
                StorageItemRow(item: item)
              }
            } header: {
              StorageGroupHeader(name: group.name, bytes: group.bytes, items: group.items)
            }
          }
        }
        .listStyle(.inset)
      }
    }
  }
}

private extension StorageCategoryDetail {
  var subtitle: String {
    guard category == .system, let date = store.systemScanDate else { return category.subtitle }
    return category.subtitle + " · system folders scanned \(date.formatted(.relative(presentation: .named)))"
  }

  var systemScanPrompt: some View {
    HStack(spacing: 10) {
      Image(systemName: "lock.shield")
        .foregroundStyle(.secondary)
      Text("System logs, system caches, other accounts and the folders no category explains need root to measure.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Scan System Folders…") { store.scanSystem() }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color.secondary.opacity(0.06))
  }
}

private struct StorageGroupHeader: View {
  let name: String
  let bytes: Int64
  let items: [StorageItem]
  @Environment(StorageStore.self) private var store

  var body: some View {
    let cleanable = items.filter(\.cleanup.isCleanable)
    let selected = cleanable.filter(store.isSelected).count
    HStack {
      Toggle(isOn: Binding(
        get: { !cleanable.isEmpty && selected == cleanable.count },
        set: { store.setSelected($0, cleanable) }
      )) {
        Text(name)
      }
      .toggleStyle(.checkbox)
      .disabled(cleanable.isEmpty || store.isBusy)
      Text("\(items.count)")
        .foregroundStyle(.tertiary)
      Spacer()
      Text(bytes.byteString)
        .monospacedDigit()
    }
    .font(.subheadline.weight(.semibold))
  }
}

private struct StorageItemRow: View {
  let item: StorageItem
  @Environment(StorageStore.self) private var store

  var body: some View {
    HStack(spacing: 10) {
      Toggle("", isOn: Binding(
        get: { store.isSelected(item) },
        set: { store.setSelected($0, [item]) }
      ))
      .toggleStyle(.checkbox)
      .labelsHidden()
      .disabled(!item.cleanup.isCleanable || store.isBusy)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .lineLimit(1)
        Text(item.detail ?? item.primaryPath.abbreviatingHome)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 12)
      if case .revealOnly(let reason) = item.cleanup {
        Image(systemName: "info.circle")
          .foregroundStyle(.secondary)
          .help(reason)
      } else if case .command(_, _, let verb) = item.cleanup {
        Text(verb)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      StorageSafetyBadge(safety: item.safety)
      VStack(alignment: .trailing, spacing: 1) {
        Text(item.bytes.byteString)
          .monospacedDigit()
        if let shared = item.sharedBytes, shared >= 1_000_000 {
          Text("+\(shared.byteString) shared")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .help("Also uses \(shared.byteString) of blocks it shares with other items through APFS clones or hard links. They are counted under those items, and removing this one alone does not free them.")
        }
      }
      .frame(width: 90, alignment: .trailing)
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .help(item.paths.map(\.abbreviatingHome).joined(separator: "\n"))
    .contextMenu {
      Button("Show in Finder") { store.reveal(item) }
        .disabled(item.paths.isEmpty)
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.primaryPath, forType: .string)
      }
      .disabled(item.paths.isEmpty)
    }
  }
}

private struct StorageSafetyBadge: View {
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
private struct StorageCleanSheet: View {
  @Environment(StorageStore.self) private var store
  @Environment(\.dismiss) private var dismiss
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
    case .other: Color(red: 0.6, green: 0.6, blue: 0.35)
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
    case .cache: .green
    case .rebuildable: .blue
    case .data: .orange
    }
  }
}

// MARK: - Sidebar row

/// The sidebar's Storage row: the last scan's total and the free space, or
/// the scan's progress while one runs.
struct StorageSidebarRow: View {
  @Environment(StorageStore.self) private var store

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "internaldrive")
        .font(.system(size: 15))
        .foregroundStyle(.tertiary)
        .frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text("Storage")
          .lineLimit(1)
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
  }

  private var status: String {
    switch store.phase {
    case .scanning:
      return store.discoveredCount > 0
        ? "Scanning… \(store.measuredCount)/\(store.discoveredCount)" : "Scanning…"
    case .cleaning:
      return "Cleaning…"
    case .idle:
      let free = "\(store.volumeAvailable.byteString) free"
      return store.hasResults ? "\(store.totalBytes.byteString) found · \(free)" : free
    }
  }
}
