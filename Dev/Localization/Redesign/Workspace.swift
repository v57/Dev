//
//  Workspace.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  The run's UI state and the write-back contract: the rail, the run controls, and the
//  human actions that are the ONLY producer of a verified slot. A run's edits live here
//  until Save — a run never writes the artifact.
//
//  Implemented here: the run control (`start` is the one button, with run/pause/resume/
//  cancel around it), the `open` that reads the rows, the imported-database resolve, the
//  status the bottom bar reports, and the overlay's presentation flags. Still stubs, and
//  another card's: the review and editing actions and the Save path.
//

import SwiftUI

extension Translation {
  /// One project's translation workspace. It owns the runner; the project owns the
  /// rows; the artifact owns the truth.
  @Observable @MainActor class Workspace {
    let project: Project
    let store: Store
    let runner: Runner

    /// Which run the rail shows. Translating is ONE button: it runs
    /// prepare -> prelearn -> learn -> translate, and the rail shows each
    /// operation's progress as a step of that run. Applying rules is a separate,
    /// explicit, paid run (prepare -> horizontal) with its own confirmation.
    var stage: Stage = .vertical
    /// Languages shown as columns. A language that is in play but hidden is STILL
    /// translated by a run: selection is a view filter, never a scope.
    var shownLanguages: [String] = []
    /// Selected catalog keys — also what a forced horizontal pass runs on.
    var selection: Set<String> = []
    /// App-side edits that are not in the artifact yet. A run makes this true.
    var isDirty: Bool = false
    /// What went wrong, for the alert.
    var error: String?

    init(project: Project, store: Store) {
      self.project = project
      self.store = store
      self.runner = Runner(project: project)
    }

    // MARK: - presentation

    /// The stage pages are a CLOSABLE OVERLAY, not a page of the app. Closing it must
    /// not stop a run — a long sweep is exactly the thing the user wants to dismiss
    /// and watch from the status bar.
    var isOverlayPresented = true

    /// The run this workspace reports on: the one for `stage`, when the project has a
    /// run of it at all. The rail, the overlay's page and the bar all read THIS, so
    /// none of them can report a position the run is not at.
    var run: Run? { runner.runs[stage] }

    /// What the bottom status bar shows while the overlay is closed, and where a
    /// reopen lands.
    ///
    /// DERIVED, never a copy: the bar has to keep reporting a run nothing is pumping,
    /// and a stored snapshot would drift the moment a batch landed — while a computed
    /// one is read straight off the run every time the bar paints.
    var status: Status { Status(run, stage: stage, checkpoint: cursors[stage]?.batchIndex) }
    struct Status {
      var isRunning = false
      /// The run the bar is reporting on.
      var run: Stage = .vertical
      /// The step it is on now, if any — what the overlay scrolls to on reopen. Nil
      /// once the run has no step left (finished, or cancelled).
      var step: Stage?
      /// The run's own state, so the bar can say "paused" from "finished". Nil when
      /// this project has never run that stage.
      var state: Run.State?
      /// Items done against the items the run has CUT. The plan is discovered one
      /// operation at a time — a stage's batches exist only once it is scanned — so
      /// the total grows as the run walks its steps rather than being known up front.
      var done = 0
      var total = 0
      var failures = 0
      /// Where the last run of this stage stopped, when no run of it is in memory.
      var checkpoint: Int?
      /// One line for the status bar: the state, the step it is on, how far it got, and
      /// what it is carrying (8.1).
      var summary: String {
        guard let state else {
          guard let checkpoint, checkpoint > 0 else { return "No run yet" }
          return "No run in this session · last run reached batch \(checkpoint)"
        }
        var line =
          switch state {
          case .idle: "Ready"
          case .scanning: "Scanning"
          case .running: "Running"
          case .paused: "Paused"
          case .cancelled: "Cancelled"
          case .finished: "Finished"
          }
        if let step { line += " · \(step.title)" }
        if total > 0 { line += " · \(done)/\(total)" }
        if failures > 0 { line += " · \(failures) failed" }
        return line
      }
      init() {}
      init(_ run: Run?, stage: Stage, checkpoint: Int? = nil) {
        self.run = stage
        self.checkpoint = checkpoint
        guard let run else { return }
        state = run.state
        isRunning = run.state == .running || run.state == .scanning
        step = run.operation
        done = run.tally.itemsDone
        total = run.tally.items
        failures = run.failures.count
      }
    }
    func closeOverlay() {
      isOverlayPresented = false
    }
    func reopenOverlay() {
      isOverlayPresented = true
    }

    /// What to say about Muse right now — nil when the one model is ready. The two
    /// halves are different problems with different remedies (5.2), and only the first
    /// one stops the button: an unconfigured app cannot run at all, while a parked Muse
    /// is a WAIT the run does itself.
    var museNote: String? {
      guard runner.router.isConfigured else { return Self.notConfigured }
      guard let until = runner.router.cooldownUntil else { return nil }
      return "Muse is parked until \(until.formatted(date: .omitted, time: .shortened)); a run waits for it."
    }

    /// True when the one button can do anything at all: Muse has a credential.
    var canStart: Bool { runner.router.isConfigured }

    private static let notConfigured =
      "Muse is not configured: set \(CommandCodeKeychain.envName) in the login keychain, "
      + "the environment, or ~/.hermes/.env."

    // MARK: - runs

    /// THE ONE BUTTON. Runs the main flow's whole plan in order — prepare, prelearn,
    /// learn, translate, then the row pass — instead of walking stages one at a time.
    /// The row pass is ALWAYS part of it (10.17 resolved): after the columns are
    /// translated it is what adapts machine output to anything a human has verified,
    /// so pressing this again once a verification session is over is how those
    /// corrections reach the rest of the project.
    ///
    /// It is impossible to start twice: a run already in flight is resumed, not
    /// stacked.
    func start() async throws {
      try await run(.vertical)
    }

    /// Loads the rows, the language documents and the last cursor, then applies
    /// the imported-database resolve. Workspace open is the one place a project's
    /// rows are read.
    ///
    /// The artifact itself — opening and PARSING the `.xcstrings` — is the catalog
    /// layer's async work and is not done here; this is the app-side half of an open:
    /// the session rows projected onto the open catalog, the shipped translations that
    /// settle a slot before any model call, and where the last run of each stage
    /// stopped. The languages are loaded by the project's own initializer.
    func open() async throws {
      try project.loadData()
      try applyImported()
      cursors = Run.plan(for: .vertical).reduce(into: [:]) { found, stage in
        found[stage] = try? store.cursor(for: stage, project: project.id)
      }
    }

    /// Where the last run of each stage stopped, read on open.
    ///
    /// A cursor is a POSITION TO REPORT, not an index to jump to: the batches are cut
    /// by the scan, so a run started after a relaunch re-cuts them and its own scan is
    /// the resume (an applied slot is no longer work). The run that persisted the
    /// cursor continues from it in memory (`Runner.resume`); this is what an open knows
    /// when nothing is in memory.
    private(set) var cursors: [Stage: Run.Cursor] = [:]

    /// The imported database, applied before any model call (6.3). A shipped human
    /// translation settles its slot as `.imported` — usable, unreviewed, and written
    /// back by nobody — and writes NO memory entry, because the database is the source
    /// of truth it is and not a lesson about our model.
    ///
    /// Only a slot with nothing in it is resolved: a value the app already holds is
    /// either the human's own (`.verified`) or machine output this project produced,
    /// and a shipped translation does not get to replace either.
    private func applyImported() throws {
      for language in project.languages.keys.sorted() {
        let resolved = try Imported.resolve(rows: project.data, language: language)
        guard !resolved.isEmpty else { continue }
        for index in project.data.indices {
          guard let value = resolved[project.data[index].key],
            let slot = project.data[index].targets.firstIndex(where: { $0.language == language }),
            project.data[index].targets[slot].target.isEmpty,
            Run.writable(project.data[index].targets[slot].status)
          else { continue }
          project.data[index].targets[slot].target = .value(value)
          project.data[index].targets[slot].status = .imported
        }
      }
    }

    // MARK: - runs

    /// Runs a stage's plan: `vertical` is prepare -> prelearn -> learn -> translate
    /// -> the row pass (prelearn, learn and the row pass are operations OF that run,
    /// not controls of their own), and `horizontal` alone re-runs just the sweep.
    /// A run needs a usable provider before it starts, so an unconfigured app fails at
    /// the button instead of per batch.
    func run(_ stage: Stage) async throws {
      // One workspace shows one run at a time, so the rail and the bar follow the run
      // that was just asked for.
      self.stage = stage
      guard runner.router.isConfigured else {
        error = Self.notConfigured
        throw BackendError.notConfigured(Self.notConfigured)
      }
      do {
        try await runner.run(stage)
      } catch {
        self.error = error.localizedDescription
        throw error
      }
      // A run reports what went wrong ON the run rather than throwing (5.7), so the
      // alert is fed from the run's own last failure — the bar counts them all.
      if let failure = runner.runs[stage]?.failure {
        error = failure.message
      }
    }

    /// Stops the batch in flight and keeps everything already applied. The run stays
    /// resumable from where it stopped.
    func pause() {
      guard let run = runner.runs[stage] else { return }
      runner.pause(run)
    }

    /// Continues the run this workspace is reporting on. A run that is not in memory
    /// cannot be continued — its batches would have to be re-cut — so this is the one
    /// button again, whose scan is itself the resume (5.6).
    func resume() async throws {
      guard let run = runner.runs[stage] else {
        try await self.run(stage)
        return
      }
      switch run.state {
      case .paused, .idle: try await runner.resume(run)
      case .cancelled, .finished: try await self.run(stage)
      // Already going: a second start is a wait, not a second run (8.1).
      case .scanning, .running: return
      }
    }

    /// Ends the run and keeps everything already applied. The run is over: Start
    /// builds a fresh one whose scan finds only what is still work.
    func cancel() {
      guard let run = runner.runs[stage] else { return }
      runner.cancel(run)
    }

    /// How many slots the horizontal pass would touch, for the confirmation that
    /// names the cost before it is paid: every WRITABLE slot of a translatable row.
    /// The row travels whole, so a settled column is sent along as context — it is
    /// what the request adapts to — but it is never one of these (4.6).
    var horizontalCandidateCount: Int {
      project.data.reduce(0) { count, row in
        guard row.translatable else { return count }
        return count + row.targets.filter { Run.writable($0.status) }.count
      }
    }

    // MARK: - review

    /// The human actions. `confirm` is the only writer of `.verified`; nothing else
    /// in the system may promote a slot, and a rule cannot reach a verified slot
    /// until it is marked needs-review again.
    func confirm(key: String, language: String) {

    }
    func confirmRow(_ key: String) {

    }
    func markNeedsReview(key: String, language: String) {

    }
    /// `shouldTranslate = false`. The value is kept — ignoring a key is not
    /// deleting its translation.
    func setTranslatable(_ translatable: Bool, key: String) {

    }

    // MARK: - editing

    func setValue(_ value: StringBody, key: String, language: String) {

    }
    func setPluralValue(_ value: String, key: String, language: String, rule: Plural.Rule) {

    }
    /// A note is a memo for humans, or a project RULE that the translator follows.
    /// A memo never reaches a document or a model.
    func setNote(_ note: String?, scope: NoteScope, key: String) {

    }
    /// The reviewer's guideline. Review side only: it never enters a prompt except
    /// as a gate input for an item that is already over it.
    func setMaxWidth(_ width: Int?, key: String) {

    }

    enum NoteScope {
      /// Stored on the row, shown in the app, sent to nobody.
      case memo
      /// Folded into the project document as a rule the translator follows.
      case projectRule
    }

    // MARK: - persistence

    /// Save is the only writer of the `.xcstrings`, and it writes through the
    /// catalog model the app already has (format validation, in-memory catalog,
    /// then the file). The store is written after it — and unlike the store, this
    /// is async, because the file is.
    func save() async throws {

    }
    /// Closing with unsaved edits owes the user the same three-way contract as
    /// today: save, discard, or stay.
    func resolveLeave(_ choice: LeaveChoice) async {

    }
    enum LeaveChoice {
      case save
      case discard
      case stay
    }
  }
}
