//
//  StorageStore.swift
//  Dev
//

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// The Storage tool's state: the last scan's items, a scan in flight, the
/// selection, and cleaning. Owned once by ContentView so the sidebar row and
/// the pane read the same scan.
///
/// The last finished scan is saved, so the tool opens on it instead of an
/// empty page; nothing rescans on its own.
@Observable
final class StorageStore {
  enum Phase: Equatable {
    case idle
    case scanning(String)
    case cleaning
  }

  /// What the normal scan found.
  private(set) var userItems: [StorageItem] = []
  /// What the last password scan found: kept across normal rescans, which
  /// never ask for the password and so cannot refresh it.
  private(set) var systemItems: [StorageItem] = []
  private(set) var systemScanDate: Date?
  /// Why the last password scan did not finish, shown once.
  var systemScanError: String?

  var items: [StorageItem] { userItems + systemItems }

  private(set) var phase: Phase = .idle
  private(set) var discoveredCount = 0
  private(set) var measuredCount = 0
  private(set) var lastScan: Date?
  private(set) var volumeTotal: Int64 = 0
  private(set) var volumeAvailable: Int64 = 0
  /// Space counted as available that macOS frees only when asked: iCloud
  /// copies, caches, snapshots.
  private(set) var purgeable: Int64 = 0
  /// Whether Dev has Full Disk Access now, re-checked whenever the app comes
  /// back to the front (the reader grants it in System Settings).
  private(set) var hasFullDiskAccess = FullDiskAccess.isGranted
  /// Whether the scan on screen could read protected folders.
  private(set) var scannedWithFullDiskAccess = false

  /// Item ids picked for cleaning. Ids are paths or tool ids, so a selection
  /// survives a rescan.
  var selection: Set<String> = []
  var category: StorageCategory?

  /// What the last clean did, shown once and then cleared.
  var report: StorageCleanReport?

  private var scanTask: Task<Void, Never>?
  private var previous: StorageSnapshot?
  @ObservationIgnored private var activation: NSObjectProtocol?

  init() {
    loadSnapshot()
    refreshVolume()
    activation = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.hasFullDiskAccess = FullDiskAccess.isGranted }
    }
  }

  /// True when access was granted after the scan on screen was made, so a
  /// rescan would see more.
  var rescanWouldSeeMore: Bool {
    hasFullDiskAccess && lastScan != nil && !scannedWithFullDiskAccess
  }

  // MARK: Reading

  var isScanning: Bool {
    if case .scanning = phase { return true }
    return false
  }

  var isBusy: Bool { phase != .idle }

  var hasResults: Bool { !items.isEmpty || lastScan != nil }

  var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

  func bytes(in category: StorageCategory) -> Int64 {
    items.reduce(0) { $1.category == category ? $0 + $1.bytes : $0 }
  }

  func bytes(in entry: StorageSidebarEntry) -> Int64 {
    let categories = Set(entry.categories)
    return items.reduce(0) { categories.contains($1.category) ? $0 + $1.bytes : $0 }
  }

  /// False while a category has nothing to show: the sidebar hides it.
  func hasItems(_ category: StorageCategory) -> Bool {
    items.contains { $0.category == category }
  }

  func items(in category: StorageCategory) -> [StorageItem] {
    items.filter { $0.category == category }
  }

  /// A category's items as (group, total, items), the largest group first and
  /// the largest item first inside each.
  func groups(in category: StorageCategory) -> [(name: String, bytes: Int64, items: [StorageItem])] {
    Dictionary(grouping: items(in: category), by: \.group)
      .map { name, items in
        (name, items.reduce(0) { $0 + $1.bytes }, items.sorted { $0.bytes > $1.bytes })
      }
      .sorted { $0.bytes > $1.bytes }
  }

  var selectedItems: [StorageItem] {
    items.filter { selection.contains($0.id) && $0.cleanup.isCleanable && !$0.isLocked }
      .map { item in
        // An app picked file by file: only those paths go (Reset keeps the app).
        guard let paths = partialPaths[item.id], !paths.isEmpty else { return item }
        var part = item
        part.paths = item.paths.filter(paths.contains)
        part.bytes = part.paths.reduce(0) { $0 + (pathSizes[$1] ?? 0) }
        if !part.paths.contains(item.primaryPath) { part.title = item.title + " data" }
        return part
      }
  }

  var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

  // MARK: Per-file picks (the Uninstaller)

  /// Items picked by some of their paths only: item id → the paths that go.
  /// An item absent here, but selected, goes whole.
  var partialPaths: [String: Set<String>] = [:]
  /// Sizes of single paths inside items, measured when an app is opened.
  private(set) var pathSizes: [String: Int64] = [:]

  func isPathSelected(_ path: String, in item: StorageItem) -> Bool {
    guard selection.contains(item.id) else { return false }
    return partialPaths[item.id]?.contains(path) ?? true
  }

  /// Picks or drops one path of an item: the item stays selected while any
  /// of its paths is, and goes whole when all are.
  func setPath(_ path: String, of item: StorageItem, selected: Bool) {
    var paths = selection.contains(item.id) ? (partialPaths[item.id] ?? Set(item.paths)) : []
    if selected { paths.insert(path) } else { paths.remove(path) }
    if paths.isEmpty {
      selection.remove(item.id)
      partialPaths[item.id] = nil
    } else {
      selection.insert(item.id)
      partialPaths[item.id] = paths.count == item.paths.count ? nil : paths
    }
  }

  /// Measures each path of an item once, off the main actor.
  func measurePaths(of item: StorageItem) async {
    let missing = item.paths.filter { pathSizes[$0] == nil }
    guard !missing.isEmpty else { return }
    let sizes = await Task.detached(priority: .userInitiated) {
      missing.map { ($0, DiskUsage.measure([$0]).bytes) }
    }.value
    for (path, bytes) in sizes { pathSizes[path] = bytes }
  }

  func pathSize(_ path: String) -> Int64? { pathSizes[path] }

  // MARK: Locks

  /// Marks the virtual machines a workflow runs on: deleting one would break
  /// that project's CI.
  func applyLocks(runnerNames: Set<String>) {
    func lock(_ item: inout StorageItem) {
      // Machines only: compaction and pruning carry their own locks from the scan.
      guard item.category == .virtualMachines, item.group != "Free Space Inside Disks",
            item.id != "docker:prune" else { return }
      let name = (item.title as NSString).deletingPathExtension
      item.lockReason = runnerNames.contains(name) ? "Workflows use it as a CI runner" : nil
    }
    for index in userItems.indices { lock(&userItems[index]) }
    for index in systemItems.indices { lock(&systemItems[index]) }
    selection.subtract(items.filter(\.isLocked).map(\.id))
  }

  /// The UTM machine names any known project's workflows run steps on.
  nonisolated static func workflowRunnerNames() -> Set<String> {
    var names = Set<String>()
    for entry in KnownProjects.read() {
      for workflow in Workflow.load(in: URL(fileURLWithPath: entry.root)) {
        for step in workflow.steps { if let name = step.vmName { names.insert(name) } }
      }
    }
    return names
  }

  /// Picks what Smart Scan recommends, once per scan: a fresh scan starts with
  /// the safe items ticked, and the reader's changes are kept after that.
  func selectRecommendedIfNew() {
    guard let lastScan, autoSelectedScan != lastScan else { return }
    autoSelectedScan = lastScan
    selection.formUnion(recommendedItems.map(\.id))
  }

  @ObservationIgnored private var autoSelectedScan: Date?

  /// What Smart Scan picks: every cleanable cache and rebuildable item. Your
  /// own data is never in it.
  var recommendedItems: [StorageItem] {
    items.filter { $0.safety != .data && $0.cleanup.isCleanable && !$0.isLocked }
  }

  var recommendedBytes: Int64 { recommendedItems.reduce(0) { $0 + $1.bytes } }

  // MARK: Selecting

  func isSelected(_ item: StorageItem) -> Bool { selection.contains(item.id) }

  func setSelected(_ selected: Bool, _ items: [StorageItem]) {
    let ids = items.filter { $0.cleanup.isCleanable && !$0.isLocked }.map(\.id)
    for id in ids { partialPaths[id] = nil }
    if selected { selection.formUnion(ids) } else { selection.subtract(ids) }
  }

  /// Everything found with this tag, and how much of it is selected.
  func bytes(tagged safety: StorageSafety) -> (total: Int64, selected: Int64) {
    items.reduce((Int64(0), Int64(0))) { sum, item in
      guard item.safety == safety else { return sum }
      let selected = selection.contains(item.id) && item.cleanup.isCleanable
      return (sum.0 + item.bytes, sum.1 + (selected ? item.bytes : 0))
    }
  }

  /// True when every cleanable item with this tag is selected.
  func isAllSelected(tagged safety: StorageSafety) -> Bool {
    let cleanable = items.filter { $0.safety == safety && $0.cleanup.isCleanable }
    return !cleanable.isEmpty && cleanable.allSatisfy { selection.contains($0.id) }
  }

  /// Selects every cleanable item with this tag, in every category, or
  /// deselects them when they are all selected already. Your data is never
  /// picked in bulk: each of those is a decision of its own.
  func toggleAll(tagged safety: StorageSafety) {
    guard safety != .data, !isBusy else { return }
    let tagged = items.filter { $0.safety == safety }
    setSelected(!isAllSelected(tagged: safety), tagged)
  }

  /// Picks every cache in the category: the things that come back on their own.
  func selectCaches(in category: StorageCategory) {
    setSelected(true, items(in: category).filter { $0.safety == .cache })
  }

  // MARK: Scanning

  func scan() {
    guard !isBusy else { return }
    previous = snapshot
    userItems = []
    discoveredCount = 0
    measuredCount = 0
    phase = .scanning("Starting…")
    hasFullDiskAccess = FullDiskAccess.isGranted
    let stream = StorageScanner.scan(
      roots: nil, runningBundle: Bundle.main.bundlePath, fullDiskAccess: hasFullDiskAccess)
    scanTask = Task {
      var finished = false
      for await event in stream {
        switch event {
        case .phase(let text):
          phase = .scanning(text)
        case .discovered(let count):
          discoveredCount = count
        case .progress(let done):
          measuredCount = done
        case .measured(let item):
          userItems.append(item)
        case .finished(let snapshot):
          apply(snapshot)
          if let saved = self.snapshot { save(saved) }
          finished = true
        }
      }
      // A cancelled scan ends without `finished`: go back to what was showing.
      if !finished {
        if let previous { apply(previous) } else { userItems = [] }
      }
      phase = .idle
      previous = nil
      scanTask = nil
    }
  }

  func cancelScan() {
    scanTask?.cancel()
  }

  /// The password scan: the whole Data volume measured as root, for what only
  /// root can see and for whatever no item explains. It runs after a normal
  /// scan has listed the items, so its leftovers are the true remainder.
  func scanSystem() {
    guard !isBusy else { return }
    // The normal scan's counts mean nothing here; the phase text carries it.
    discoveredCount = 0
    measuredCount = 0
    phase = .scanning("Waiting for your password…")
    let known = userItems
    Task {
      do {
        let found = try await StorageSystemScan.run(known: known) { counted in
          // The password prompt and the home walk run at the same time, and
          // nothing says when the password was typed, so the text names both.
          Task { @MainActor in
            guard case .scanning = self.phase else { return }
            self.phase = .scanning(counted.map { "Measuring your home folder… \($0.byteString)" }
              ?? "Waiting for the password and the root measurement…")
          }
        }
        systemItems = found
        systemScanDate = Date()
        selection.formIntersection(Set(items.map(\.id)))
        if let snapshot { save(snapshot) }
        category = .system
      } catch StorageSystemScan.Failure.cancelled {
        // The reader said no to the prompt: nothing to report.
      } catch {
        systemScanError = error.localizedDescription
      }
      refreshVolume()
      phase = .idle
    }
  }

  // MARK: Cleaning

  /// Cleans the selected items off the main actor, drops the cleaned ones from
  /// the list and saves the result, so the page never shows bytes that are gone.
  func cleanSelection(deleteImmediately: Bool) async {
    let targets = selectedItems
    guard !targets.isEmpty, !isBusy else { return }
    phase = .cleaning
    let report = await Task.detached(priority: .userInitiated) {
      StorageCleaner.clean(targets, deleteImmediately: deleteImmediately)
    }.value
    let cleaned = Set(report.cleanedIDs)
    // An item cleaned path by path keeps the paths that stayed.
    let partial = partialPaths
    func keep(_ item: inout StorageItem) -> Bool {
      guard cleaned.contains(item.id) else { return true }
      guard let gone = partial[item.id] else { return false }
      item.paths.removeAll(where: gone.contains)
      item.bytes = max(0, item.bytes - gone.reduce(0) { $0 + (pathSizes[$1] ?? 0) })
      return !item.paths.isEmpty
    }
    userItems = userItems.compactMap { var item = $0; return keep(&item) ? item : nil }
    systemItems = systemItems.compactMap { var item = $0; return keep(&item) ? item : nil }
    selection.subtract(cleaned)
    for id in cleaned { partialPaths[id] = nil }
    refreshVolume()
    if let snapshot { save(snapshot) }
    phase = .idle
    self.report = report
  }

  // MARK: Export

  /// The selection as Markdown, to review what Smart Scan picks: what is
  /// picked by category with its tag, action and path, then what is not and
  /// why (your data, locked, shown only, or simply unticked).
  func selectionReport() -> String {
    func cell(_ text: String) -> String {
      text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
    func path(_ item: StorageItem) -> String {
      guard !item.paths.isEmpty else { return "" }
      let more = item.paths.count > 1 ? " +\(item.paths.count - 1) more" : ""
      return "`\(cell(item.primaryPath.abbreviatingHome))`\(more)"
    }
    func table(_ items: [StorageItem], last: String, _ value: (StorageItem) -> String) -> [String] {
      var lines: [String] = []
      for category in StorageCategory.allCases {
        let inCategory = items.filter { $0.category == category }.sorted { $0.bytes > $1.bytes }
        guard !inCategory.isEmpty else { continue }
        lines += ["", "### \(category.title) · \(inCategory.reduce(0) { $0 + $1.bytes }.byteString)", "",
          "| Size | Item | Group | Tag | \(last) | Path |", "|---:|---|---|---|---|---|"]
        lines += inCategory.map { item in
          let title = cell(item.title) + (item.detail.map { " — " + cell($0) } ?? "")
          return "| \(item.bytes.byteString) | \(title) | \(cell(item.group)) | \(item.safety.title) | \(cell(value(item))) | \(path(item)) |"
        }
      }
      return lines
    }

    let picked = selectedItems
    let pickedIDs = Set(picked.map(\.id))
    let rest = items.filter { !pickedIDs.contains($0.id) }
    let recommended = recommendedItems
    var lines = ["# Storage selection", ""]
    if let lastScan {
      lines.append("Scanned \(lastScan.formatted(date: .abbreviated, time: .shortened))"
        + " · Full Disk Access \(scannedWithFullDiskAccess ? "on" : "off")"
        + " · \(volumeAvailable.byteString) free of \(volumeTotal.byteString)  ")
    }
    lines.append("Picked: \(picked.count) items · \(selectedBytes.byteString)"
      + " · Smart Scan recommends \(recommended.count) items · \(recommendedBytes.byteString)")
    lines += ["", "## Picked"] + table(picked, last: "Action") { $0.cleanup.verb }
    lines += ["", "## Not picked"] + table(rest, last: "Why not") { item in
      if let reason = item.lockReason { return "Locked: " + reason }
      if case .revealOnly(let reason) = item.cleanup { return "Shown only: " + reason }
      if item.safety == .data { return "Your data" }
      return "Unticked"
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Asks where to save the selection report and writes it there.
  func exportSelection() {
    let panel = NSSavePanel()
    panel.title = "Export Selection"
    panel.nameFieldStringValue = "Storage selection \(Date().formatted(.iso8601.year().month().day())).md"
    panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
    panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try selectionReport().write(to: url, atomically: true, encoding: .utf8)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } catch {
      NSAlert(error: error).runModal()
    }
  }

  // MARK: Finder

  func reveal(_ item: StorageItem) {
    let urls = item.urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  func openTrash() {
    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
  }

  // MARK: Persistence

  private var snapshot: StorageSnapshot? {
    guard let lastScan else { return nil }
    return StorageSnapshot(
      date: lastScan, items: userItems, volumeTotal: volumeTotal, volumeAvailable: volumeAvailable, roots: [],
      fullDiskAccess: scannedWithFullDiskAccess, systemItems: systemItems, systemDate: systemScanDate)
  }

  private func apply(_ snapshot: StorageSnapshot) {
    userItems = snapshot.items
    if let system = snapshot.systemItems {
      systemItems = system
      systemScanDate = snapshot.systemDate
    }
    lastScan = snapshot.date
    volumeTotal = snapshot.volumeTotal
    volumeAvailable = snapshot.volumeAvailable
    scannedWithFullDiskAccess = snapshot.fullDiskAccess ?? false
    let ids = Set(items.map(\.id))
    selection.formIntersection(ids)
  }

  private func refreshVolume() {
    let volume = StorageScanner.volumeCapacity()
    volumeTotal = volume.total
    volumeAvailable = volume.available
    let plain = (try? URL(fileURLWithPath: NSHomeDirectory())
      .resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0
    purgeable = max(0, volume.available - Int64(plain))
  }

  private static var snapshotURL: URL? {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    let folder = support
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.v57.dev", isDirectory: true)
      .appendingPathComponent("Storage", isDirectory: true)
    return folder.appendingPathComponent("last-scan.json")
  }

  private func loadSnapshot() {
    guard let url = Self.snapshotURL, let data = try? Data(contentsOf: url),
      let snapshot = try? JSONDecoder().decode(StorageSnapshot.self, from: data)
    else { return }
    apply(snapshot)
  }

  private func save(_ snapshot: StorageSnapshot) {
    // A screenshot or test launch never replaces the reader's saved scan.
    guard !LaunchOptions.isScreenshotMode, let url = Self.snapshotURL else { return }
    Task.detached(priority: .background) {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
  }
}
