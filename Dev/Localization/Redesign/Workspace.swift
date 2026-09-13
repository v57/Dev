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
//  status the bottom bar reports, the overlay's presentation flags, and the human side of
//  the write-back contract: the review and editing actions, and the Save path — the one
//  writer of the `.xcstrings`.
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
      // What a run wrote is in the store, not in the artifact (a run never writes the file
      // — 5.8), so the session is dirty: the leave prompt has to know the file is behind.
      if let run = runner.runs[stage], run.tally.itemsDone > 0 { isDirty = true }
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
    /// recorded HERE rather than from the projected `translatable`: the row projection has no
    /// catalog half, so it reads `true` for a key the FILE already ignores, and writing that
    /// back would silently re-enable it.
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
      isDirty = true
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
      for record in records {
        record.note = text.isEmpty ? nil : text
        record.noteScope = text.isEmpty ? nil : (scope == .projectRule ? Self.ruleScope : Self.memoScope)
        // What the fold did, so the next edit re-folds and a clear retracts. The old
        // browser's columns, kept for the same reason.
        record.noteFoldedText = rule.isEmpty ? nil : rule
        record.noteFoldedAt = rule.isEmpty ? nil : .now
        try? store.upsert(record)
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
      for record in records(of: key).values.flatMap({ $0 }) {
        record.maxWidth = width
        try? store.upsert(record)
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
    private func settle(_ slot: LocalizationString, at: (row: Int, slot: Int)) {
      guard project.data[at.row].targets[at.slot] != slot else { return }
      project.data[at.row].targets[at.slot] = slot
      isDirty = true
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
      // `setNote` cannot throw, so a failed store write leaves the body and its bump in
      // memory — the same shape `Context.append` has, and the next write republishes them.
      try? project.context.save()
    }
    /// The raw `noteScope` a record carries. The strings are the store's ABI — the old browser
    /// writes and reads them — so the two cases must not be renamed (only the artifact has no
    /// note to keep, which is why this is app-side).
    private static let memoScope = "memo"
    private static let ruleScope = "project"

    // MARK: - persistence

    /// The open artifact: the catalog this session is saved through, and where it came from.
    /// Parsed once and kept — the app's copy of the file rather than a per-save re-read —
    /// because a run never touches the artifact and Save is its only writer (5.8).
    private var catalog: StringCatalog?
    private var catalogURL: URL?
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

    /// Save is the only writer of the `.xcstrings`, and it writes through the
    /// catalog model the app already has (format validation, in-memory catalog,
    /// then the file). The store is written after it — and unlike the store, this
    /// is async, because the file is.
    ///
    /// What it writes is the SESSION, and the mapping is 2.1: the status becomes the file's
    /// state (`needsTranslate` -> `new`, `translated` -> `needs_review`, `verified` ->
    /// `translated`), an ignored key becomes `shouldTranslate = false` with its values kept,
    /// and `.stale` and `.imported` are never written — one is app-side knowledge no file can
    /// express, the other is the file's own. Everything the session does not model is left
    /// exactly where the file has it, so an artifact another tool wrote survives a Save.
    func save() async throws {
      guard !project.data.isEmpty else { return }
      do {
        let (parsed, url) = try await artifact()
        var outgoing = parsed
        apply(to: &outgoing)
        try await file(outgoing, to: url)
        catalog = outgoing
        catalogURL = url
        // The artifact holds the session now, so the edits are no longer pending on disk —
        // even if the store write below is the thing that fails. A failed store write is its
        // own problem: `saveData`'s change gate finds whatever it missed on the next Save.
        isDirty = false
        // After the file (7.4). The session's values, states and stamps land in the store
        // together with the ONE journal row a verified value that MOVED earns — the corpus
        // `learn` folds, which is why no single edit writes a journal row of its own.
        try project.saveData()
        error = nil
      } catch {
        self.error = error.localizedDescription
        throw error
      }
    }
    /// Closing with unsaved edits owes the user the same three-way contract as
    /// today: save, discard, or stay.
    ///
    /// A Save that fails keeps the session where it is — `error` is showing and the caller
    /// stays — instead of dropping edits the app could not write. `discard` is the answer
    /// that drops them.
    func resolveLeave(_ choice: LeaveChoice) async {
      switch choice {
      case .save: try? await save()
      case .discard: discard()
      // The caller keeps its workspace open; the session is untouched.
      case .stay: return
      }
    }
    /// Drops what no Save wrote: the rows are re-projected from the store, which is where
    /// everything a run wrote already is (`Runner.persist`) and where the last Save put the
    /// human's values. A run's results therefore survive a discard; an unconfirmed edit does
    /// not, which is the whole point of asking.
    private func discard() {
      project.data.removeAll()
      project.rowIndex.removeAll()
      translatableEdits.removeAll()
      ignoredStatuses.removeAll()
      try? project.loadData()
      isDirty = false
      error = nil
    }
    enum LeaveChoice {
      case save
      case discard
      case stay
    }
    /// What a Save reports when it cannot write: which project has no catalog file, and what
    /// the file itself said. The artifact is the only file the app writes, so both halves carry
    /// a message a human can act on.
    enum SaveError: LocalizedError {
      /// The store holds no project row for this workspace, so there is no file to write.
      case noArtifact(project: String)
      /// The file could not be read (or parsed) on the way in.
      case unreadable(reason: String)
      var errorDescription: String? {
        switch self {
        case .noArtifact(let project): "No .xcstrings file is recorded for \(project)."
        case .unreadable(let reason): "Couldn't read the catalog: \(reason)"
        }
      }
    }
    /// The artifact this session is saved through, parsed once and kept.
    ///
    /// WHERE it is comes from the app's own project row (`Store.projectRow(id:)` then
    /// `catalogURL`): the redesign's `Project` holds no handle on the open catalog, because
    /// opening and parsing the `.xcstrings` is the catalog layer's async work (7.1). When that
    /// layer lands, this is the one place that should adopt the catalog it already opened.
    private func artifact() async throws -> (StringCatalog, URL) {
      if let open = catalog, let url = catalogURL { return (open, url) }
      guard let row = try store.projectRow(id: project.id) else {
        throw SaveError.noArtifact(project: project.id)
      }
      switch await StringCatalog.loadOffMainActor(row.catalogURL) {
      case .success(let parsed):
        catalog = parsed
        catalogURL = row.catalogURL
        return (parsed, row.catalogURL)
      case .failure(let error):
        throw SaveError.unreadable(reason: error.localizedDescription)
      }
    }
    /// The session as the artifact holds it (2.1). Every row of the session is visited, and
    /// nothing outside them is touched.
    private func apply(to catalog: inout StringCatalog) {
      for row in project.data {
        if let translatable = translatableEdits[row.key], var entry = catalog.strings[row.key] {
          entry.shouldTranslate = translatable ? nil : false
          catalog.strings[row.key] = entry
        }
        for slot in row.targets { apply(slot, of: row, to: &catalog) }
      }
    }
    /// One slot as the file carries it.
    ///
    /// Three statuses write nothing at all: `.stale` (app-side knowledge, never written),
    /// `.imported` (the shipped database is not a writer — the file keeps what it carried) and
    /// `.ignore` (the key is flagged; its values are the file's). A `.needsTranslate` slot with
    /// nothing in it writes nothing either: absence IS "not translated" in the format, and
    /// writing `new` for every untouched slot of a project would rewrite a whole catalog on the
    /// first Save.
    ///
    /// A shape the session and the FILE disagree on stays as the file has it — a flat slot never
    /// writes into a plural-varied node, and no device-varied node is touched — which is the old
    /// merge's shadowing rule, restated here because the redesign calls nothing in that file.
    private func apply(
      _ slot: LocalizationString, of row: LocalizationKey, to catalog: inout StringCatalog
    ) {
      // The source language is AUTHORED text, not a translation: the artifact owns it and the
      // store seeds no slot for it.
      guard slot.language != catalog.sourceLanguage else { return }
      let state: String
      switch slot.status {
      case .needsTranslate: state = "new"
      case .translated: state = "needs_review"
      case .verified: state = "translated"
      case .stale, .imported, .ignore: return
      }
      switch slot.target {
      case .value(let text):
        guard !text.isEmpty else { return }
        guard !catalog.hasPlurals(for: row.key, language: slot.language),
          !catalog.hasDeviceVariations(for: row.key, language: slot.language)
        else { return }
        setUnit(text, state: state, key: row.key, language: slot.language, in: &catalog)
      case .plural(let forms):
        guard !forms.isEmpty else { return }
        // A flat unit the file carried becomes the plural set — the move `varyByPlural` makes,
        // and the reason it is cleared rather than left beside the forms.
        clearUnit(key: row.key, language: slot.language, in: &catalog)
        for form in forms.values {
          // An empty form is absent: `setPluralValue` drops its unit, which is how a cleared
          // form leaves the file (and how a form the language does not fill stays absent).
          catalog.setPluralValue(
            form.value, state: form.value.isEmpty ? nil : state,
            key: row.key, language: slot.language, category: form.rule.rawValue)
        }
      }
    }
    /// One flat unit written into a node, leaving the node's variations and substitutions where
    /// they are: the flat unit is the session's to write and nothing else there is.
    private func setUnit(
      _ text: String, state: String, key: String, language: String, in catalog: inout StringCatalog
    ) {
      guard var entry = catalog.strings[key] else { return }
      var localizations = entry.localizations ?? [:]
      var node = localizations[language] ?? StringCatalog.Language()
      node.stringUnit = StringCatalog.StringUnit(state: state, value: text)
      localizations[language] = node
      entry.localizations = localizations
      catalog.strings[key] = entry
    }
    /// The flat unit of a node dropped, so a plural set can take its place (`nil` is absence,
    /// and normalization drops a node left with nothing).
    private func clearUnit(key: String, language: String, in catalog: inout StringCatalog) {
      guard var entry = catalog.strings[key],
        var localizations = entry.localizations,
        var node = localizations[language]
      else { return }
      node.stringUnit = nil
      localizations[language] = node
      entry.localizations = localizations
      catalog.strings[key] = entry
    }
    /// The artifact written off the main actor: the encode and the write are the one part of a
    /// Save that is genuinely async (7.1). The writer is the catalog model's own — it normalizes
    /// the shapes Xcode's compiler rejects and writes atomically — so none of the file-format
    /// work is redone here (7.4).
    private func file(_ catalog: StringCatalog, to url: URL) async throws {
      try await Task.detached { try catalog.save(to: url) }.value
    }
  }
}
