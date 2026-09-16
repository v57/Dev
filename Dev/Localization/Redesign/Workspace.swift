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
//  status the bottom bar reports, the overlay's presentation flags, the human side of the
//  write-back contract (the review and editing actions), and the PUBLISH step — what hands
//  the session to the app's own open catalog, the ONE instance Save writes (5.8).
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
    /// What the session owes the artifact. The APP's flag whenever the pane has handed its
    /// store over — that is the flag ⌘S, the Save button and the unsaved-changes prompt are
    /// built from (5.8), and a run that raised only its own reading could be lost with no
    /// prompt at all — and the session's own reading when there is no store to ask (a
    /// preview, a probe).
    var isDirty: Bool { app?.hasUnsavedChanges ?? sessionDirty }
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
      /// WHICH PLAN the run is on (`Run.Mode`, 8.1). The bar names it for a plan that differs
      /// from the usual one: a run of three steps whose line said nothing would let the two
      /// absent steps read as steps that did nothing, when they are absent by choice. Nil when
      /// this project has never run that stage.
      var mode: Run.Mode?
      /// Items done against the items the run has CUT. The plan is discovered one
      /// operation at a time — a stage's batches exist only once it is scanned — so
      /// the total grows as the run walks its steps rather than being known up front.
      var done = 0
      var total = 0
      var failures = 0
      /// Where the last run of this stage stopped, when no run of it is in memory.
      var checkpoint: Int?
      /// One line for the status bar: the state, the plan it is running, the step it is on, how
      /// far it got, and what it is carrying (8.1).
      ///
      /// The PLAN is named only when it is not the usual one: a run of three steps has to say it
      /// is skipping the learning steps, or the two steps it never reaches read as steps that did
      /// nothing — while the five-step plan's line stays exactly what it always was.
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
        if let mode, mode != .full { line += " · \(mode.title)" }
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
        mode = run.mode
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

    /// What BOTH start buttons are disabled by (8.1): Muse has a credential, and no run of this
    /// workspace is in flight. A run already going is paused or cancelled from its own pages
    /// rather than started again, so the two buttons offer a WAIT — not two more runs.
    ///
    /// One reading, read by the pane's bar and by the toolbar's Start alike, because the two
    /// hosts offer the same pair of buttons: a rule restated per host is a rule that can drift.
    var canStartRun: Bool { canStart && !status.isRunning }

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

    /// THE SECOND WAY IN (reader, 2026-09-14): the same run WITHOUT the learning steps —
    /// prepare, translate, then the row pass.
    ///
    /// Nothing else differs: the same runner, the same stages, the same write-back, the same
    /// retry and the same saving rules. What it does not do is prelearn (the machine record a
    /// human-verified slot is missing) and learn (folding what the human changed into the
    /// project's language document) — right for a project whose documents already carry what
    /// they should.
    ///
    /// Preparation is NOT skipped and cannot be: it is what reads the rows and resolves the
    /// imported database, so without it there is nothing for the translate stages to find (4.8).
    /// The plan is decided in ONE place (`Run.plan`), never by trimming an array here.
    func startSkippingLearning() async throws {
      try await run(.vertical, mode: .skipLearning)
    }

    /// Loads the rows from the open catalog, the language documents and the last cursor,
    /// then applies the imported-database resolve. Workspace open is the one place a
    /// project's rows are read.
    ///
    /// `catalog` is the artifact the pane is showing, PARSED by the catalog layer — its async
    /// half, which owns opening the file (7.1) — and handed over as a value: the rows are one
    /// per CATALOG key (4.8), so the parsing is the whole of what an open waits for. The URL
    /// it came from is adopted with it, because that file is the one the app's catalog is
    /// published into and the one Save writes (5.8); the catalog ITSELF is not kept here, so
    /// there is no second copy of the artifact to drift from the app's.
    ///
    /// What is left for this side of an open is the app-side half: the session rows projected
    /// onto that catalog, the shipped translations that settle a slot before any model call,
    /// and where the last run of each stage stopped. The languages are loaded by the
    /// project's own initializer.
    func open(catalog: StringCatalog, from url: URL) async throws {
      catalogURL = url
      try project.loadData(catalog: catalog)
      try applyImported()
      cursors = Run.plan(for: .vertical).reduce(into: [:]) { found, stage in
        found[stage] = try? store.cursor(for: stage, project: project.id)
      }
    }

    /// The file this session's catalog lives in, for the surfaces that have to NAME what a Save
    /// writes. Nil for a workspace that never went through an open.
    var fileName: String? { catalogURL?.lastPathComponent }

    /// Hands this workspace the app's own store — the one holding the OPEN catalog the
    /// browser displays and Save writes (5.8). The pane is the surface that has both halves
    /// (its store, and the workspace it focused from that store's catalog), so this is where
    /// the two meet.
    ///
    /// Taken WEAKLY: the app owns the store, and a workspace kept for the life of the shell
    /// must not keep a closed window's store alive. A publish with no store attached is not an
    /// error — it is a workspace whose pane has not appeared yet — so the session simply stays
    /// pending (`sessionDirty`) and the attach re-publishes it.
    func attach(_ store: LocalizationStore) {
      app = store
      if sessionDirty { publish() }
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
    /// translation settles its slot as `.imported` — usable, unreviewed, never overwritten by a
    /// run (it is out of every write-back's write set), and written to the artifact as
    /// `needs_review` (5.8) — and writes NO memory entry, because the database is the source
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
    ///
    /// `mode` is which plan a translate run performs (8.1): `.full` is the five steps above,
    /// `.skipLearning` is the same run without the two learning steps. It reaches the runner
    /// and lives on the run, so nothing else here has to know: the rail, the pages and the bar
    /// all read the run's own plan.
    ///
    /// A run needs a usable provider before it starts, so an unconfigured app fails at
    /// the button instead of per batch.
    func run(_ stage: Stage, mode: Run.Mode = .full) async throws {
      // One workspace shows one run at a time, so the rail and the bar follow the run
      // that was just asked for.
      self.stage = stage
      // A NEW run reads the CURRENT world: a slot another writer moved since this session
      // loaded is not this run's to translate (a human's edit in the browser would read as
      // the shipped text it replaced), and its ending SAVES, so the same snapshot would also
      // be written back over it. Adoption is what closes both halves; a run RESUMED from a
      // pause is not this path (it keeps the batches it already cut).
      try project.adoptForeignWrites()
      guard runner.router.isConfigured else {
        error = Self.notConfigured
        throw BackendError.notConfigured(Self.notConfigured)
      }
      do {
        try await runner.run(stage, mode: mode)
      } catch {
        self.error = error.localizedDescription
        throw error
      }
      // A run reports what went wrong ON the run rather than throwing (5.7), so the
      // alert is fed from the run's own last failure — the bar counts them all.
      if let failure = runner.runs[stage]?.failure {
        error = failure.message
      }
      // What a run wrote is in the store, not in the artifact (a run never writes the file
      // — 5.8), so the session is PUBLISHED into the app's own catalog: that is what makes
      // ⌘S live and what the unsaved-changes prompt is built from. Unconditional, because a
      // value translation memory answered is a result too (5.7 counts it apart from the
      // items sent), and a publish that finds nothing to write touches neither the catalog
      // nor the flag.
      publish()
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
      case .paused, .idle:
        try await runner.resume(run)
        // The batches a resume landed are the run's results like any other: the app's
        // catalog is what a Save would write, so it learns about them now (5.8).
        publish()
      case .cancelled, .finished: try await self.run(stage, mode: run.mode)
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

    /// 5.11's action, from the overlay's chrome. It runs exactly the batches the run gave up on —
    /// the failed ones of BOTH translate jobs — as the run holds them: `Runner.retryFailedBatches`
    /// scans nothing, re-cuts nothing and rebuilds nothing off the project, so the requests go out
    /// as they went out the first time and every id is still the position it always was.
    ///
    /// The re-ask's own ending is what the write reads (5.10): it ran on a run that had FINISHED,
    /// so its results are written like any other completion's — through the publish step and the
    /// app's own writer, the ONE writer this session has, so the earlier completion's write is
    /// simply continued. A re-ask the user STOPPED is not that ending: what it landed stays
    /// app-side until an explicit Save, the way a cancelled run's results do.
    func retryFailedBatches() async throws {
      guard let run = runner.runs[stage], run.canRetryFailedBatches else { return }
      guard runner.router.isConfigured else {
        error = Self.notConfigured
        throw BackendError.notConfigured(Self.notConfigured)
      }
      let failures = run.failures.count
      let retry = await runner.retryFailedBatches(run)
      guard retry.batches > 0 else { return }
      if retry.completed {
        await save()
      } else {
        publish()
      }
      // A batch that failed AGAIN is reported the way a run reports one (5.7). The failures list
      // is the attempts' HISTORY and keeps what the original run left there (5.9), so this asks
      // for an entry the re-ask itself added — otherwise a settled failure would raise the alert
      // again — and it leaves a failed write's own message alone.
      if run.failures.count > failures, error == nil, let failure = run.failure {
        error = failure.message
      }
    }

    /// Stops 5.11's re-ask. The run it belongs to is already finished, so what ends is the ASKING:
    /// the batches the re-ask did not reach stay failed and reported, and the button offers exactly
    /// those again.
    func stopRetry() {
      guard let run = runner.runs[stage] else { return }
      runner.stopRetry(run)
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
    ///
    /// All of them edit the SESSION — the rows a run scans and Save writes — so nothing
    /// here touches the artifact and nothing here reaches the store before Save does. The
    /// two exceptions are the note and the width guideline, whose only home IS the store:
    /// the `.xcstrings` format has no field for either.
    func confirm(key: String, language: String) {
      guard let at = position(of: key, language: language) else { return }
      var slot = project.data[at.row].targets[at.slot]
      // Nothing to vouch for: a slot with nothing in it is work, not a decision, and
      // confirming one would write a unit with no value into the file.
      guard !slot.target.isEmpty else { return }
      slot.status = .verified
      // The snapshot 2.5 describes: the value as the human settled it. `toLearn` compares
      // it with the target, which is what makes a confirmation that moved nothing teach
      // nothing and a later edit re-arm learning for the slot. It reaches the store through
      // `saveData`, so a re-armed slot still reads re-armed after a relaunch.
      slot.reviewed = slot.target
      // Settled NOW, against the documents as they stand (3.3): a value a human just approved
      // cannot be stale the moment it was approved, and this stamp is the input the
      // staleness comparison reads (3.4).
      slot.versions = project.currentVersion(for: language)
      settle(slot, at: at)
    }
    /// Every slot of one row that has a value: the human read the row and vouched for what
    /// it says, not for one column of it. An empty slot is left alone — there is nothing in
    /// it to confirm.
    func confirmRow(_ key: String) {
      guard let row = project.row(key) else { return }
      for slot in row.targets where !slot.target.isEmpty {
        confirm(key: key, language: slot.language)
      }
    }
    /// Back to the review queue: `.verified` -> `.translated`, the status the artifact calls
    /// `needs_review` (2.1). Deliberately NOT `.needsTranslate`: the value is still there and
    /// is now output a run may rewrite, which is exactly what un-confirming a slot means. The
    /// confirmation snapshot and the stamp stay where they are — un-reviewing a value is not
    /// an edit of it.
    ///
    /// A slot that is not `.verified` is already in or out of that queue for a reason of its
    /// own, so this does nothing to it.
    func markNeedsReview(key: String, language: String) {
      guard let at = position(of: key, language: language),
        project.data[at.row].targets[at.slot].status == .verified
      else { return }
      var slot = project.data[at.row].targets[at.slot]
      slot.status = .translated
      settle(slot, at: at)
    }
    /// `shouldTranslate = false`. The value is kept — ignoring a key is not
    /// deleting its translation.
    ///
    /// The flag has two halves and neither is a value: the row's `translatable`, which every
    /// scan reads, and the slots' `.ignore`, which is what keeps a run off them whatever the
    /// flag says (`Run.writable` refuses the status). Ignoring writes both, remembering what
    /// each slot was so that re-enabling can put it back — the store's own record is the
    /// fallback, because `.ignore` is app-side knowledge a record cannot express (2.1) and the
    /// state under it is untouched. A value a human confirmed therefore comes back `.verified`
    /// rather than as machine output: re-enabling a key is not a review decision.
    ///
    /// The artifact carries the flag and nothing else, and Save writes it from the toggle
    /// recorded HERE rather than from the projected `translatable`: the projection now carries
    /// the FILE's own flag (4.8), so writing every row's flag back would rewrite
    /// `shouldTranslate` across the whole catalog instead of the one key the human toggled.
    func setTranslatable(_ translatable: Bool, key: String) {
      guard let row = project.rowIndex[key], project.data.indices.contains(row),
        project.data[row].translatable != translatable
      else { return }
      project.data[row].translatable = translatable
      translatableEdits[key] = translatable
      let stored = translatable ? records(of: key) : [:]
      let remembered = ignoredStatuses[key]
      for slot in project.data[row].targets.indices {
        let current = project.data[row].targets[slot]
        if translatable {
          project.data[row].targets[slot].status =
            remembered?[current.language]
            ?? restored(current, records: stored[current.language] ?? [])
        } else {
          ignoredStatuses[key, default: [:]][current.language] = current.status
          project.data[row].targets[slot].status = .ignore
        }
      }
      // The flag is the artifact's and the statuses moved with it, so the row is published
      // whole: the app's catalog is what Save writes, and ⌘S has to be live for it.
      publish(project.data[row])
    }

    // MARK: - editing

    /// The human's text for one slot.
    ///
    /// An inline edit is NOT a confirmation. `.verified` is `confirm`'s to produce and
    /// nothing else may produce it (2.2), so an edit of a value the human already owns keeps
    /// `.verified` — a refinement re-arms learning through the snapshot, which the edit
    /// leaves where it is (2.5) — and an edit of anything else leaves unreviewed output
    /// behind, which is what the review step is for. An ignored row keeps `.ignore`: it is
    /// out of scope and the value it holds is kept.
    ///
    /// `machine` is never touched: that body is the model's own output, and learning is
    /// exactly the comparison of it with what the human settled on (2.4).
    func setValue(_ value: StringBody, key: String, language: String) {
      guard let at = position(of: key, language: language) else { return }
      var slot = project.data[at.row].targets[at.slot]
      slot.target = value
      slot.status = status(of: slot, after: project.data[at.row])
      settle(slot, at: at)
    }
    /// One form of a plural slot.
    ///
    /// The slot's shape comes from the artifact: the form set is the target language's, a
    /// rule that language does not carry writes nothing (the set stays the same across the
    /// slot's bodies — 1.4), and a body that was flat is promoted the way
    /// `StringCatalog.varyByPlural` promotes the file's own unit: its text becomes `other`,
    /// because every CLDR set has one.
    func setPluralValue(_ value: String, key: String, language: String, rule: Plural.Rule) {
      guard let at = position(of: key, language: language) else { return }
      var slot = project.data[at.row].targets[at.slot]
      var target = plurals(slot.target, language: language)
      target.set(value, for: rule)
      slot.target = .plural(target)
      // The other two bodies are plural bodies too (1.4), so a flat one is promoted here
      // instead of being left for `saveData` to stamp onto every form of the slot.
      slot.machine = .plural(plurals(slot.machine, language: language))
      if let reviewed = slot.reviewed { slot.reviewed = .plural(plurals(reviewed, language: language)) }
      slot.status = status(of: slot, after: project.data[at.row])
      settle(slot, at: at)
    }
    /// A note is a memo for humans, or a project RULE that the translator follows.
    /// A memo never reaches a document or a model.
    ///
    /// The note itself is app-side and key-scoped: `TranslationRecord.note` and `noteScope`,
    /// the two columns the old browser writes, across every record of the key. Nothing here
    /// is in the artifact, so no Save is owed and the session is not dirty.
    ///
    /// A PROJECT RULE has a second half: the text is folded into the project document as one
    /// plain prose line (3.5 — an exact-line membership test, no model call). A note that
    /// becomes a memo, or is cleared, RETRACTS the line it folded, and a text that did not
    /// change writes nothing — not even a version bump (3.3).
    ///
    /// The key's records are ONE transaction (7.6): the note lands on every record of the key or
    /// on none, so the loop writes through without saving and the key pays ONE `Store.save()`.
    /// A failure is REPORTED where the reader looks (`error`, the pane's alert) instead of being
    /// swallowed by `try?`, and what did not land is rolled back — a note that reads as stored
    /// when it is not is worse than an error.
    func setNote(_ note: String?, scope: NoteScope, key: String) {
      let text = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let records = records(of: key).values.flatMap { $0 }
      let folded = records.compactMap(\.noteFoldedText).first { !$0.isEmpty } ?? ""
      // The line this note owns: empty for a memo and for a cleared note, so one path below
      // covers folding, replacing and retracting.
      let rule = scope == .projectRule ? text : ""
      if rule != folded {
        if folded.isEmpty {
          // A new rule goes through the document's own append: it bumps once, it never
          // duplicates a line, and it is what publishes a scope nothing had written for.
          if !rule.isEmpty { project.context.append(value: rule) }
        } else {
          replace(folded, with: rule)
        }
      }
      do {
        for record in records {
          record.note = text.isEmpty ? nil : text
          record.noteScope = text.isEmpty ? nil : (scope == .projectRule ? Self.ruleScope : Self.memoScope)
          // What the fold did, so the next edit re-folds and a clear retracts. The old
          // browser's columns, kept for the same reason.
          record.noteFoldedText = rule.isEmpty ? nil : rule
          record.noteFoldedAt = rule.isEmpty ? nil : .now
          try store.upsert(record, saving: false)
        }
        try store.save()
      } catch {
        store.rollback()
        self.error = error.localizedDescription
      }
    }
    /// The reviewer's guideline. Review side only: it never enters a prompt except
    /// as a gate input for an item that is already over it.
    ///
    /// Key-scoped and app-local — `TranslationRecord.maxWidth`, nil clears it — and like a
    /// note it is written to the store at once, because that column is the only place it can
    /// live: the artifact has no width field and `saveData` lifts values, states and stamps
    /// rather than this. The ROW carries the guideline a run sends only from the next
    /// projection on (its `maxWidth` is not settable), so a change here reaches a prompt from
    /// the next open.
    func setMaxWidth(_ width: Int?, key: String) {
      // The key's records are ONE transaction here too (7.6), for the same reason the note's
      // are: the guideline lands on every record of the key or on none, and a failed write is
      // surfaced rather than swallowed — a width the reviewer set and the pane shows as stored
      // is a promise the next run relies on.
      do {
        for record in records(of: key).values.flatMap({ $0 }) {
          record.maxWidth = width
          try store.upsert(record, saving: false)
        }
        try store.save()
      } catch {
        store.rollback()
        self.error = error.localizedDescription
      }
    }

    enum NoteScope {
      /// Stored on the row, shown in the app, sent to nobody.
      case memo
      /// Folded into the project document as a rule the translator follows.
      case projectRule
    }

    // MARK: - the session

    /// Where one slot sits in the session, or nil when the key is not a row of this project.
    /// The key is the identity every operation carries (1.1), so nothing here is addressed by
    /// array position.
    private func position(of key: String, language: String) -> (row: Int, slot: Int)? {
      guard let row = project.rowIndex[key], project.data.indices.contains(row),
        let slot = project.data[row].index(of: language)
      else { return nil }
      return (row, slot)
    }
    /// Puts an edited slot back on its row. The session is marked dirty only when the edit
    /// really changed something: a confirmation of a value nobody touched is not an edit of
    /// the artifact, and the leave prompt should not be raised for it.
    ///
    /// The edit is PUBLISHED as it lands (5.8): the app's catalog is the object Save writes
    /// and the object its dirty flag is about, so an edit that only reached the session would
    /// be one ⌘S could not see. One ROW is published rather than the whole session — an edit
    /// is one row's work, and a full walk per keystroke is not a price an editor should pay.
    private func settle(_ slot: LocalizationString, at: (row: Int, slot: Int)) {
      guard project.data[at.row].targets[at.slot] != slot else { return }
      project.data[at.row].targets[at.slot] = slot
      publish(project.data[at.row])
    }
    /// What an edit does to a slot's status.
    ///
    /// `.verified` is `confirm`'s to produce (2.2), so an edit keeps a status the human
    /// already owns and otherwise leaves unreviewed output behind: the typed text is not yet a
    /// decision, and the review step is what turns it into one. An ignored row keeps
    /// `.ignore`, and a slot an edit left with nothing in it is work again (2.2's "a human
    /// clearing a slot").
    private func status(
      of slot: LocalizationString, after row: LocalizationKey
    ) -> LocalizationString.Status {
      guard row.translatable else { return .ignore }
      if slot.status == .verified { return .verified }
      return slot.target.isEmpty ? .needsTranslate : .translated
    }
    /// A body as a plural set over the target language's rules: a flat body's text becomes
    /// `other` (every CLDR set has one) and an existing set is kept exactly as it is, so the
    /// three bodies of a plural slot stay parallel (1.4).
    private func plurals(_ body: StringBody, language: String) -> Plurals {
      switch body {
      case .plural(let forms): return forms
      case .value(let text):
        var forms = Plurals(language: language)
        forms.set(text, for: .other)
        return forms
      }
    }
    /// This project's records for one key, by language — `Store.records` is the one fetch a
    /// project's rows are read through, and it is filtered here rather than fetched per slot.
    private func records(of key: String) -> [String: [TranslationRecord]] {
      let all = (try? store.records(project: project.id)) ?? []
      return Dictionary(grouping: all.filter { $0.key == key }, by: \.language)
    }
    /// The status a slot returns to when its key is translatable again: the store's own record
    /// still says who wrote the value, because `.ignore` writes no state (2.1). The rule is the
    /// row projection's, restated rather than re-derived so that re-enabling a key can neither
    /// promote nor demote: a machine value comes back `.translated`, a human's `.verified`,
    /// shipped output `.imported`.
    private func restored(
      _ slot: LocalizationString, records: [TranslationRecord]
    ) -> LocalizationString.Status {
      guard !slot.target.isEmpty, let record = records.first else { return .needsTranslate }
      switch record.state {
      case .empty: return .needsTranslate
      case .needs_review: return .translated
      case .reviewed: return record.autoReviewed ? .imported : .verified
      }
    }
    /// A project document as its rules: one non-empty line each. The document is prose (3.7),
    /// so a line is a rule and an exact-line test is the whole lookup.
    private static func rules(_ body: String) -> [String] {
      body.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }
    /// The rule a previous fold wrote, swapped for the new one — or dropped, when the new one
    /// is empty (a retraction). A replacement is ONE real change, so it is one write and one
    /// bump (3.3), and the document has to exist: the line being replaced could only be in the
    /// body because a write published it.
    private func replace(_ folded: String, with rule: String) {
      var lines = Self.rules(project.context.context).filter { $0 != folded }
      if !rule.isEmpty, !lines.contains(rule) { lines.append(rule) }
      let body = lines.joined(separator: "\n")
      guard body != project.context.context else { return }
      project.context.context = body
      project.context.version += 1
      // The DOCUMENT's own write is one write (`saveDocument`, which 7.6 leaves as it is), and a
      // failure here leaves the body and its bump in memory — the same shape `Context.append`
      // has, and the next write republishes them. The key's RECORDS are the other half of a note
      // edit and are not silent: `setNote` reports a failure there, because a note that reads as
      // stored when it is not is worse than an error.
      try? project.context.save()
    }
    /// The raw `noteScope` a record carries. The strings are the store's ABI — the old browser
    /// writes and reads them — so the two cases must not be renamed (only the artifact has no
    /// note to keep, which is why this is app-side).
    private static let memoScope = "memo"
    private static let ruleScope = "project"

    // MARK: - the artifact (5.8)

    /// The app's own store — the instance holding the OPEN catalog the browser displays and
    /// Save writes. The pane hands it over (`attach`), and it is the only way a run's results
    /// reach the artifact: the redesign keeps no catalog of its own and writes no file.
    private weak var app: LocalizationStore?
    /// Where this session's catalog came from — the file Save writes, and the identity a
    /// publish is checked against: a publish aimed at another URL is a stale caller and is
    /// refused, which is the rule `mirrorOpenCatalog` states.
    private var catalogURL: URL?
    /// The session's own reading of "the artifact is behind", for a workspace with no store to
    /// ask. The APP's flag is the one that gates the write (`isDirty`); this keeps a preview
    /// and a probe honest, and `attach` re-publishes whatever it is carrying.
    private var sessionDirty = false
    /// The keys whose `shouldTranslate` flag this session changed, and what it became. The
    /// artifact is the flag's home (2.1) and the row projection cannot read it, so a Save
    /// writes the flag from here and leaves every other entry's alone.
    private var translatableEdits: [String: Bool] = [:]
    /// The status each slot carried before its key was ignored, by key and language.
    ///
    /// `.ignore` is what the session says while the row is out of scope, and the STORE cannot
    /// say what the slot was: `saveData` writes no state for an ignored slot (2.1 — ignore is
    /// app-side knowledge), so a value a human confirmed and then ignored in the same session
    /// would come back as unreviewed machine output. Remembering it here is what keeps a
    /// re-enable from demoting a human's value; the store is the fallback for a key that was
    /// ignored in an earlier session.
    private var ignoredStatuses: [String: [String: LocalizationString.Status]] = [:]

    /// The PUBLISH step (5.8): the session's results are handed to the app's own open catalog
    /// — target, status, and the `shouldTranslate` flag a human toggled — and the artifact is
    /// still written by Save alone, the app's writer, from that same instance.
    ///
    /// This is the whole of what a run deploys. Before it existed the session could produce
    /// every value in a project and the app's catalog never heard about any of it: ⌘S stayed
    /// disabled AND the unsaved-changes prompt saw nothing, so a run's results could be lost
    /// without even being offered. Publishing at the moment they land is what makes the app's
    /// one dirty flag true — which is what the prompt, the Save button and ⌘S are built from.
    ///
    /// A no-op publish (the catalog already carries the session — a re-publish, a save after
    /// a save) changes nothing and raises nothing. A publish with no store to publish into (a
    /// preview, or a pane that has gone away) raises the SESSION's own reading instead, and
    /// `attach` hands the session over the moment a store appears.
    func publish() {
      guard let app, let url = catalogURL else { return markPending() }
      if app.publish(from: url, apply(to:)) { sessionDirty = true }
    }
    /// ONE ROW published — a human edit's shape (5.8): the review and editing actions change
    /// one row, and an editor must not pay for a walk of the whole session to raise a flag.
    /// `publish()` is the run's shape, because a run's output is the project.
    private func publish(_ row: LocalizationKey) {
      guard let app, let url = catalogURL else { return markPending() }
      if app.publish(from: url, { catalog in apply(row, to: &catalog) }) { sessionDirty = true }
    }
    /// The session owes the artifact and there is no catalog to publish it into yet.
    private func markPending() { sessionDirty = true }

    /// SAVE, through the app's own writer (5.8): the session is published into the open
    /// catalog — the instance the browser displays and the one Save writes — and
    /// `LocalizationStore.save` writes the file from it. The redesign has no writer of its
    /// own, which is precisely what makes one dirty flag enough: the app's flag is about the
    /// object that actually reaches the disk.
    ///
    /// The store is written after the file (7.4): the session's values, states and stamps land
    /// together with the ONE journal row a verified value that MOVED earns — the corpus
    /// `learn` folds, which is why no single edit writes a journal row of its own.
    ///
    /// A published session the app could not write leaves `error` set and the flags where they
    /// are, so nothing is reported as saved that is not.
    ///
    /// The three-way leave contract (8.3) is deliberately NOT restated here: a session's edits
    /// ARE the app's catalog edits once they are published, so the app's own unsaved-changes
    /// path — save, discard, or stay — is the one the user meets, and a second copy of it on
    /// this side could only disagree with the flag that gates the write.
    func save() async {
      guard !project.data.isEmpty else { return }
      // The WORLD first, then this session (4.8). This session's rows are a snapshot from its
      // open, and both halves of a save write that snapshot out — the publish step into the
      // app's catalog (which a Save then puts in the file) and `saveData` onto the records —
      // so a record another writer moved since the load is adopted before either runs, or the
      // save silently reverts it. A session that could not READ the world must not write over
      // it: the failure is reported and the save stops.
      do {
        try project.adoptForeignWrites()
      } catch {
        self.error = error.localizedDescription
        return
      }
      publish()
      guard let app else {
        error = "No catalog is open for this project, so there is nothing to save into."
        return
      }
      await app.save()
      guard !app.hasUnsavedChanges else {
        error = app.saveError ?? "The catalog's file was not written, so nothing was saved."
        return
      }
      do {
        try project.saveData()
      } catch {
        self.error = error.localizedDescription
        return
      }
      sessionDirty = false
      error = nil
    }

    /// The session as the artifact holds it (2.1), as a MIRROR of it: every row of the session
    /// is visited and nothing outside those rows is touched — the shape `mirrorOpenCatalog`
    /// has, and the reason a catalog another tool wrote (a scan merge, a generated comment,
    /// a hand edit in the old browser) survives a publish. Returns whether anything really
    /// changed.
    ///
    /// What it carries is what a Save writes: the values and their states, and the
    /// `shouldTranslate` flag this session toggled. What it deliberately does NOT carry is a
    /// COMMENT: the format owns that field and no session state backs it (2.8 — the on-device
    /// pass writes into this same catalog), so every entry keeps the comment the catalog has.
    private func apply(to catalog: inout StringCatalog) -> Bool {
      var changed = false
      for row in project.data {
        if apply(row, to: &catalog) { changed = true }
      }
      return changed
    }
    /// One row published: the flag this session changed, and every slot the row carries.
    private func apply(_ row: LocalizationKey, to catalog: inout StringCatalog) -> Bool {
      var changed = false
      if let translatable = translatableEdits[row.key], var entry = catalog.strings[row.key] {
        let flag: Bool? = translatable ? nil : false
        if entry.shouldTranslate != flag {
          entry.shouldTranslate = flag
          catalog.strings[row.key] = entry
          changed = true
        }
      }
      for slot in row.targets {
        if apply(slot, of: row, to: &catalog) { changed = true }
      }
      return changed
    }
    /// One slot as the file carries it. Returns whether the slot really moved.
    ///
    /// Two statuses write nothing at all: `.stale` (app-side knowledge, never written) and
    /// `.ignore` (the key is flagged; its values are the file's). A `.needsTranslate` slot with
    /// nothing in it writes nothing either: absence IS "not translated" in the format, and
    /// writing `new` for every untouched slot of a project would rewrite a whole catalog on the
    /// first Save.
    ///
    /// `.imported` writes as `needs_review`: a shipped translation nobody has vouched for is the
    /// same thing the artifact calls unreviewed, which is the state `.translated` (machine
    /// output) rides in. It must NOT write `"translated"` — that is Xcode's word for a human
    /// confirmation, and the `.imported` / `.verified` distinction is app-side knowledge the file
    /// cannot carry (a value it held as `"translated"` would read back as a human's).
    ///
    /// A shape the session and the FILE disagree on stays as the file has it — a flat slot never
    /// writes into a plural-varied node, and no device-varied node is touched — which is the old
    /// merge's shadowing rule, restated here because the redesign calls nothing in that file.
    private func apply(
      _ slot: LocalizationString, of row: LocalizationKey, to catalog: inout StringCatalog
    ) -> Bool {
      // The source language is AUTHORED text, not a translation: the artifact owns it and the
      // store seeds no slot for it.
      guard slot.language != catalog.sourceLanguage else { return false }
      let state: String
      switch slot.status {
      case .needsTranslate: state = "new"
      // Both unreviewed shapes land in the same file state: the artifact has one word for
      // "nobody has vouched for this", and which side produced it stays app-side.
      case .translated, .imported: state = "needs_review"
      case .verified: state = "translated"
      case .stale, .ignore: return false
      }
      switch slot.target {
      case .value(let text):
        guard !text.isEmpty else { return false }
        guard !catalog.hasPlurals(for: row.key, language: slot.language),
          !catalog.hasDeviceVariations(for: row.key, language: slot.language)
        else { return false }
        return setUnit(text, state: state, key: row.key, language: slot.language, in: &catalog)
      case .plural(let forms):
        guard !forms.isEmpty else { return false }
        // A flat unit the file carried becomes the plural set — the move `varyByPlural` makes,
        // and the reason it is cleared rather than left beside the forms. The forms are
        // compared as a SET before and after, which is also what makes the flat unit's
        // removal part of the change.
        let before = Self.signature(of: catalog, key: row.key, language: slot.language)
        clearUnit(key: row.key, language: slot.language, in: &catalog)
        for form in forms.values {
          // An empty form is absent: `setPluralValue` drops its unit, which is how a cleared
          // form leaves the file (and how a form the language does not fill stays absent).
          catalog.setPluralValue(
            form.value, state: form.value.isEmpty ? nil : state,
            key: row.key, language: slot.language, category: form.rule.rawValue)
        }
        return Self.signature(of: catalog, key: row.key, language: slot.language) != before
      }
    }
    /// One (key, language) node as it COMPARES: its flat unit and its plural forms, each with
    /// the state it carries. An empty value reads as ABSENCE — the artifact says "cleared" by
    /// dropping a unit, so a node carrying an empty `stringUnit` is no more written than one
    /// carrying none — and the plural forms are compared as a set, so their order cannot make
    /// a difference out of nothing.
    ///
    /// Device variations and substitutions are deliberately NOT in the signature: the mapping
    /// above never touches either, so they can never be the thing that changed.
    private static func signature(
      of catalog: StringCatalog, key: String, language: String
    ) -> [String: String] {
      var signature: [String: String] = [:]
      if let unit = catalog.strings[key]?.localizations?[language]?.stringUnit,
        let value = unit.value, !value.isEmpty {
        signature[""] = "\(unit.state ?? "")\u{1}\(value)"
      }
      for (category, unit) in catalog.pluralUnits(for: key, language: language) ?? [:] {
        guard let value = unit.value, !value.isEmpty else { continue }
        signature[category] = "\(unit.state ?? "")\u{1}\(value)"
      }
      return signature
    }
    /// One flat unit written into a node, leaving the node's variations and substitutions where
    /// they are: the flat unit is the session's to write and nothing else there is. Returns
    /// whether the unit really moved.
    private func setUnit(
      _ text: String, state: String, key: String, language: String, in catalog: inout StringCatalog
    ) -> Bool {
      guard var entry = catalog.strings[key] else { return false }
      var localizations = entry.localizations ?? [:]
      var node = localizations[language] ?? StringCatalog.Language()
      let unit = StringCatalog.StringUnit(state: state, value: text)
      guard node.stringUnit?.state != unit.state || node.stringUnit?.value != unit.value else {
        return false
      }
      node.stringUnit = unit
      localizations[language] = node
      entry.localizations = localizations
      catalog.strings[key] = entry
      return true
    }
    /// The flat unit of a node dropped, so a plural set can take its place (`nil` is absence,
    /// and normalization drops a node left with nothing).
    private func clearUnit(key: String, language: String, in catalog: inout StringCatalog) {
      guard var entry = catalog.strings[key],
        var localizations = entry.localizations,
        var node = localizations[language],
        node.stringUnit != nil
      else { return }
      node.stringUnit = nil
      localizations[language] = node
      entry.localizations = localizations
      catalog.strings[key] = entry
    }
  }
}
