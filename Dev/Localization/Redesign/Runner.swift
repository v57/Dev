//
//  Runner.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  The run executor: the state of one run, the batches it is made of, and the one
//  thing that knows HOW a batch happens — admission, prompt assembly, the model,
//  deterministic validation, repair, the paid gate, write-back, checkpoint,
//  telemetry. Semantics are in "Design notes.md", section 5; section 4 says what
//  each operation IS, and that half belongs to the stage files.
//
//  The stage classes know WHAT to send — the predicate, the per-language grouping
//  and the character splitting are theirs. This file knows HOW: `scan` turns what a
//  stage built into the run's own batches, `request(for:)` picks the shape the
//  batch sends, and `apply` is the ONLY writer of a slot. Every call goes to Muse
//  (there is no chain to walk), and the run never writes the artifact: results
//  reach the .xcstrings through the open in-memory catalog and a user Save (5.8).
//
//  Nothing here is referenced by the current pipeline and nothing here calls into
//  it: the two implementations run side by side until the old one is deleted.
//

import Foundation
import Observation
import SwiftData

extension Translation {
  /// The live state of one stage's run. Observable, one per stage, owned by the
  /// workspace — never by the project.
  @Observable @MainActor class Run {
    let stage: Stage
    let project: Project
    /// The operations this run performs, in order — what the rail shows as the
    /// steps of one pass. A translate run is
    /// `[.prepare, .prelearn, .learn, .vertical, .horizontal]`: the row pass is a
    /// step, always, not a separate pass the user triggers.
    var operations: [Stage]
    var state: State = .idle
    /// Which operation of `operations` the run is on. The rail shows each step's
    /// progress through this, and reopening the overlay lands here (8.1).
    var operationIndex: Int = 0
    /// Cursor into `batches`: the next batch to start. Persisted, so an
    /// interrupted run resumes at the next unstarted batch instead of re-billing
    /// the finished ones.
    var batchIndex: Int = 0
    var batches: [Batch] = []
    var tally = Tally()
    /// Everything the run has to report. `failure` is the one the status bar and
    /// an alert show; the list is what the run's own report keeps, because a run
    /// keeps going after a batch fails (5.6).
    var failures: [Failure] = []
    var startedAt: Date?
    var finishedAt: Date?

    init(stage: Stage, project: Project) {
      self.stage = stage
      self.project = project
      operations = Run.plan(for: stage)
    }

    /// The ordered operations behind a run. Preparation is always first: scan the
    /// catalog, merge it into the in-memory catalog, load the session rows and
    /// resolve the imported database, so every later operation sees one settled
    /// set of rows.
    ///
    /// prelearn and learn are operations OF the translate run, not passes a user
    /// starts: prelearn supplies the machine record a human-verified slot is
    /// missing, and learn folds what the human changed into the project's language
    /// document before the column it governs is translated.
    ///
    /// The row pass is the LAST step of that run, and it is always enabled (reader,
    /// 2026-09-14). After the columns are translated, it puts each row in view so the
    /// machine output can be adapted to whatever a human has verified and the rows
    /// whose output is invalid across languages get caught. It is not a setting and
    /// not a separate control: because it runs at the end of every run, pressing the
    /// button again after a verification session is how those corrections reach the
    /// rest of the project — the vertical step finds nothing to redo (verified slots
    /// are not work), prelearn and learn do their thing, and the row pass adapts.
    static func plan(for stage: Stage) -> [Stage] {
      switch stage {
      case .vertical: [.prepare, .prelearn, .learn, .vertical, .horizontal]
      case .horizontal: [.prepare, .horizontal]
      case .prepare: [.prepare]
      case .prelearn, .learn: [.prepare, stage]
      }
    }

    enum State: Equatable {
      case idle
      /// Reading the rows into batches: cheap, on the main actor, cancellable.
      case scanning
      case running
      case paused
      case cancelled
      /// Every batch started; carried failures are the only thing left to report.
      case finished
    }

    /// One model request, and the unit of write-back: a batch that fails leaves
    /// nothing half-applied.
    struct Batch: Identifiable {
      let id: String
      /// The operation that sent it, which is also what routes the request shape,
      /// the write-back and the tally (5.7).
      let stage: Stage
      /// The L1 language for a per-language batch; nil for a row batch, where the
      /// language is named inside each item.
      let language: String?
      var items: [Item]
      let characters: Int
      /// The model that answered — the write-back stamps the slot with it (5.5).
      var model: String = ""
      var phase: Phase = .pending
    }

    /// One slot inside a batch. Its KEY is app-side only: the request's ids are the
    /// items' positions in the batch, and the key is what applies a reply, addresses
    /// memory and journals the edit. Nothing on the wire is ever a key.
    struct Item {
      let key: String
      /// nil on a vertical batch (the batch carries the language); set on a row
      /// batch, where one request spans several languages.
      let language: String?
      let source: StringBody
      let target: StringBody
      let comment: String
      /// The reviewer's guideline. Travels to the model ONLY inside the paid gate,
      /// and only for an item whose reply is already over it.
      let maxWidth: Int
      /// What the machine produced for this slot, where the stage has one to
      /// compare — the learn fold's evidence. Never on the wire for a translate
      /// shape: the item payload is a closed set (4.3).
      var machine: StringBody = .empty
      var phase: Phase = .pending
      /// The document versions the request was built against, stamped when the batch
      /// goes out (5.5). Per ITEM rather than per batch because a row batch spans
      /// several languages, and each of them has its own language document.
      var versions: Context.Version = .none

      /// The text a request actually sends for this row: the row's CONTENT, the
      /// catalog key standing in when nothing was authored (4.3). `Prompt` applies
      /// the same rule where it builds the payload; the runner needs its own copy
      /// because validation compares a reply against what the model was SHOWN, and
      /// the source of a row with nothing authored is the key.
      var payloadSource: StringBody { source.isEmpty ? .value(key) : source }

      /// What this item carries: its source plus the value it answers with, the
      /// same measure the stages split by (`VerticalOperation.characters`).
      var characters: Int { source.characters + target.characters }
    }

    enum Phase: Equatable {
      case pending
      case sent
      case validated
      case repaired
      case applied
      /// Reported, never retried forever: the run keeps its other results.
      case failed
    }

    /// What the run cost and what it covered — the numbers the workspace shows.
    struct Tally {
      var batches = 0
      var batchesDone = 0
      var items = 0
      var itemsDone = 0
      var characters = 0
      var requests = 0
      var promptTokens = 0
      var completionTokens = 0
      /// A flat zero means the provider cache is NOT being hit, which is a bug in
      /// the prompt, not a model property.
      var cachedTokens = 0
      /// The cached share of what went out. This is the number that says whether
      /// the cacheable prefix (system + L0) is still a prefix; a run that reports 0
      /// here has a prompt-layout bug, not an unlucky provider.
      var cachedShare: Double {
        promptTokens > 0 ? Double(cachedTokens) / Double(promptTokens) : 0
      }
      /// Requests per model, so a fallback tier is visible in the report.
      var byModel: [String: Int] = [:]
      /// Items done per operation of the run, so a step that did nothing is
      /// visible as a step that did nothing.
      var byStage: [Stage: Int] = [:]
    }

    /// A failure worth surfacing: the item or batch it happened on, and whether
    /// retrying could help.
    struct Failure {
      let key: String?
      let language: String?
      let message: String
      let retryable: Bool
    }

    /// Where a paused or interrupted run left off.
    struct Cursor {
      var batchIndex: Int
    }

    /// The operation the run is on now, if any.
    var operation: Stage? {
      operations.indices.contains(operationIndex) ? operations[operationIndex] : nil
    }

    /// The failure the status bar shows. The list keeps the rest.
    var failure: Failure? { failures.last }

    var isFinished: Bool { state == .finished || state == .cancelled }

    /// The rule of the write set, and its ONLY rule: a slot the run may write is one
    /// whose OWN status allows it. `.verified` and `.imported` are never overwritten —
    /// a value this project has already committed to is context, not a target (4.6) —
    /// and an ignored key is out of scope for every stage.
    ///
    /// Both the validator and the write-back ask this, and they ask it of the SLOT,
    /// at the moment they ask: a slot the human confirms while a batch is in flight
    /// is settled by the time the reply lands, and the reply is discarded rather than
    /// spending a repair call on a value nobody may write (5.3, 5.5).
    static func writable(_ status: LocalizationString.Status) -> Bool {
      switch status {
      case .needsTranslate, .stale, .translated: true
      case .verified, .imported, .ignore: false
      }
    }
  }

  /// Executes a run. One runner per project: a project can have at most one run
  /// of a stage going, and `learn` is a single writer of language documents.
  @Observable @MainActor class Runner {
    let project: Project
    /// The only client there is. The runner owns it, so a park and the telemetry it
    /// earns belong to the run that paid for them.
    let router: Router
    private(set) var runs: [Stage: Run] = [:]
    var isRunning: Bool {
      runs.values.contains { $0.state == .running || $0.state == .scanning }
    }

    /// The execution in flight, so pause and cancel can interrupt a batch (and a
    /// cooldown sleep) instead of waiting one out.
    private var task: Task<Void, Never>?
    /// The store's slot records, keyed by (key, language, category), fetched once
    /// per run — `Store.records` is one fetch for the whole project, so a per-write
    /// fetch is not an option and neither is a per-batch one.
    private var slotRecords: [SlotKey: TranslationRecord]?
    /// The open catalog's rows by key: what every result is applied by (1.2).
    private var rowPositions: [String: Int] = [:]
    /// The word a fold answers when the document already covers every lesson.
    private static let noChange = "NO_CHANGE"

    init(project: Project) {
      self.project = project
      self.router = Router()
    }

    /// A runner with a client handed in. One client per runner is the point: the
    /// telemetry and the parks are the run's own numbers (5.7).
    init(project: Project, router: Router) {
      self.project = project
      self.router = router
    }

    /// Runs a stage's whole plan, one batch at a time, from its first operation to
    /// its last: a translate run is prepare -> prelearn -> learn -> translate -> the
    /// row pass.
    ///
    /// Starting twice is impossible: a run of this stage that is already in flight
    /// is waited for, and a paused one is resumed from its cursor (8.1).
    @discardableResult
    func run(_ stage: Stage) async throws -> Run {
      if let existing = runs[stage] {
        switch existing.state {
        case .scanning, .running:
          await task?.value
          return existing
        case .paused:
          try await resume(existing)
          return existing
        case .idle, .finished, .cancelled:
          break
        }
      }
      let run = Run(stage: stage, project: project)
      runs[stage] = run
      try await execute(run)
      return run
    }

    /// Continues a run from its cursor, skipping everything already applied. The
    /// batches it already scanned are the ones it keeps going with: re-scanning
    /// would renumber them under the cursor.
    func resume(_ run: Run) async throws {
      guard run.state == .paused || run.state == .idle else { return }
      runs[run.stage] = run
      try await execute(run)
    }

    /// Cancels the batch in flight and keeps everything already applied. The run
    /// stays resumable from its cursor.
    func pause(_ run: Run) {
      guard run.state == .running || run.state == .scanning else { return }
      run.state = .paused
      task?.cancel()
    }

    /// Cancels the batch in flight and keeps everything already applied. The run is
    /// over: pressing Start again builds a fresh one, and its scan finds only what is
    /// still work.
    func cancel(_ run: Run) {
      guard run.state != .finished, run.state != .cancelled else { return }
      run.state = .cancelled
      task?.cancel()
    }

    // MARK: - the plan

    /// Runs a plan in this runner's own task, so pause and cancel can interrupt it.
    /// Nothing propagates out of a run: what went wrong is reported on the RUN, which
    /// is what the overlay and the status bar read (5.7).
    private func execute(_ run: Run) async throws {
      let task = Task { await self.plan(run) }
      self.task = task
      await task.value
      if self.task == task { self.task = nil }
    }

    /// The plan, one operation at a time. Preparation is a single pass with no model
    /// call; every other operation scans its batches and runs them sequentially —
    /// within a language the batches are strictly sequential, because a write-back
    /// changes the column the next batch's register sample is read from (4.5).
    private func plan(_ run: Run) async {
      let isFresh = run.startedAt == nil
      if isFresh {
        run.startedAt = .now
        run.tally = Run.Tally()
        // The telemetry is the client's, and a run's numbers are its own (5.7).
        router.resetTelemetry()
        slotRecords = nil
        indexRows(run)
      }
      run.finishedAt = nil
      run.state = .scanning
      do {
        guard router.isConfigured else {
          // The button checks this before a run starts (5.2), so meeting it here
          // means the credential went away: one failure, not one per batch.
          throw BackendError.notConfigured(
            "Muse is not configured: set \(CommandCodeKeychain.envName) in the login "
              + "keychain, the environment, or ~/.hermes/.env.")
        }
        try await runOperations(run)
        run.state = .finished
      } catch is CancellationError {
        // Pause and cancel both interrupt the batch in flight, and everything
        // applied is kept. The state they set is what the run reports.
        run.state = run.state == .cancelled ? .cancelled : .paused
      } catch {
        fail(run, message: error.localizedDescription, retryable: Self.retryable(error))
        run.state = .finished
      }
      if run.state == .finished || run.state == .cancelled { run.finishedAt = .now }
    }

    /// The operations, in the order `Run.plan` put them in.
    private func runOperations(_ run: Run) async throws {
      while run.operationIndex < run.operations.count {
        try Task.checkCancellation()
        let operation = run.operations[run.operationIndex]
        if operation == .prepare {
          try prepare(run)
          run.operationIndex += 1
          continue
        }
        // The scan happens once per operation per run: a resumed run keeps the
        // batches it already cut, because the cursor counts THOSE.
        if !scanned(operation, in: run) {
          run.state = .scanning
          try scan(operation, into: run)
        }
        run.state = .running
        while run.batchIndex < run.batches.count {
          try Task.checkCancellation()
          let batch = run.batches[run.batchIndex]
          do {
            try await perform(batch, in: run)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            markFailed(batch, error: error, in: run)
            // An unconfigured provider is not a per-batch condition: every later
            // batch would fail the same way, so the run stops and reports instead of
            // spending a request per batch to hear the same answer.
            if let backend = error as? BackendError, case .notConfigured = backend {
              return
            }
          }
          run.tally.batchesDone += 1
          run.batchIndex += 1
          try await checkpoint(run)
        }
        run.operationIndex += 1
      }
    }

    /// Preparation: one pass, NO model call, before any batch, so every later
    /// operation sees one settled set of rows (4.1).
    ///
    /// Opening and parsing the `.xcstrings` is the catalog layer's async work, and
    /// the imported-database resolve belongs to whoever opens a project
    /// (`Workspace.open`); what is left for the run is the session's own load.
    private func prepare(_ run: Run) throws {
      try run.project.loadData()
      indexRows(run)
    }

    /// True when this operation's batches are already in the run and cut.
    private func scanned(_ operation: Stage, in run: Run) -> Bool {
      run.batches.contains { $0.stage == operation }
    }

    /// Scans one operation into the run's batch list. The stage owns WHAT to send —
    /// its predicate, its per-language grouping and its character splitting (4.4) —
    /// so this only turns what it built into the runner's own batches.
    private func scan(_ operation: Stage, into run: Run) throws {
      let batches: [Run.Batch]
      switch operation {
      case .prepare:
        return
      case .prelearn:
        batches = self.batches(of: try project.verticalPrelearn())
      case .learn:
        batches = self.batches(of: try project.verticalLearn())
      case .vertical:
        batches = self.batches(of: try project.verticalTranslate())
      case .horizontal:
        batches = self.batches(of: try project.horizontalTranslate())
      }
      run.batches.append(contentsOf: batches)
      run.tally.batches += batches.count
      run.tally.items += batches.reduce(0) { $0 + $1.items.count }
    }

    // MARK: - what a stage scanned, as the runner's batches

    /// A vertical stage's groups as the runner's batches. The group IS the request,
    /// so every group becomes one batch, in the order the scan produced them.
    ///
    /// The batch's language is copied onto every item as well: the paid gate is
    /// handed the ITEMS and reads the language off them, and a per-language batch's
    /// items carry none of their own by construction (4.3).
    private func batches(of stage: VerticalTranslate) -> [Run.Batch] {
      stage.operations.enumerated().map { ordinal, group in
        Run.Batch(
          id: "\(Stage.vertical.rawValue).\(group.language).\(ordinal)",
          stage: .vertical,
          language: group.language,
          items: group.items.map { operation in
            Run.Item(
              key: operation.key,
              language: group.language,
              source: operation.source,
              target: operation.target,
              comment: operation.comment,
              maxWidth: operation.maxWidth)
          },
          characters: group.items.reduce(0) { $0 + $1.characters })
      }
    }

    /// Prelearn's groups as the runner's batches: the same shape as a language batch,
    /// because the prompt is the same shape and the reply is written to `machine`
    /// only.
    ///
    /// The item carries NO width guideline (`maxWidth: 0`, and `Prompt` omits the
    /// field when it is 0): whether prelearn's request carries one is the prelearn
    /// card's open decision, and the executor does not make it on the way past.
    private func batches(of stage: VerticalPrelearn) -> [Run.Batch] {
      stage.operations.enumerated().map { ordinal, group in
        Run.Batch(
          id: "\(Stage.prelearn.rawValue).\(group.language).\(ordinal)",
          stage: .prelearn,
          language: group.language,
          items: group.items.map { operation in
            Run.Item(
              key: operation.key,
              language: group.language,
              source: operation.source,
              target: operation.target,
              comment: operation.comment,
              maxWidth: 0)
          },
          characters: group.items.reduce(0) { $0 + $1.characters })
      }
    }

    /// Learn's groups as the runner's batches. The item carries the machine's attempt
    /// beside the human's value, because that delta IS the lesson; its `target` is the
    /// human's value, which is what the fold folds in.
    private func batches(of stage: VerticalLearn) -> [Run.Batch] {
      stage.operations.enumerated().map { ordinal, group in
        Run.Batch(
          id: "\(Stage.learn.rawValue).\(group.language).\(ordinal)",
          stage: .learn,
          language: group.language,
          items: group.items.map { operation in
            Run.Item(
              key: operation.key,
              language: group.language,
              source: operation.source,
              target: operation.target,
              comment: operation.comment,
              maxWidth: 0,
              machine: operation.machine)
          },
          characters: group.items.reduce(0) { $0 + $1.characters })
      }
    }

    /// A row stage's groups as the runner's batches. One row becomes ONE item per
    /// language of the row — settled columns included, which is what gives the
    /// request its register reference (4.6) — and each item names its own language,
    /// so the batch itself names none.
    private func batches(of stage: HorizontalTranslate) -> [Run.Batch] {
      stage.operations.enumerated().map { ordinal, group in
        Run.Batch(
          id: "\(Stage.horizontal.rawValue).\(ordinal)",
          stage: .horizontal,
          language: nil,
          items: group.items.flatMap { operation in
            operation.targets.map { slot in
              Run.Item(
                key: operation.key,
                language: slot.language,
                source: operation.source,
                target: slot.target,
                comment: operation.comment,
                maxWidth: operation.maxWidth)
            }
          },
          characters: group.items.reduce(0) { $0 + $1.characters })
      }
    }

    // MARK: - one batch

    /// One batch, start to applied: admission -> prompt -> send -> deterministic
    /// validation -> repair -> the paid gate -> write-back -> checkpoint ->
    /// telemetry (5.1). The checkpoint is the caller's, so the cursor never claims a
    /// batch whose write-back failed.
    private func perform(_ batch: Run.Batch, in run: Run) async throws {
      guard let index = run.batches.firstIndex(where: { $0.id == batch.id }) else { return }
      run.batches[index] = try await performOne(run.batches[index], in: run)
    }

    /// One request's whole life, from the prompt to the row. A re-ask of a cut reply
    /// is this same pipeline on a subset of items, which is why it takes the batch by
    /// value and answers with the batch it produced.
    private func performOne(_ origin: Run.Batch, in run: Run) async throws -> Run.Batch {
      var batch = origin
      // The stamp a slot written now would carry is what the request is built
      // against, so it is read here — once, just before the prompt is assembled.
      for index in batch.items.indices {
        batch.items[index].versions = project.currentVersion(
          for: language(of: batch.items[index], in: batch))
      }
      for index in batch.items.indices { batch.items[index].phase = .sent }
      batch.phase = .sent
      run.tally.characters += batch.characters

      let answer = try await send(request(for: batch, in: run), in: run)
      batch.model = answer.model

      // The fold answers DOCUMENT TEXT: there is nothing per-id to validate, repair
      // or gate, because the reply is not a set of candidates (5.3/5.4 are about
      // candidates).
      if batch.stage == .learn {
        await fold(answer.raw ?? "", of: batch, in: run)
        for index in batch.items.indices { batch.items[index].phase = .applied }
        batch.phase = .applied
        return batch
      }

      let replies = answer.replies
      // Which slots this run may write, resolved from each slot's OWN status at this
      // moment. An answer for a slot that is already settled is DISCARDED, never
      // rejected: spending a repair call on a value nobody is allowed to write is
      // paying twice (4.6).
      let writable = writablePositions(of: batch)
      var report = Validator.validate(replies, for: batch.items, writable: writable)
      report.truncated = answer.raw.map(Validator.isTruncated) ?? false
      for id in report.invented {
        fail(
          run, key: batch.items.first?.key, language: batch.language,
          message: "the reply answered id \(id), which this batch never asked for",
          retryable: false)
      }
      for id in report.accepted.keys.compactMap(Int.init) where batch.items.indices.contains(id) {
        batch.items[id].phase = .validated
      }

      // A reply the model CUT OFF is not a set of bad answers: everything it did
      // complete is real output, and the ids it never reached were lost to the cut.
      // So what arrived is written, and the remainder is re-asked IN HALVES — never
      // repaired one id at a time, which is what a cut is not (5.3).
      if report.truncated, batch.items.count > 1 {
        let answered = try await gate(report.accepted, of: batch, in: run)
        apply(answered, of: &batch, in: run)
        let remaining = batch.items.enumerated()
          .filter { writable.contains($0.offset) && answered[String($0.offset)] == nil }
          .map(\.element)
        for item in try await reask(remaining, of: batch, in: run) {
          guard let position = batch.items.firstIndex(where: {
            $0.key == item.key && $0.language == item.language
          }) else { continue }
          batch.items[position].phase = item.phase
        }
        settle(&batch)
        return batch
      }

      // Only ids that survive are repaired, and each rejected id is repaired in its
      // OWN language, singly: batching them would mix the languages whose L1 blocks
      // are what makes the request work at all (5.3).
      var resolved = report.accepted
      for id in report.rejected {
        guard let position = Int(id), batch.items.indices.contains(position) else { continue }
        let item = batch.items[position]
        let language = language(of: item, in: batch)
        guard let repaired = try await repair(item, in: batch, in: run) else {
          batch.items[position].phase = .failed
          fail(
            run, key: item.key, language: language,
            message: "no usable translation: \(Validator.describe(replies[id], of: item, language: language))",
            retryable: false)
          continue
        }
        batch.items[position].phase = .repaired
        resolved[id] = repaired
      }

      // The paid gate, over everything about to be written (5.4).
      resolved = try await gate(resolved, of: batch, in: run)

      // Write-back: one unit, decided per slot at the moment it is applied (5.5).
      apply(resolved, of: &batch, in: run)

      // Anything still unanswered is reported, never retried forever: the run keeps
      // its other results.
      for (position, item) in batch.items.enumerated()
      where writable.contains(position) && resolved[String(position)] == nil {
        batch.items[position].phase = .failed
        fail(
          run, key: item.key, language: language(of: item, in: batch),
          message: "no translation produced", retryable: false)
      }
      settle(&batch)
      return batch
    }

    /// The remainder of a cut reply, re-asked in halves. Each half is a request of
    /// its own — the full pipeline again, with its own positions — and its items'
    /// phases land on the batch they came from, because a half is a retry of one unit
    /// of the plan and never a unit of its own.
    ///
    /// Recursion terminates: every level halves the count, a single item is never
    /// split, and a request that cannot be answered at all ends as a failure.
    private func reask(_ items: [Run.Item], of batch: Run.Batch, in run: Run) async throws -> [Run.Item] {
      guard !items.isEmpty else { return [] }
      let cut = items.count > 1 ? max(1, items.count / 2) : items.count
      var answered: [Run.Item] = []
      for (ordinal, slice) in [Array(items[..<cut]), Array(items[cut...])].enumerated()
      where !slice.isEmpty {
        let half = Run.Batch(
          id: "\(batch.id).r\(ordinal)",
          stage: batch.stage,
          language: batch.language,
          items: slice,
          characters: slice.reduce(0) { $0 + $1.characters })
        answered.append(contentsOf: try await performOne(half, in: run).items)
      }
      return answered
    }

    /// The batch's phase, read off its items: failed when one of them is, applied
    /// otherwise. A discarded answer (a settled slot) is neither.
    private func settle(_ batch: inout Run.Batch) {
      batch.phase = batch.items.contains { $0.phase == .failed } ? .failed : .applied
    }

    // MARK: - the request

    /// The request a batch sends. The block ORDER is the cache contract and lives in
    /// `Prompt` (4.3); what is decided here is only which shape the batch is.
    private func request(for batch: Run.Batch, in run: Run) -> Prompt.Request {
      switch batch.stage {
      case .vertical:
        return Prompt.languageBatch(
          language: batch.language ?? "", items: batch.items, project: project)
      case .prelearn:
        return Prompt.prelearnBatch(
          language: batch.language ?? "", items: batch.items, project: project)
      case .horizontal:
        return Prompt.rowBatch(items: batch.items, project: project)
      case .learn:
        let language = batch.language ?? batch.items.first?.language ?? ""
        return Prompt.learnFold(
          language: language,
          lessons: lessons(of: batch),
          document: project.language(language)?.context.context ?? "")
      case .prepare:
        // Preparation is a pass, never a request: no batch of it exists.
        return Prompt.Request()
      }
    }

    /// The lessons one fold folds: what the machine produced against what the human
    /// settled on. A lesson whose machine value equals the human's is not built — the
    /// model already agreed with the human, so there is nothing to teach
    /// (`Prompt.Lesson`).
    private func lessons(of batch: Run.Batch) -> [Prompt.Lesson] {
      batch.items.compactMap { item in
        let machine = item.machine.catalogValue
        let value = item.target.catalogValue
        guard !machine.isEmpty, !value.isEmpty, machine != value else { return nil }
        return Prompt.Lesson(
          key: item.key,
          source: item.payloadSource.catalogValue,
          comment: item.comment,
          machine: machine,
          value: value)
      }
    }

    // MARK: - the model

    /// One answered request: the per-id answers as text, the raw reply, and the model
    /// that produced them.
    private struct Answer {
      var replies: [String: String] = [:]
      var raw: String?
      var model: String = ""
    }

    /// One request, through Muse and nothing else (5.2). Admission suspends on the
    /// per-minute budget rather than burning a batch on a refusal, and a parked Muse
    /// is WAITED out — there is no second candidate to fall back to, so waiting is
    /// the only thing that is not giving up.
    ///
    /// The reply is read from the RAW text: `Router.values(in:)` casts `text` to a
    /// String, which drops a plural answer (an object of categories) and with it the
    /// whole item, so the runner parses the reply it depends on itself (10.15's
    /// "a reply's text mirrors the payload body").
    private func send(_ request: Prompt.Request, in run: Run) async throws -> Answer {
      let candidate = try await candidate()
      try await router.admit(candidate)
      _ = try await router.send(request, using: candidate)
      run.tally.byModel[candidate.model, default: 0] += 1
      readTelemetry(run)
      return Answer(
        replies: router.lastRawReply.map(Validator.answers(in:)) ?? [:],
        raw: router.lastRawReply,
        model: candidate.model)
    }

    /// Muse, or a wait. `next()` answers nil exactly while Muse is parked, so the run
    /// sleeps out the park instead of failing the batch; a park with no readable
    /// instant falls back to the fixed window rather than spinning.
    private func candidate() async throws -> Router.Candidate {
      while true {
        try Task.checkCancellation()
        if let candidate = router.next() { return candidate }
        let wait = router.cooldownUntil?.timeIntervalSinceNow ?? Router.cooldownWindow
        try await Task.sleep(nanoseconds: UInt64(max(wait, 1) * 1_000_000_000))
      }
    }

    /// A rejected id, repaired on its own, in its own language. The answer is
    /// validated like any other: a repair that is itself empty or an echo is not an
    /// answer (5.3).
    private func repair(_ item: Run.Item, in batch: Run.Batch, in run: Run) async throws -> String? {
      let language = language(of: item, in: batch)
      let answer = try await send(
        Prompt.repair(item: item, language: language, project: project), in: run)
      // A repair request is a one-item batch: its ids are exactly ["0"].
      guard let text = answer.replies["0"] else { return nil }
      let body = Validator.decode(text, for: item, language: language)
      return Validator.defects(body, of: item).isEmpty ? text : nil
    }

    /// The one paid call (5.4): the candidates that were already in the prompt, plus
    /// `{id, valid, fix}`.
    ///
    /// A correction is trusted only when it passes the same free checks the candidate
    /// did; a settled slot is never a target, so a fix for one is discarded; and an
    /// item that cannot be fixed is written AS IS rather than dropped, which is why a
    /// rejected correction leaves the candidate alone.
    private func gate(
      _ resolved: [String: String], of batch: Run.Batch, in run: Run
    ) async throws -> [String: String] {
      guard !resolved.isEmpty else { return resolved }
      let answer = try await send(
        Prompt.review(project: project, items: batch.items, replies: resolved), in: run)
      guard let raw = answer.raw else { return resolved }
      let writable = writablePositions(of: batch)
      var corrected = resolved
      for (id, review) in Validator.reviews(in: raw) {
        guard let position = Int(id), batch.items.indices.contains(position),
          writable.contains(position), resolved[id] != nil,
          !review.valid, let fix = review.fix
        else { continue }
        let item = batch.items[position]
        let body = Validator.decode(fix, for: item, language: language(of: item, in: batch))
        guard Validator.defects(body, of: item).isEmpty else { continue }
        corrected[id] = fix
      }
      return corrected
    }

    // MARK: - write-back

    /// The write-back a batch owns: `target`, `machine`, status -> `.translated`,
    /// the version stamp of the documents the request was built against, the
    /// producing model's name, and one journal row — then the checkpoint.
    ///
    /// The write set is decided HERE, per slot, and its only rule is the slot's own
    /// status: `.verified` and `.imported` are not editable, whatever the request
    /// asked for. That is also why the check is here rather than in a scan — a slot
    /// the human confirms while the batch is in flight still survives it (4.6).
    ///
    /// The batch applies as ONE unit: what to write is resolved for every item first,
    /// so a slot that stopped being writable between validation and here cannot leave
    /// half a batch on the rows.
    private func apply(_ results: [String: String], of batch: inout Run.Batch, in run: Run) {
      var writes: [SlotWrite] = []
      var positions: [Int] = []
      for position in results.keys.compactMap(Int.init).sorted() {
        guard batch.items.indices.contains(position),
          let answer = results[String(position)]
        else { continue }
        let item = batch.items[position]
        let language = language(of: item, in: batch)
        guard let row = rowPositions[item.key], project.data.indices.contains(row),
          let slot = project.data[row].targets.firstIndex(where: { $0.language == language }),
          Run.writable(project.data[row].targets[slot].status)
        else { continue }
        let body = Validator.decode(answer, for: item, language: language)
        guard !body.isEmpty else { continue }
        let previous = project.data[row].targets[slot].target
        writes.append(
          SlotWrite(
            key: item.key,
            language: language,
            row: row,
            slot: slot,
            // The text the value was produced FROM, which is what memory is keyed
            // by. Taken from the ITEM rather than re-read off the row: it is what
            // the request was built against, and it is the same body the fold's
            // gold write records.
            source: item.payloadSource.catalogValue,
            target: batch.stage == .prelearn ? nil : body,
            machine: body,
            // Prelearn writes the machine record ONLY: the human owns the value, so
            // its target, its status and its stamp stay exactly as they were (4.1).
            status: batch.stage == .prelearn ? nil : .translated,
            versions: batch.stage == .prelearn ? nil : item.versions,
            previous: previous,
            model: batch.model,
            reason: batch.stage == .prelearn
              ? "Prelearn (\(batch.model)): machine record for a verified slot"
              : "\(batch.stage.title) (\(batch.model)): "
                + (previous.isEmpty ? "filled empty slot" : "differs from previous machine value")))
        positions.append(position)
      }
      for write in writes { persist(write, of: batch, in: run) }
      for position in positions { batch.items[position].phase = .applied }
    }

    /// One slot write, gathered before anything is written so a batch applies as one
    /// unit. `target`/`status`/`versions` are nil for a write that only records what
    /// the machine produced.
    private struct SlotWrite {
      let key: String
      let language: String
      let row: Int
      let slot: Int
      /// The source text the value answers, as the request was shown it. `Memory`
      /// is addressed by (source text, language) within the project (6.2), so the
      /// hint write needs it beside the slot it belongs to.
      let source: String
      let target: StringBody?
      let machine: StringBody?
      let status: LocalizationString.Status?
      let versions: Context.Version?
      let previous: StringBody
      let model: String
      let reason: String
    }

    /// One gathered write: the working copy first, then the app's session, then the
    /// machine hint the value leaves in translation memory.
    ///
    /// The in-memory row goes first because the next batch's register sample is read
    /// off it (4.5). The store is the app's own records — the redesign writes the
    /// same store, additively, and has no second one to keep in step (7.2; whether
    /// the two implementations should share the records is 10.16).
    private func persist(_ write: SlotWrite, of batch: Run.Batch, in run: Run) {
      var slot = run.project.data[write.row].targets[write.slot]
      if let target = write.target { slot.target = target }
      if let machine = write.machine { slot.machine = machine }
      if let status = write.status { slot.status = status }
      if let versions = write.versions { slot.versions = versions }
      run.project.data[write.row].targets[write.slot] = slot
      do {
        for form in forms(of: write) {
          let record = try slotRecord(
            key: write.key, language: write.language, category: form.category)
          let before = record.value
          if let value = form.value {
            record.value = value
            record.state = value.isEmpty ? .empty : .needs_review
          }
          if let machine = form.machine { record.machine = machine }
          record.provider = .deepseek
          record.lastEditor = write.model
          if let versions = write.versions { record.contextVersions = Store.persistable(versions) }
          try store.upsert(record)
          // The journal is the value's before -> after, so a write that only records
          // the machine's output is not an edit of the slot.
          if write.target != nil {
            try store.append(
              TranslationEdit(
                record: record,
                fromValue: before,
                toValue: record.value ?? "",
                editor: .provider,
                reason: write.reason,
                contextVersions: Store.persistable(write.versions ?? .none),
                isUserConfirmed: false))
          }
        }
      } catch {
        fail(run, key: write.key, language: write.language,
             message: error.localizedDescription, retryable: true)
      }
      // What a translate stage produced is kept as a HINT in translation memory
      // (6.1/6.2): provenance for the value, so a later run — and the browser — can
      // show where it came from, with the document versions it was produced
      // against.
      //
      // A hint is PROVENANCE, NEVER A DECISION (6.2): it may be shown and it may
      // seed a repair, but it never overrides a value a human or a machine wrote —
      // the store refuses to let a hint touch gold — and nothing here reads a hint
      // back as an answer to a slot.
      //
      // Only a translate stage's own output is a hint: prelearn writes the machine
      // record of a slot a HUMAN owns (`target` stays nil), which is not a value
      // this run produced, and learn writes gold.
      if let produced = write.target {
        do {
          try Memory(project: project).upsert(
            Memory.Entry(
              key: write.key,
              source: write.source,
              language: write.language,
              // The form the artifact itself shows for a plural (`catalogValue`),
              // exactly as the fold's gold write records it: memory is addressed by
              // (source text, language) and carries no category.
              value: produced.catalogValue,
              grade: .hint,
              versions: write.versions ?? .none))
        } catch {
          fail(run, key: write.key, language: write.language,
               message: error.localizedDescription, retryable: true)
        }
      }
      run.tally.itemsDone += 1
      run.tally.byStage[batch.stage, default: 0] += 1
    }

    /// The records one write touches: one per category for a plural slot (how the
    /// store keeps forms and how the artifact shows them), one with no category for a
    /// flat value. A write that only records the machine's output names its categories
    /// from the machine body, and leaves `value` and `state` alone.
    private func forms(of write: SlotWrite) -> [(category: String?, value: String?, machine: String?)] {
      guard let target = write.target else {
        guard let machine = write.machine else { return [] }
        if case .plural(let plural) = machine {
          return plural.values.map { ($0.rule.rawValue, nil, $0.value.isEmpty ? nil : $0.value) }
        }
        return [(nil, nil, machine.catalogValue)]
      }
      switch target {
      case .value(let text):
        return [(nil, text, write.machine?.catalogValue)]
      case .plural(let plural):
        return plural.values.map { rule in
          (rule.rule.rawValue, rule.value.isEmpty ? nil : rule.value, categoryValue(of: write.machine, rule.rule))
        }
      }
    }

    /// One category of a body, when the body has one: a plural body answers per
    /// category, a flat one answers with its whole text.
    private func categoryValue(of body: StringBody?, _ rule: Plural.Rule) -> String? {
      guard let body else { return nil }
      guard case .plural(let plural) = body else { return body.catalogValue }
      let value = plural.value(for: rule)
      return value.isEmpty ? nil : value
    }

    /// The store's record for one (key, language, category), inserting one the store
    /// does not hold yet.
    ///
    /// The records are fetched ONCE per run, not per write: `Store.records` is a
    /// single fetch for the whole project (measured: 0.7 s for 48 420 rows, against
    /// 4.2 s for the same rows through the faulted relationship), so a per-write
    /// fetch is not an option and a per-batch one is not either.
    private func slotRecord(key: String, language: String, category: String?) throws -> TranslationRecord {
      if slotRecords == nil {
        var index: [SlotKey: TranslationRecord] = [:]
        for record in try store.records(project: project.id) {
          index[SlotKey(key: record.key, language: record.language, category: record.category ?? "")] = record
        }
        slotRecords = index
      }
      let identifier = SlotKey(key: key, language: language, category: category ?? "")
      if let record = slotRecords?[identifier] { return record }
      let record = TranslationRecord(
        key: key,
        sourceText: project.row(key)?.content.catalogValue ?? key,
        language: language,
        provider: .deepseek,
        state: .needs_review,
        contextVersions: ContextVersions(),
        createdAt: .now,
        updatedAt: .now,
        project: try store.projectRow(id: project.id),
        category: category)
      slotRecords?[identifier] = record
      return record
    }

    /// A slot's identity in the store: the model's own triple, which is what makes a
    /// plural slot's forms separate rows.
    private struct SlotKey: Hashable {
      let key: String
      let language: String
      let category: String
    }

    /// The learn write-back: the reply IS the line(s) to append to the language
    /// document, or the single word `NO_CHANGE` (3.5). Canonicalization and the change
    /// gate belong to `Context.append` (3.8) — an identical line writes nothing and
    /// bumps nothing — and the document is compressed after the fold, because a
    /// language-document bump is what marks the rest of the column stale (3.6).
    ///
    /// The gold memory entry comes from the lessons the batch carried, which is the
    /// human's own value (6.2): a fold's reply is prose for ONE document, never a set
    /// of candidates, so nothing here is per-id.
    private func fold(_ reply: String, of batch: Run.Batch, in run: Run) async {
      let answer = reply.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let language = batch.language ?? batch.items.first?.language,
        let document = project.language(language)?.context
      else { return }
      // The reply is the line(s) to append, or NO_CHANGE. A language document's line
      // is `KEY<TAB>SOURCE<TAB>VALUE` — three fields, and each scope validates its own
      // format (3.7) — so a reply that is prose is reported rather than folded: the
      // document is what every later prompt of that column carries, and
      // canonicalization (3.8) cannot turn prose into a lesson.
      if !answer.isEmpty, answer != Self.noChange {
        let lines = answer.split(separator: "\n")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
        let lessons = lines.filter {
          $0.split(separator: "\t", omittingEmptySubsequences: false).count == 3
        }
        if lessons.count < lines.count {
          fail(
            run, language: language,
            message: "the fold answered \(lines.count - lessons.count) line(s) that are not lesson lines",
            retryable: false)
        }
        if !lessons.isEmpty { document.append(value: lessons.joined(separator: "\n")) }
      }
      // The budget keeper runs after the fold, because a language-document bump is
      // what marks the rest of that column stale (3.6).
      do {
        try await document.compressIfNeeded()
      } catch {
        fail(run, language: language, message: error.localizedDescription, retryable: true)
      }
      let memory = Memory(project: project)
      for item in batch.items {
        do {
          try memory.upsert(
            Memory.Entry(
              key: item.key,
              source: item.payloadSource.catalogValue,
              language: language,
              value: item.target.catalogValue,
              grade: .gold,
              versions: item.versions))
        } catch {
          fail(run, key: item.key, language: language,
               message: error.localizedDescription, retryable: true)
        }
      }
      run.tally.itemsDone += batch.items.count
      run.tally.byStage[.learn, default: 0] += batch.items.count
    }

    // MARK: - checkpoint

    /// Persists the cursor and the tally. A batch is resumable at batch
    /// granularity; nothing finer is promised.
    ///
    /// The order matters: the write-back has already saved the batch's values, and the
    /// cursor moves only after them, so an interrupted run never claims a batch it did
    /// not apply.
    private func checkpoint(_ run: Run) async throws {
      try store.saveCursor(Run.Cursor(batchIndex: run.batchIndex), for: run.stage, project: project.id)
      try store.context.save()
    }

    // MARK: - resolution helpers

    /// The language an item is translated into: its own, or the batch's when the batch
    /// names one. The executor copies a batch's language onto its items as well, so an
    /// item always has one and the paid gate can read it off the item.
    private func language(of item: Run.Item, in batch: Run.Batch) -> String {
      item.language ?? batch.language ?? ""
    }

    /// The positions whose slot this run may write, resolved from each slot's OWN
    /// status NOW — the same check the write-back makes, which is why an answer for a
    /// settled slot is never a defect and never a repair (5.3, 4.6).
    private func writablePositions(of batch: Run.Batch) -> IndexSet {
      var positions = IndexSet()
      for (position, item) in batch.items.enumerated() {
        let language = language(of: item, in: batch)
        guard let row = rowPositions[item.key], project.data.indices.contains(row),
          let slot = project.data[row].target(language),
          Run.writable(slot.status)
        else { continue }
        positions.insert(position)
      }
      return positions
    }

    /// The open catalog's rows by key, read once per run and once more after
    /// preparation. Every result is applied by KEY and re-checked against this
    /// snapshot (1.2); rows that appear mid-run are picked up by the next scan, never
    /// patched into a batch already in flight.
    private func indexRows(_ run: Run) {
      rowPositions = Dictionary(
        run.project.data.enumerated().map { ($0.element.key, $0.offset) },
        uniquingKeysWith: { first, _ in first })
    }

    /// The store: the app's SwiftData container, seen from the redesign (7.2).
    private var store: Store { project.global.store }

    // MARK: - failures

    /// Records what went wrong and keeps the run going: a failed batch leaves nothing
    /// half-applied, and the run keeps its other results (5.6).
    private func fail(
      _ run: Run, key: String? = nil, language: String? = nil, message: String, retryable: Bool
    ) {
      run.failures.append(
        Run.Failure(key: key, language: language, message: message, retryable: retryable))
    }

    /// Marks a batch and its items failed, and reports it once.
    private func markFailed(_ batch: Run.Batch, error: Error, in run: Run) {
      if let index = run.batches.firstIndex(where: { $0.id == batch.id }) {
        run.batches[index].phase = .failed
        for item in run.batches[index].items.indices { run.batches[index].items[item].phase = .failed }
      }
      fail(
        run,
        key: batch.items.first?.key,
        language: batch.language,
        message: error.localizedDescription,
        retryable: Self.retryable(error))
    }

    /// Whether retrying a failed request could help. A missing credential and a reply
    /// the app could not decode cannot be retried into working; a refusal can, once
    /// the park it earned has passed.
    private static func retryable(_ error: Error) -> Bool {
      guard let backend = error as? BackendError else { return false }
      switch backend {
      case .notConfigured, .decoding: return false
      case .network, .emptyResult, .rateLimited: return true
      case .badStatus(let code, _): return code >= 500
      }
    }

    /// The run's numbers, read off the client: `send` answers with values, not with
    /// usage, so the client's counters are the only place the tokens exist, and the
    /// cached share is the one number that says whether the prompt layout held (5.7).
    private func readTelemetry(_ run: Run) {
      run.tally.requests = router.requests
      run.tally.promptTokens = router.promptTokens
      run.tally.completionTokens = router.completionTokens
      run.tally.cachedTokens = router.cachedTokens
    }
  }

  /// Deterministic, free, and always run before the paid gate: a dropped
  /// placeholder, an echoed source or an empty reply must never cost a review
  /// call.
  ///
  /// The checks and their tolerances follow `TranslationValidator` — read as the
  /// precedent, never called — one level up: the ids are the items' POSITIONS as
  /// strings (a key never travels, 10.15), and an answer is required only for a slot
  /// the run may WRITE (5.3).
  enum Validator {
    struct Report {
      var accepted: [String: String] = [:]
      /// Ids that answered badly: repaired one at a time, in their own language.
      var rejected: [String] = []
      /// The reply was CUT OFF. A different failure from a rejected id on
      /// purpose: a truncated reply is re-asked in halves, never repaired one id
      /// at a time.
      var truncated: Bool = false
      /// Ids the request never asked for. Reported, never repaired: there is no item
      /// behind them, so there is nothing to re-ask on their behalf.
      var invented: [String] = []
    }

    /// Everything wrong with one answer. Empty means it is acceptable.
    enum Defect: Equatable {
      case empty
      /// Placeholder multiset differs from the source's.
      case placeholders(expected: [String], got: [String])
      /// The answer is the source text unchanged.
      case echo

      var description: String {
        switch self {
        case .empty:
          return "empty response"
        case .placeholders(let expected, let got):
          return "placeholders changed (expected \(expected.joined(separator: " ")), got \(got.joined(separator: " ")))"
        case .echo:
          return "untranslated (identical to source)"
        }
      }
    }

    /// The reply against the request: an answer for every id the run may write, an
    /// answer for no id it never asked for, and no defect in what came back. Anything
    /// answered for a SETTLED slot is neither — it is discarded, because nobody may
    /// write it.
    static func validate(
      _ reply: [String: String], for items: [Run.Item], writable: IndexSet
    ) -> Report {
      var report = Report()
      let asked = Set((0..<items.count).map(String.init))
      report.invented = reply.keys
        .filter { !asked.contains($0) }
        .sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
      for (position, item) in items.enumerated() {
        let id = String(position)
        guard writable.contains(position) else { continue }
        guard let answer = reply[id] else {
          report.rejected.append(id)
          continue
        }
        let body = decode(answer, for: item, language: item.language ?? "")
        guard defects(body, of: item).isEmpty else {
          report.rejected.append(id)
          continue
        }
        report.accepted[id] = answer
      }
      return report
    }

    /// The same check with every item writable. The write-back and the gate still
    /// resolve the real write set per slot; this is what a caller that has no status
    /// to read (a design page, a probe) can ask.
    static func validate(_ reply: [String: String], for items: [Run.Item]) -> Report {
      validate(reply, for: items, writable: IndexSet(integersIn: 0..<items.count))
    }

    /// The reply's per-id answers, as TEXT — an object of plural categories as its own
    /// text (10.15: a reply's `text` mirrors the payload body).
    ///
    /// The runner reads this rather than `Router.send`'s map, because that map casts
    /// `text` to a String and drops a nested object — and with it the whole plural
    /// item. The tolerance is the same tolerance the client has: a markdown fence, a
    /// numeric or string id, `translation` for `text`, and a reply cut off mid-array
    /// keeps the rows it completed, so a plural batch and a flat one travel one path.
    static func answers(in raw: String) -> [String: String] {
      let text = strippingFence(raw)
      guard let start = text.firstIndex(of: "[") else { return [:] }
      var rows: [[String: Any]] = []
      if let end = text.lastIndex(of: "]"), start <= end,
        let data = String(text[start...end]).data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
      {
        rows = parsed
      } else {
        rows = salvage(in: text[start...])
      }
      var answers: [String: String] = [:]
      for row in rows {
        guard let id = idText(row["id"]) else { continue }
        guard let answer = answerText(row["text"]) ?? answerText(row["translation"]) else { continue }
        answers[id] = answer
      }
      return answers
    }

    /// True when the reply holds no complete array at all: the model stopped
    /// mid-answer, or answered something that is not one. Distinguished from a bad id
    /// because the right response differs — re-ask in halves instead of repairing id
    /// by id (5.3).
    static func isTruncated(_ raw: String) -> Bool {
      let text = strippingFence(raw)
      guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"),
        start <= end,
        let data = String(text[start...end]).data(using: .utf8),
        (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) != nil
      else { return true }
      return false
    }

    /// The paid gate's rows: `{id, valid, fix}` per candidate (5.4).
    struct Review {
      let valid: Bool
      let fix: String?
    }

    static func reviews(in raw: String) -> [String: Review] {
      let text = strippingFence(raw)
      guard let start = text.firstIndex(of: "[") else { return [:] }
      var rows: [[String: Any]] = []
      if let end = text.lastIndex(of: "]"), start <= end,
        let data = String(text[start...end]).data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
      {
        rows = parsed
      } else {
        rows = salvage(in: text[start...])
      }
      var reviews: [String: Review] = [:]
      for row in rows {
        guard let id = idText(row["id"]) else { continue }
        let valid = (row["valid"] as? Bool) ?? ((row["valid"] as? NSNumber)?.boolValue ?? false)
        reviews[id] = Review(valid: valid, fix: answerText(row["fix"]))
      }
      return reviews
    }

    /// What is wrong with one item's answer, deterministically and for free: nothing
    /// to judge in an empty answer, a placeholder multiset that did not survive, an
    /// answer left in the source language (5.3).
    ///
    /// The source side is what the model was SHOWN (`payloadSource`), not the authored
    /// field: a row with nothing authored sent its key, and an answer that echoes the
    /// key is an echo.
    static func defects(_ answer: StringBody, of item: Run.Item) -> [Defect] {
      guard !answer.isEmpty else { return [.empty] }
      var defects: [Defect] = []
      let expected = placeholders(in: item.payloadSource).sorted()
      let got = placeholders(in: answer).sorted()
      if expected != got {
        defects.append(.placeholders(expected: expected, got: got))
      }
      if echoes(answer, item.payloadSource) {
        defects.append(.echo)
      }
      return defects
    }

    /// The same defects as a sentence, for a failure report.
    static func describe(_ answer: String?, of item: Run.Item, language: String) -> String {
      guard let answer else { return "empty response" }
      let defects = defects(decode(answer, for: item, language: language), of: item)
      return defects.isEmpty ? "rejected" : defects.map(\.description).joined(separator: "; ")
    }

    // MARK: - bodies

    /// The body a reply's text mirrors.
    ///
    /// A flat item answers a string; a plural item answers an object of category ->
    /// text, and is decoded over the TARGET LANGUAGE's own categories — the rules
    /// normalize a region-tagged code (9.5) — so the slot's three bodies stay parallel:
    /// every rule the language has, the ones the reply did not name left empty. A flat
    /// answer to a plural item fills the form the artifact reads (`other` when the
    /// language has it), because turning the slot flat would break that parallel.
    static func decode(_ answer: String, for item: Run.Item, language: String) -> StringBody {
      let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard expectsPlural(item) else { return .value(text) }
      var plural = Plurals(language: language)
      if let object = object(from: text) {
        for index in plural.values.indices {
          if let value = object[plural.values[index].rule.rawValue] {
            plural.values[index].value = value
          }
        }
        return .plural(plural)
      }
      let rule = plural.values.contains { $0.rule == .other } ? Plural.Rule.other : (plural.values.first?.rule ?? .other)
      plural.set(text, for: rule)
      return .plural(plural)
    }

    /// A plural slot is a plural on the wire: the item either carries plural bodies
    /// already, or sent the target language's EMPTY SKELETON because the source is a
    /// plural and nothing has been filled yet (4.3).
    private static func expectsPlural(_ item: Run.Item) -> Bool {
      if case .plural = item.target { return true }
      if case .plural = item.source { return true }
      return false
    }

    /// The placeholder tokens of a body: the tokens of every text it carries, in
    /// order. A plural body's forms are all compared, because a form that dropped a
    /// placeholder is a defect of the same kind.
    static func placeholders(in body: StringBody) -> [String] {
      switch body {
      case .value(let text):
        return placeholders(in: text)
      case .plural(let plural):
        return plural.values.flatMap { placeholders(in: $0.value) }
      }
    }

    /// Placeholder / format-specifier tokens, in order of appearance: printf-style
    /// specifiers (`%@`, `%lld`, `%1$@`, `%.2f`) and brace-style tokens (`{name}`,
    /// `{{name}}`). A bare percent such as "50% off" is not a match because a letter
    /// or `@` must follow. The two patterns are `TranslationValidator`'s own.
    ///
    /// `StringBody.placeholders` in `Design.swift` is the container's accessor and is
    /// still a stub; the validator tokenizes here, once, and both sides of every
    /// comparison go through this function.
    static func placeholders(in text: String) -> [String] {
      matches(#"%(\d+\$)?[@a-zA-Z][a-zA-Z0-9]*"#, in: text)
        + matches(#"\{\{?[A-Za-z_][A-Za-z0-9_]*\}?\}"#, in: text)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
      let range = NSRange(text.startIndex..., in: text)
      return regex.matches(in: text, range: range).compactMap {
        Range($0.range, in: text).map { String(text[$0]) }
      }
    }

    /// An answer left in the source language. Only meaningful for a string long enough
    /// that an unchanged copy is not a legitimate loanword or acronym (the reference's
    /// own guard), and a plural answer has to echo EVERY form it fills to count.
    private static func echoes(_ answer: StringBody, _ source: StringBody) -> Bool {
      let sourceText = source.catalogValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard sourceText.count > 4 else { return false }
      switch answer {
      case .value(let text):
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
          .caseInsensitiveCompare(sourceText) == .orderedSame
      case .plural(let plural):
        let filled = plural.values.filter { !$0.value.isEmpty }
        guard !filled.isEmpty else { return false }
        // A plural slot compares per CATEGORY against its own plural source; against
        // a flat source (a plural slot whose source unit is flat) every form would
        // have to be a copy of that text.
        guard case .plural(let reference) = source else {
          return filled.allSatisfy {
            $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
              .caseInsensitiveCompare(sourceText) == .orderedSame
          }
        }
        return filled.allSatisfy { form in
          let expected = reference.value(for: form.rule).trimmingCharacters(in: .whitespacesAndNewlines)
          guard !expected.isEmpty else { return false }
          return form.value.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(expected) == .orderedSame
        }
      }
    }

    /// A reply's text as the shape the wire uses: a string as it is, an object of
    /// plural categories as its own JSON (which `decode` reads back). An empty answer
    /// is not an answer, so it is dropped here and the id is rejected for it.
    private static func answerText(_ any: Any?) -> String? {
      if let text = any as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      }
      if let object = any as? [String: Any],
        let data = try? JSONSerialization.data(
          withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
      {
        let text = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
      }
      return nil
    }

    /// A reply's JSON object of category -> text, when it is one.
    private static func object(from text: String) -> [String: String]? {
      guard text.hasPrefix("{"), let data = text.data(using: .utf8) else { return nil }
      return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }

    /// The id a row names, as a string: the model may echo a position as a number or
    /// as a string, and both mean the same row.
    private static func idText(_ any: Any?) -> String? {
      if let text = any as? String { return text }
      if let number = any as? NSNumber { return number.stringValue }
      return nil
    }

    /// Drops a markdown fence around a reply, when the model wrapped it in one.
    private static func strippingFence(_ raw: String) -> String {
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard text.hasPrefix("```") else { return text }
      return text.replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes as many COMPLETE `{…}` rows as the text holds, in order — the salvage
    /// path for a cut-off reply. String state is tracked so a brace inside a
    /// translation cannot end a row early, and the scan stops at the unbalanced object
    /// where the cut happened. (`Router.completeRows` is the same walk in the client.)
    private static func salvage(in text: Substring) -> [[String: Any]] {
      var rows: [[String: Any]] = []
      var depth = 0
      var objectStart: String.Index?
      var inString = false
      var escaped = false

      for index in text.indices {
        let character = text[index]
        if inString {
          if escaped {
            escaped = false
          } else if character == "\\" {
            escaped = true
          } else if character == "\"" {
            inString = false
          }
          continue
        }
        switch character {
        case "\"":
          inString = true
        case "{":
          if depth == 0 { objectStart = index }
          depth += 1
        case "}":
          depth -= 1
          guard depth <= 0, let start = objectStart else { continue }
          if let data = text[start...index].data(using: .utf8),
            let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
          {
            rows.append(row)
          }
          depth = 0
          objectStart = nil
        default:
          continue
        }
      }
      return rows
    }
  }
}
