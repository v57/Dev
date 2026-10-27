//
//  ScanController.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import ComponentKit
import ComponentKit
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

  // MARK: the comment pass (notes 2.8)

  /// What the on-device comment pass did: the counts the report shows, the
  /// comments it generated (key -> sentence) and why it skipped the rest.
  /// Starts as "nothing asked yet" and is replaced the moment the pass is
  /// scheduled, so the sheet can show its progress from the first second.
  private(set) var comments: CommentPassOutcome?
  /// True while the pass is generating — the report's own run state.
  private(set) var isCommenting = false
  private(set) var commentDone = 0
  private(set) var commentTotal = 0
  private(set) var commentKey = ""
  /// Keys of the merged catalog with no comment that the scan never located
  /// and keys the scan located without a source file: counted before the pass
  /// starts, reported with its result.
  private var commentNoFile = 0
  private var commentUnlocated = 0

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
    Task {
      guard
        let url = await KitDesktop.chooseFolders(
          prompt: "Scan", message: "Choose the repo folder to scan for Swift packages and Xcode projects"
        ).first
      else { return }
      start(root: url.standardizedFileURL)
    }
  }

  /// Cancels the running scan and terminates its toolchain children. The
  /// partial report is kept for inspection; nothing is merged.
  func cancel() {
    if isRunning {
      cancellation.cancel()
      phase = "Cancelling…"
      return
    }
    cancelCommentPass()
  }

  /// Stops the comment pass. The cancel flag is what the pass reads between
  /// comments, so it stops within one comment (~1 s) and KEEPS every sentence
  /// it already wrote into the catalog — a half-finished pass is a set of
  /// ordinary app-side edits, not a torn state.
  func cancelCommentPass() {
    guard isCommenting else { return }
    cancellation.cancel()
  }

  func dismiss() {
    if isRunning { cancellation.cancel() }
    // The pass reads the OPEN catalog and the scan that is gone with the
    // sheet: closing it stops the pass rather than letting it write into
    // whatever catalog the pane opens next.
    if isCommenting { cancelCommentPass() }
    isPresented = false
  }

  private func start(root: URL) {
    guard !isRunning, !isCommenting else { return }
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
    comments = nil
    isCommenting = false
    commentDone = 0
    commentTotal = 0
    commentKey = ""

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
  /// computed against the catalog as it is right now — and the on-device
  /// comment pass starts on the scan's own result (notes 2.8: it belongs to
  /// the scan, because that is where the source paths are).
  private func finish(_ result: ScanReport) {
    isRunning = false
    report = result
    phase = result.cancelled
      ? "Cancelled — nothing was merged"
      : "Done in \(Self.durationText(result.duration))"
    if result.cancelled { return }
    errorMessage = result.errorMessage
    refreshPlan()
    startCommentPass()
  }

  // MARK: - the comment pass

  /// Generates a comment for every comment-less key of the merged catalog,
  /// reusing THIS scan's file map — nothing is stored anywhere (notes 2.8).
  ///
  /// Runs automatically when a scan finishes and can be started again from the
  /// report (after a cancel, or for keys a merge has added since). Each
  /// sentence is written into the open catalog as it arrives, so a cancel
  /// keeps everything generated so far.
  func startCommentPass() {
    guard !isCommenting, let report, !report.cancelled else { return }
    guard let store, let catalog = store.catalog else { return }
    let prepared = CommentGeneration.targets(
      extracted: report.extracted,
      keyFiles: report.keyFiles,
      catalog: catalog)
    commentNoFile = prepared.noFile
    commentUnlocated = prepared.unlocated
    commentDone = 0
    commentTotal = prepared.targets.count
    commentKey = ""
    comments = CommentPassOutcome(targetCount: prepared.targets.count)
    isCommenting = true
    phase = prepared.targets.isEmpty
      ? "Comments: nothing to generate"
      : "Generating comments for \(prepared.targets.count) key(s)…"

    let token = cancellation
    let model = OnDeviceCommentModel()
    let targets = prepared.targets
    // Detached on purpose, exactly like the scan itself: the pass is minutes
    // of work (measured 0.8 s per comment), and a nonisolated async function
    // is not guaranteed to leave the caller's actor. On the main actor it
    // would freeze the window for the whole pass — and the Cancel button the
    // card promises would be untouchable.
    Task { [weak self] in
      let onComment: @Sendable (String, String) -> Void = { key, comment in
        Task { @MainActor in self?.applyGenerated(comment, for: key) }
      }
      let onProgress: @Sendable (Int, Int, String) -> Void = { index, total, key in
        Task { @MainActor in self?.showCommentProgress(index: index, total: total, key: key) }
      }
      let result = await Task.detached(priority: .utility) {
        await CommentGeneration.run(
          targets: targets,
          model: model,
          cancellation: token,
          onComment: onComment,
          onProgress: onProgress)
      }.value
      await MainActor.run { self?.finishCommentPass(result) }
    }
  }

  private func showCommentProgress(index: Int, total: Int, key: String) {
    commentDone = index
    commentTotal = total
    commentKey = key
  }

  /// One generated sentence reaches the catalog (an ordinary app-side edit
  /// pending Save) and the log, where the user watches the pass work.
  private func applyGenerated(_ comment: String, for key: String) {
    guard store?.setGeneratedComment(comment, for: key) == true else { return }
    append("[comment] \(key) — \(comment.count > 160 ? String(comment.prefix(160)) + "…" : comment)")
  }

  private func finishCommentPass(_ result: CommentPassOutcome) {
    isCommenting = false
    commentDone = commentTotal
    var outcome = result
    outcome.unlocatedCount = commentUnlocated
    if commentNoFile > 0 {
      outcome.skipped[.noSourceFile, default: 0] += commentNoFile
    }
    comments = outcome
    switch (outcome.didRun, outcome.cancelled) {
    case (false, _):
      let reason = outcome.unavailableReason ?? "the on-device model is unavailable"
      phase = "Comments skipped — \(reason)"
      append("comments skipped: \(reason) (the scan itself is unaffected)")
    case (true, true):
      phase = "Comments cancelled — \(outcome.generatedCount) kept"
      append("comments cancelled after \(outcome.generatedCount) of \(outcome.targetCount)")
    case (true, false):
      phase = "Comments: \(outcome.generatedCount) generated, \(outcome.skippedCount) skipped"
      append("comments: \(outcome.generatedCount) generated of \(outcome.targetCount) in "
        + "\(Self.durationText(outcome.duration)) "
        + String(format: "(%.2fs per comment)", outcome.secondsPerComment))
    }
    // New keys now carry their generated comment into the merge preview.
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
      generatedComments: comments?.generated ?? [:],
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
      generatedComments: comments?.generated ?? [:],
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
      return plan.textSummary(report: report) + commentReportText
    }
    var lines = ["Scan Strings report", "root: \(report.root.path)"]
    lines.append("cancelled after \(Self.durationText(report.duration))")
    return lines.joined(separator: "\n")
  }

  /// The comment pass's own section of the report: what it generated, what it
  /// skipped and why, and the measured cost. Empty until the pass has an
  /// answer (it is scheduled with the scan, so a report normally carries one).
  var commentReportText: String {
    guard let comments else { return "" }
    var lines = ["", "comments (on-device):"]
    if let reason = comments.unavailableReason {
      lines.append("  skipped — \(reason); the scan is unaffected")
      return lines.joined(separator: "\n")
    }
    lines.append("  keys without a comment: \(comments.targetCount)")
    lines.append("  generated: \(comments.generatedCount)")
    for (reason, count) in comments.skipLines {
      lines.append("  skipped — \(reason.label): \(count)")
    }
    if comments.unlocatedCount > 0 {
      lines.append("  not located by the scan (no call site): \(comments.unlocatedCount)")
    }
    if comments.cancelled {
      lines.append("  cancelled after \(comments.generatedCount) of \(comments.targetCount)")
    }
    if comments.generatedCount > 0 {
      lines.append(String(
        format: "  %.2fs per comment, %.1fs total in the model",
        comments.secondsPerComment, comments.modelSeconds))
    }
    if !comments.generated.isEmpty {
      lines.append("")
      lines.append("generated comments (\(comments.generatedCount)):")
      for (key, comment) in comments.generated.sorted(by: { $0.key < $1.key }) {
        lines.append("  \(key)")
        lines.append("      \(comment)")
      }
    }
    return lines.joined(separator: "\n")
  }

  func copyReport() {
    guard let text = reportText else { return }
    KitPasteboard.copy(text)
  }

  static func durationText(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let minutes = Int(seconds) / 60
    let rest = Int(seconds) % 60
    return "\(minutes)m \(rest)s"
  }
}
