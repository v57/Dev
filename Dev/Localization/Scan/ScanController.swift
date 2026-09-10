//
//  ScanController.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import AppKit
import Foundation

/// Run state for Scan Strings: one scan at a time, its live progress, the
/// finished report and the merge it proposes.
///
/// The scan never writes anything itself — it extracts keys and builds a
/// merge PREVIEW; the catalog file changes only when the user applies the
/// merge (or the pipeline translates the freshly added keys).
@Observable
final class ScanController {
  // MARK: presentation

  /// The sheet host: true while the Scan Strings sheet is open.
  var isPresented = false

  /// Root being scanned (or last scanned).
  private(set) var root: URL?

  // MARK: run state

  private(set) var isRunning = false
  private(set) var phase = ""
  private(set) var log: [String] = []
  private(set) var progressDone = 0
  private(set) var progressTotal = 0

  /// Finished report (nil while idle or running).
  private(set) var report: ScanReport?
  /// The merge this report proposes against the open catalog.
  private(set) var plan: ScanMergePlan?
  /// Set after a successful merge: how many keys were added.
  private(set) var appliedCount: Int?
  private(set) var errorMessage: String?

  /// The catalog store this scan belongs to (weak: the store owns the
  /// controller).
  private weak var store: LocalizationStore?

  private var task: Task<Void, Never>?
  private var cancellation = ScanCancellation()

  // MARK: - lifecycle

  /// Opens the sheet and starts a scan of `root`.
  func begin(store: LocalizationStore, root: URL?) {
    self.store = store
    isPresented = true
    guard let root else {
      errorMessage = "This catalog has no project folder to scan. Choose the repo root."
      return
    }
    start(root: root)
  }

  /// Re-runs the scan (Scan Again).
  func rescan() {
    guard let root else { return }
    start(root: root)
  }

  /// Lets the user pick another root folder (a catalog may live deep inside
  /// the repo, e.g. Resources/Localization).
  func chooseRoot() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose the repo folder to scan for Swift packages and Xcode projects"
    panel.prompt = "Scan"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    start(root: url.standardizedFileURL)
  }

  /// Cancels the running scan and terminates its toolchain children. The
  /// partial report is kept for inspection; nothing is merged.
  func cancel() {
    guard isRunning else { return }
    cancellation.cancel()
    phase = "Cancelling…"
  }

  func dismiss() {
    if isRunning { cancellation.cancel() }
    isPresented = false
  }

  private func start(root: URL) {
    guard !isRunning else { return }
    self.root = root
    isRunning = true
    phase = "Preparing…"
    log = []
    report = nil
    plan = nil
    appliedCount = nil
    errorMessage = nil
    progressDone = 0
    progressTotal = 0

    let token = ScanCancellation()
    cancellation = token
    let config = ScanConfig(root: root)

    task = Task { [weak self] in
      let emit: @Sendable (ScanEvent) -> Void = { event in
        Task { @MainActor in self?.handle(event) }
      }
      let result = await Task.detached(priority: .userInitiated) {
        ScanEngine.run(config: config, cancellation: token, emit: emit)
      }.value
      self?.finish(result)
    }
  }

  private func handle(_ event: ScanEvent) {
    switch event {
    case .phase(let text):
      phase = text
      append(text)
    case .log(let text):
      append(text)
    case .discovered(let packages, let projects):
      for path in packages { append("package  \(path)") }
      for path in projects { append("project  \(path)") }
      if packages.isEmpty, projects.isEmpty {
        append("nothing to scan here")
      }
    case .progress(let done, let total, let label):
      progressDone = done
      progressTotal = total
      phase = "Extracted \(done)/\(total) — \(label)"
    case .moduleFinished(let module):
      let status = module.failed ? "FAILED — \(module.detail)" : "\(module.keyCount) keys"
      append("  \(module.module): \(status)  (\(module.fileCount) files)")
    }
  }

  private func append(_ line: String) {
    log.append(line)
    if log.count > 500 {
      log.removeFirst(log.count - 500)
    }
  }

  /// Adopts a finished scan: the raw report stands; the merge preview is
  /// computed against the catalog as it is right now.
  private func finish(_ result: ScanReport) {
    isRunning = false
    report = result
    phase = result.cancelled
      ? "Cancelled — nothing was merged"
      : "Done in \(Self.durationText(result.duration))"
    if result.cancelled { return }
    errorMessage = result.errorMessage
    refreshPlan()
  }

  /// Recomputes the merge preview against the open catalog (the catalog may
  /// have gained or lost keys since the scan finished).
  func refreshPlan() {
    guard let report, let store,
          let catalog = store.catalog, let catalogURL = store.catalogURL,
          !report.cancelled
    else {
      plan = nil
      return
    }
    plan = ScanMerge.plan(
      extracted: report.extracted,
      keyOwners: report.keyOwners,
      catalog: catalog,
      catalogURL: catalogURL)
  }

  // MARK: - apply

  /// Merges the scan into the open catalog: the store adopts the merged
  /// document, writes it and re-reconciles (new keys become translate rows).
  /// Returns how many keys were added.
  @discardableResult
  func apply() -> Int {
    guard let report, !report.cancelled, let store else { return 0 }
    guard let catalog = store.catalog, let catalogURL = store.catalogURL else { return 0 }
    let fresh = ScanMerge.plan(
      extracted: report.extracted,
      keyOwners: report.keyOwners,
      catalog: catalog,
      catalogURL: catalogURL)
    plan = fresh
    guard !fresh.added.isEmpty else {
      appliedCount = 0
      return 0
    }
    let merged = ScanMerge.apply(fresh, to: catalog)
    store.adoptScanMerge(merged, url: catalogURL)
    appliedCount = fresh.added.count
    return fresh.added.count
  }

  // MARK: - report text

  var reportText: String? {
    guard let report else { return nil }
    if let plan {
      return plan.textSummary(report: report)
    }
    var lines = ["Scan Strings report", "root: \(report.root.path)"]
    lines.append("cancelled after \(Self.durationText(report.duration))")
    return lines.joined(separator: "\n")
  }

  func copyReport() {
    guard let text = reportText else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  static func durationText(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let minutes = Int(seconds) / 60
    let rest = Int(seconds) % 60
    return "\(minutes)m \(rest)s"
  }
}
