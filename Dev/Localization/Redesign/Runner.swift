//
//  Runner.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  The run executor: the state of one run, the batches it is made of, and the one
//  thing that knows HOW a batch happens — admission, prompt assembly, the model,
//  deterministic validation, the paid gate, write-back, checkpoint,
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

/// A request COMPARES by the two bodies and the prefix it carries, so a probe can ask whether
/// what a page shows is the very request the runner built rather than comparing strings by hand.
/// Declared at file scope, beside the exchange that hands a request to a page, because equality
/// is the PANE's need — `Prompt` is assembled as the wire contract and needs none.
extension Translation.Prompt.Request: Equatable {
  static func == (left: Self, right: Self) -> Bool {
    left.system == right.system
      && left.user == right.user
      && left.ids == right.ids
      && left.cacheablePrefix == right.cacheablePrefix
  }
}

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
      /// What this batch carries, which is what the run pays for (5.7). Memory can
      /// answer an item before the request is built, so it is recomputed then: the
      /// report counts what was sent, never what a slot would have cost.
      var characters: Int
      /// The model that answered — the write-back stamps the slot with it (5.5).
      var model: String = ""
      var phase: Phase = .pending
      /// Which ATTEMPT this batch is on: 1 while its first request is out, 2 to
      /// `Limits.retries + 1` after a retryable failure sent it back for another answer
      /// (5.9). Kept on the batch, on the run's own copy, because that is what a progress
      /// line reads WHILE a re-ask is in flight — a retry nobody can see reads as a hang.
      ///
      /// A re-ask BY HAND counts here too (5.11): it is another attempt at the same unit of
      /// work, which is also what keeps its characters from being charged a second time
      /// (5.7 — the cost of a unit is counted once, while every SEND is counted).
      var attempt: Int = 1
      /// The model's RAW reply for THIS batch, exactly as the provider sent it: what the
      /// right half of a stage page prints, unread (8.1, "stage pages").
      ///
      /// Per BATCH, not per run, because a page shows one batch and `Router.lastRawReply`
      /// keeps only the LAST call's text — a page would show the wrong request's answer for
      /// every batch but the newest. It is set the moment the call returns and KEPT after
      /// it, including on a batch that then failed validation or was cut off: a reply that
      /// failed is exactly the one a human wants to read. Nothing here parses it, and
      /// nothing decides anything with it: it is printed as it came.
      var rawReply: String?

      /// The request THIS batch sent, exactly as it went out: the two message BODIES
      /// (`system` + `user`) and the cacheable prefix the telemetry counts (5.7, 8.1,
      /// "stage pages"). Kept per BATCH for the same reason the reply is — a page shows one
      /// batch — and kept the moment the request is BUILT, so a batch whose call then failed
      /// still shows what was asked of the model: an input that vanished on a failure would
      /// leave the pane explaining a failure nobody can inspect.
      ///
      /// The two bodies are the truth and are stored VERBATIM; the ids and the payload are
      /// reconstructible from the items and are not copied. Nothing parses this, nothing
      /// decides anything with it, and it is never persisted: a request is up to
      /// `Limits.batch` characters of payload plus its context, so it lives with the run and
      /// dies with it (a stage page is the only thing that reads it).
      var request: Prompt.Request?

      /// What a stage page's right half reads: the reply, and the phase that says WHY
      /// there is none yet (still in flight, no request spent, or the call failed).
      var reply: Reply { Reply(raw: rawReply, phase: phase) }

      /// BOTH SIDES of this batch's exchange, as ONE value: what was sent and what came
      /// back. Both halves are read off THIS batch, so a page holding batch N's exchange can
      /// never show batch M's input beside its reply — there are no two arrays to keep
      /// aligned (8.1).
      var exchange: Exchange { Exchange(request: request, reply: reply) }
    }

    /// One batch as a stage page's right half sees it: the model's raw reply and the
    /// batch's own phase, so the page can say "still in flight" instead of showing an
    /// empty box, and "the model answered nothing" instead of showing whitespace (8.1,
    /// "stage pages").
    struct Reply: Equatable {
      /// The reply as it came back; nil when nothing has answered this batch.
      let raw: String?
      /// Where the batch is in its life — the only thing that tells a batch nobody has
      /// sent yet from one no model will ever answer (`Run.resolveMemory`).
      let phase: Phase
    }

    /// One batch's whole EXCHANGE, as the four stage pages take it: what was SENT and what
    /// came back, in one value (8.1, "stage pages" — the reader asked for the other side of
    /// the same pane: "Add model input to that model reply view").
    ///
    /// One shape for all four pages, and one value PER BATCH: the pages page by batch, so
    /// the input and the reply travel together and cannot drift apart. A page that has no
    /// batch behind it reads `unsent` rather than a pair of nils.
    struct Exchange: Equatable {
      /// The request the batch built and sent; nil while nothing has been sent — or when
      /// nothing ever will be, because translation memory answered every item of it
      /// (`Run.resolveMemory`).
      let request: Prompt.Request?
      /// The reply, and the phase that explains an absent one.
      let reply: Reply

      /// The exchange of a page with no batch behind it: nothing sent, nothing answered.
      static let unsent = Exchange(request: nil, reply: Reply(raw: nil, phase: .pending))
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
      /// The value the slot holds, which is what a request shows as the current one
      /// (4.3). Written when memory answers the slot before the request is built, so the
      /// row's own payload carries the value the run just resolved instead of the stale
      /// machine text it replaced.
      var target: StringBody
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
      /// Every send that went OUT, the attempts that FAILED included: a retry is a send, and
      /// attempts are what a retry costs (5.7, 5.9). `requests` is the client's own count of
      /// calls that came BACK, so the two numbers differ by exactly the attempts that failed
      /// — which is the whole point of keeping both, because a batch that was answered on its
      /// fourth attempt has to read as four sends and one answer.
      var sends = 0
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
      /// Writes a step did with NO request at all: the slots translation memory answered
      /// (6.2, `Run.resolveMemory`). Kept apart from `itemsDone`/`byStage` on purpose —
      /// those two count the items a step CUT, and a slot memory answers never becomes
      /// one, so counting it there would make the rail read "5 done of 1 cut" (5.7).
      /// No readout shows this number yet; the saving is already visible in
      /// `characters` and `requests`, and this is what says how much of it memory did.
      var resolved: [Stage: Int] = [:]
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

    /// The batch this run is on WHILE IT IS BEING RE-ASKED (5.9), i.e. the batch whose
    /// attempt failed retryably and whose next request is on its way. Nil the rest of the
    /// time: a batch that is on its first attempt, and one that has landed — applied or
    /// failed — is not a batch anybody is retrying.
    ///
    /// Attempts are COST (5.7) and they are the one part of a retry the user pays for, so
    /// the progress line reads this and says which attempt is in flight rather than letting
    /// a slow batch read as a stuck one.
    var reasking: Batch? {
      guard batches.indices.contains(batchIndex) else { return nil }
      let batch = batches[batchIndex]
      guard batch.attempt > 1, batch.phase != .applied, batch.phase != .failed else { return nil }
      return batch
    }

    var isFinished: Bool { state == .finished || state == .cancelled }

    /// True while 5.11's re-ask is in flight: the batches a finished run gave up on are being
    /// asked again. The run it belongs to reads as RUNNING while this holds — a batch being
    /// re-asked must read as running again rather than as still finished — and it is what tells
    /// a re-ask from the run's own execution.
    var isRetrying = false

    /// The batches 5.11's button re-asks: the TRANSLATE jobs' batches that failed — the column
    /// pass and the row pass — in the order the run cut them.
    ///
    /// Prelearn and learn are not translations (they write a machine record and a document
    /// line), so a failure of theirs is not something a re-ask is offered for: it stays in the
    /// run's own report, where it belongs.
    ///
    /// These are the run's OWN batch objects, with their items, their positions and their
    /// languages — the reason a re-ask needs no scan: the list is already cut and the requests
    /// go out exactly as they did the first time (4.3, 5.11).
    var failedBatches: [Batch] {
      batches.filter {
        $0.phase == .failed && ($0.stage == .vertical || $0.stage == .horizontal)
      }
    }

    /// Whether the overlay offers 5.11's retry: a FINISHED run that still carries a failed
    /// TRANSLATE batch. A run with no failures offers nothing, a run that was cancelled is over
    /// rather than finished, and a re-ask already in flight does not offer itself again.
    var canRetryFailedBatches: Bool {
      state == .finished && !isRetrying && !failedBatches.isEmpty
    }

    /// The rule of the write set for a write of the VALUE, and its ONLY rule: a slot the
    /// run may write is one whose OWN status allows it. `.verified` and `.imported` are
    /// never overwritten — a value this project has already committed to is context, not a
    /// target (4.6) — and an ignored key is out of scope for every stage.
    ///
    /// Both the validator and the write-back ask this, and they ask it of the SLOT,
    /// at the moment they ask: a slot the human confirms while a batch is in flight
    /// is settled by the time the reply lands, and the reply is discarded rather than
    /// spending a call on a value nobody may write (5.3, 5.5).
    static func writable(_ status: LocalizationString.Status) -> Bool {
      switch status {
      case .needsTranslate, .stale, .translated: true
      case .verified, .imported, .ignore: false
      }
    }

    /// Which rule this run's write-back asks of a slot, for the shape the batch is.
    ///
    /// A translate batch writes a VALUE and asks the slot's status. A prelearn batch writes
    /// the machine RECORD and no value at all (4.1), and the value rule refuses exactly the
    /// slots that operation exists for: its slots are `.verified` by construction. Measured
    /// before this pair existed — a prelearn batch spent its request, wrote nothing, and
    /// reported no failure, because the write set was empty and nobody asked for an answer.
    ///
    /// One place answers for both, so the scan's own preview, the validator's "ids that must
    /// be answered" and the write-back cannot drift apart (5.3, 5.5).
    static func writable(_ slot: LocalizationString, for stage: Stage) -> Bool {
      stage == .prelearn ? machineWritable(slot) : writable(slot.status)
    }

    /// The write set of a machine-record write: the slot is one a HUMAN settled whose
    /// machine record is still missing — the two halves of the prelearn predicate (2.4),
    /// asked here so the scan and the write-back cannot disagree.
    ///
    /// It protects something narrower than the value rule does, and deliberately: the field
    /// it fills, `machine`, is one no human owns (a human edit never touches it), so a
    /// `.verified` slot is not a reason to refuse the write. What it does refuse is a slot
    /// that already HAS a machine record: the operation only ever asks for one while it is
    /// empty, so filling it again would spend the request on a record nobody asked for.
    static func machineWritable(_ slot: LocalizationString) -> Bool {
      slot.status == .verified && slot.machine.isEmpty
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
    /// Who a value memory answered with is attributed to, in the record the app's own
    /// browser reads. The old pipeline's memory resolve wrote exactly this word, and a
    /// model that was never asked must not be named as the writer (10.16).
    private static let memoryEditor = "Translation Memory"

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
    ///
    /// A re-ask in flight is not a run being paused (5.11): the run it belongs to has already
    /// finished, so there is no cursor to resume from and nothing to pause — the re-ask runs on,
    /// and `stopRetry` is what ends it.
    func pause(_ run: Run) {
      guard run.state == .running || run.state == .scanning else { return }
      guard !run.isRetrying else { return }
      run.state = .paused
      task?.cancel()
    }

    /// Cancels the batch in flight and keeps everything already applied. The run is
    /// over: pressing Start again builds a fresh one, and its scan finds only what is
    /// still work.
    ///
    /// While a re-ask is what is in flight there is no run left to cancel — it finished long
    /// ago — so this STOPS the asking instead (`stopRetry`).
    func cancel(_ run: Run) {
      guard run.state != .finished, run.state != .cancelled else { return }
      guard !run.isRetrying else { return stopRetry(run) }
      run.state = .cancelled
      task?.cancel()
    }

    /// Stops an in-flight re-ask (5.11). What ends is the ASKING: a re-ask runs on a run that has
    /// already finished — there is no cursor to resume from and no run to cancel — so the batches
    /// it did not reach stay failed and reported, and the button offers exactly those again.
    ///
    /// Its own ending is the only thing the workspace saves on (5.10), and a stopped one is not
    /// that ending: what it did land stays app-side until an explicit Save, the way a cancelled
    /// run's results do.
    func stopRetry(_ run: Run) {
      guard run.isRetrying else { return }
      task?.cancel()
    }

    /// What a re-ask did: how many batches it re-sent, and whether it ran to the end.
    ///
    /// The workspace needs both halves. The COUNT is what makes an empty button a no-op, and
    /// `completed` is what it saves on: a re-ask that ran on a run that had finished is that
    /// run's own ending (5.10), while one the user stopped never was.
    struct Retry {
      let batches: Int
      let completed: Bool
    }

    /// Re-asks the batches a FINISHED run gave up on — 5.11's button, and the only way a failed
    /// batch is asked again without starting over.
    ///
    /// Exactly the failed TRANSLATE batches go out, AS THEY STAND. NO scan, no re-cut and no
    /// regeneration of the list: the run already holds those batch objects with their items,
    /// their positions and their languages, so every id is still the position it always was
    /// (4.3) and the request is built exactly as it was built the first time. Rebuilding a
    /// stage's operations from the project is what pressing Start does; this deliberately does
    /// not, because the reader's point was that a finished run should not need a second Start.
    ///
    /// The run it belongs to was finished before this began and is finished again when it is
    /// over; what this answers beyond the count is whether the re-ask RAN TO THE END.
    @discardableResult
    func retryFailedBatches(_ run: Run) async -> Retry {
      let failed = run.canRetryFailedBatches ? run.failedBatches : []
      guard !failed.isEmpty else { return Retry(batches: 0, completed: false) }
      // The flag goes up HERE rather than inside the task: `canRetryFailedBatches` is what the
      // button reads and what the next call's guard asks, so a re-ask is under way the moment it is
      // asked for — not a moment later, when two presses could both start one.
      run.isRetrying = true
      let task = Task { await self.retry(failed, of: run) }
      self.task = task
      await task.value
      if self.task == task { self.task = nil }
      return Retry(batches: failed.count, completed: !task.isCancelled)
    }

    /// The re-ask itself, one failed batch at a time: each goes out ONCE, carrying the items the
    /// run still holds, and nothing walks the operations, the cursor or the project's rows.
    ///
    /// ONCE, and not through 5.9's loop: the automatic retries belong to a batch's own execution
    /// and were already spent on it, so this is a NEW attempt AFTER them, never instead of them
    /// (5.11). A batch that fails again leaves the run's copy failed and reported, and the button
    /// re-offers it — the re-ask promises nothing.
    ///
    /// The batches are addressed by ID and re-read off the run before each send, because a send
    /// suspends: what is replaced is the run's own copy, never the snapshot this loop walks.
    ///
    /// The flag the button reads (`Run.isRetrying`) is put up by the caller and cleared here, so it
    /// is never left standing by an ending this loop does not reach.
    private func retry(_ batches: [Run.Batch], of run: Run) async {
      // The cursor the run's own walk left behind — the end of the list — so the re-ask can report
      // the batch it is on without moving where the run stopped (5.6).
      let cursor = run.batchIndex
      run.finishedAt = nil
      run.state = .running
      for batch in batches {
        if Task.isCancelled { break }
        guard let index = run.batches.firstIndex(where: { $0.id == batch.id }) else { continue }
        // The batch being re-asked is what the run REPORTS it is on: `Run.reasking` reads the
        // cursor, and the cursor of a finished run is past the end of the list — so the re-ask
        // moves it onto the batch it is asking, which is what the progress line and the overlay's
        // page read while the request is out. The run's own cursor is put back below.
        let standing = run.batches[index]
        run.batchIndex = index
        // The batch reads as RUNNING again while it is re-asked (5.11): a page reads the batch's
        // phase and its items', so both go back — the failure stamped the whole batch, while an
        // item that LANDED (memory answered it) keeps the phase that says so and is not re-asked.
        for position in run.batches[index].items.indices
        where run.batches[index].items[position].phase == .failed {
          run.batches[index].items[position].phase = .pending
        }
        run.batches[index].phase = .sent
        // Another attempt at the SAME unit of work (5.7): the characters are not paid for twice,
        // the SEND is — counted where the send happens, `Tally.sends` (5.9).
        run.batches[index].attempt += 1
        do {
          run.batches[index] = try await performOne(run.batches[index], in: run)
        } catch is CancellationError {
          // Stopped mid-request. An attempt that never answered leaves the batch as it was —
          // failed and reported — so the button offers it again, which is the whole of what 5.11
          // promises a stopped re-ask.
          run.batches[index] = standing
          break
        } catch {
          markFailed(batch, error: error, in: run)
        }
      }
      run.isRetrying = false
      run.batchIndex = cursor
      // The run ends where it began: FINISHED. Stopping a re-ask stops the asking; it does not
      // un-finish the run it belongs to, and it is not a cancel (5.10).
      run.state = .finished
      run.finishedAt = .now
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
    /// its predicate, its per-language grouping and its character splitting (4.4) — so
    /// this only turns what it built into the runner's own batches; and THEN it applies
    /// translation memory to them (6.2, `resolveMemory`), because a slot memory already
    /// answers must never reach a request.
    ///
    /// The resolve runs at SCAN time rather than per batch on purpose: this is where
    /// the run's batch list becomes FINAL — the cursor numbers these batches, a resumed
    /// run keeps them instead of re-cutting them, and the stage files stay memory-free
    /// (their own cards ask for that).
    private func scan(_ operation: Stage, into run: Run) throws {
      var batches: [Run.Batch]
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
      // One lookup per (source, language) pair per scan: the resolve is a store fetch,
      // and a project's rows share their sources. Rebuilt for every operation, so a
      // lesson the fold wrote earlier in the same run is read by the next scan.
      var cards: [MemoryKey: Remembered] = [:]
      for index in batches.indices {
        resolveMemory(&batches[index], in: run, cards: &cards)
      }
      // A batch memory emptied has nothing to ask and is not a batch: dropping it here
      // keeps the run's list, the cursor's ordinals and the tally to what is sent.
      batches.removeAll { $0.items.isEmpty }
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

    // MARK: - translation memory, read before the request

    /// The pair memory is addressed by: the source text a request would send — 4.3's
    /// fallback included, so the read looks up exactly what a hint write recorded — and
    /// the target language.
    private struct MemoryKey: Hashable {
      let source: String
      let language: String
    }

    /// What one lookup answered. Kept per scan, because the resolve is a store fetch
    /// and a project's rows share their sources.
    private enum Remembered {
      /// No entry for the pair, or an entry that carries no value.
      case nothing
      case hit(Memory.Entry)
    }

    /// The two memory rules of 6.2/10.19, applied to one batch BEFORE it is sent:
    ///
    ///   GOLD — a human confirmed this exact (source, language) pair, so it answers the
    ///   slot with NO model call at all (6.2, which is what keeps a column's
    ///   1 000-character document sufficient: per-key knowledge lives here). It
    ///   REPLACES machine text — a `.stale` or `.translated` slot — and it is the only
    ///   thing that may: a value a human settled (`.verified`) or the database shipped
    ///   (`.imported`) is never overwritten (10.19a). The slot it answers reads
    ///   `reviewed` afterwards (10.19b), which freezes it for the rest of the run.
    ///
    ///   HINT — machine output kept for reference. It is PROVENANCE, NOT A DECISION
    ///   (6.2): it is never applied over anything a human or a machine wrote, and what
    ///   it may do is fill a slot that holds NOTHING (10.19c), as machine output
    ///   (`.translated`, the old pipeline's needs_review role).
    ///
    /// The write goes through the same `SlotWrite`/`persist` path every other write
    /// uses, so memory is never a second writer of a slot: it decides a value and the
    /// store's own state exactly as a model's answer does. What happens to the ITEM:
    ///
    ///   - a per-language (vertical) batch DROPS it. The request must not carry a slot
    ///     nothing may spend a call on, and the batch keeps the items that still need
    ///     one — a batch they empty entirely is sent nowhere.
    ///   - a row (horizontal) batch KEEPS it, with the resolved value in its payload:
    ///     4.6's payload carries every language of the row, and 10.19b removes a
    ///     resolved slot from the write set, not from the row's VIEW. Its answer is
    ///     then discarded like any answer for a settled slot.
    ///
    /// Only a translate stage resolves. prelearn writes the machine record of a slot a
    /// HUMAN owns (and the value rule below refuses those slots anyway), and the fold's
    /// reply is document text rather than candidates — its gold write is already in
    /// memory by the time a column translates.
    private func resolveMemory(
      _ batch: inout Run.Batch, in run: Run, cards: inout [MemoryKey: Remembered]
    ) {
      guard batch.stage == .vertical || batch.stage == .horizontal else { return }
      var positions: [Int] = []
      var writes: [SlotWrite] = []
      for position in batch.items.indices {
        let item = batch.items[position]
        let language = language(of: item, in: batch)
        // The slot this item answers, as the open catalog holds it NOW.
        guard let row = rowPositions[item.key], project.data.indices.contains(row),
          let slot = project.data[row].targets.firstIndex(where: { $0.language == language })
        else { continue }
        let current = project.data[row].targets[slot]
        // The value rule, asked of the slot's own status: a settled value is context,
        // not a target (4.6), and 10.19a names the one value memory never replaces —
        // another human's.
        guard Run.writable(current.status) else { continue }
        let source = item.payloadSource.catalogValue
        guard !source.isEmpty else { continue }
        let key = MemoryKey(source: source, language: language)
        if cards.index(forKey: key) == nil {
          cards[key] = answer(for: key, of: item.key, in: run)
        }
        guard case .hit(let entry)? = cards[key] else { continue }
        // Gold replaces machine text; a hint only fills EMPTYNESS (10.19a/10.19c).
        guard entry.grade == .gold || current.target.isEmpty else { continue }
        // The entry's value is memory's TEXT — one body per pair, with no categories —
        // so it is decoded exactly like a model's flat answer: a plural slot keeps its
        // parallel and the form the artifact reads is the one filled.
        let body = Validator.decode(entry.value, for: item, language: language)
        guard !body.isEmpty else { continue }
        writes.append(
          SlotWrite(
            key: item.key,
            language: language,
            row: row,
            slot: slot,
            source: source,
            target: body,
            // The machine record is what OUR model produced for this slot before, and
            // memory answers with a VALUE: neither the value nor the status of a
            // machine record is decided here.
            machine: nil,
            // 10.19b: a gold hit reads `reviewed`, so it is frozen for writing — and it
            // still travels in a row batch, as context. A hint keeps the machine's
            // status: unreviewed output, which the row pass may still adapt.
            status: entry.grade == .gold ? .verified : .translated,
            // The documents the value was produced against, which is the entry's own
            // stamp and not this run's: a gold entry written against an older project
            // document is still a human's value, and its provenance has to say so.
            versions: entry.versions,
            previous: current.target,
            // No model was asked for this value.
            model: "",
            reason: entry.grade == .gold
              ? "Resolved from reviewed translation memory (gold)"
              : "Resolved from machine translation memory (hint)",
            memory: entry.grade))
        positions.append(position)
      }
      guard !writes.isEmpty else { return }
      for write in writes { persist(write, of: batch, in: run) }
      // The item leaves a per-language request; in a row batch it stays, carrying what
      // it was answered with. Either way its write is already applied.
      if batch.stage == .vertical {
        for position in positions.reversed() { batch.items.remove(at: position) }
      } else {
        for (position, write) in zip(positions, writes) {
          if let target = write.target { batch.items[position].target = target }
          batch.items[position].phase = .applied
        }
      }
      // What a batch carries is what it costs, and memory just changed that.
      batch.characters = batch.items.reduce(0) { $0 + $1.characters }
    }

    /// One lookup, reported rather than thrown. A memory read that fails must not cost
    /// the run a value: the item stays unresolved and the model answers it, exactly as
    /// if the pair had no entry — and the failure is on the run.
    private func answer(for key: MemoryKey, of slot: String, in run: Run) -> Remembered {
      do {
        guard
          let entry = try Memory(project: project).resolve(
            source: key.source, language: key.language)
        else { return .nothing }
        // Memory never carries a valueless entry (`Memory.resolve` guards the row's own
        // state); one that somehow does answers nothing.
        return entry.value.isEmpty ? .nothing : .hit(entry)
      } catch {
        fail(
          run, key: slot, language: key.language, message: error.localizedDescription,
          retryable: true)
        return .nothing
      }
    }

    // MARK: - one batch

    /// One batch, start to applied: admission -> prompt -> send -> deterministic
    /// validation -> the paid gate -> write-back -> checkpoint ->
    /// telemetry (5.1). The checkpoint is the caller's, so the cursor never claims a
    /// batch whose write-back failed.
    ///
    /// A model response that FAILS retryably is RE-ASKED here, before the batch is given up
    /// on (5.9): the same request again, up to `Limits.retries` times after the first attempt,
    /// so one batch costs at most `Limits.retries + 1` sends. It is the batch's OWN request
    /// because the ids are batch positions — a second answer is another attempt at the same
    /// unit of work, never a second unit — and it goes through admission and the cooldown
    /// again, so a parked or rate-limited Muse WAITS instead of the re-ask burning nothing
    /// and failing for the same reason (5.2).
    ///
    /// A NON-retryable failure is thrown by its FIRST send: the flags the failure sites
    /// already compute decide, and a batch that has used its retries is thrown too, so it
    /// fails exactly as it did before this loop existed. Nothing is applied on the way —
    /// `performOne` works on a value and applies as one unit — so a re-asked batch starts
    /// from the batch the run still holds, and a batch that runs out of attempts leaves
    /// nothing half-applied (5.5).
    private func perform(_ batch: Run.Batch, in run: Run) async throws {
      guard let index = run.batches.firstIndex(where: { $0.id == batch.id }) else { return }
      var attempt = 1
      while true {
        do {
          run.batches[index] = try await performOne(run.batches[index], in: run)
          return
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          guard Self.retryable(error), attempt <= Limits.retries else { throw error }
          // The attempt is over and the batch is NOT failed: it is being re-asked. The
          // failure is recorded anyway, because the list is where the history lives — one
          // entry per attempt, so a retry does not erase what it took to get there.
          fail(run, error, on: batch)
          attempt += 1
          // Which attempt the batch is on, on the RUN's copy, so a progress line can read it
          // while the re-ask is in flight (5.9, `Run.reasking`).
          run.batches[index].attempt = attempt
        }
      }
    }

    /// One request's whole life, from the prompt to the row. A re-ask of a cut reply
    /// is this same pipeline on a subset of items, which is why it takes the batch by
    /// value and answers with the batch it produced.
    private func performOne(_ origin: Run.Batch, in run: Run) async throws -> Run.Batch {
      var batch = origin
      // A batch memory emptied has nothing to ask: no request, no admission, and no
      // failure — the scan already wrote what it answered (5.1).
      guard !batch.items.isEmpty else {
        batch.phase = .applied
        return batch
      }
      // The stamp a slot written now would carry is what the request is built
      // against, so it is read here — once, just before the prompt is assembled.
      for index in batch.items.indices {
        batch.items[index].versions = project.currentVersion(
          for: language(of: batch.items[index], in: batch))
      }
      // Only an item still to be SENT is marked sent: one the scan answered from memory
      // is applied, and re-labelling it would report a call that was never made.
      for index in batch.items.indices where batch.items[index].phase == .pending {
        batch.items[index].phase = .sent
      }
      batch.phase = .sent
      // Counted ONCE per unit of work, however many attempts it takes: a re-ask carries the
      // same items, so it is the same characters and not more work (5.7). What a retry
      // multiplies is the SEND, and that is counted where the send happens (`Tally.sends`).
      if batch.attempt == 1 { run.tally.characters += batch.characters }

      // The request is BUILT here and kept on the run's own copy before the send: it is what
      // this batch asked, and a call that then fails — admission, the cooldown, the network —
      // must still show the reader the input it failed on (8.1). Nothing about sending
      // changes: the same value goes to `send`.
      let request = request(for: batch, in: run)
      batch.request = request
      retain(request, of: batch, in: run)

      let answer = try await send(request, in: run)
      batch.model = answer.model
      // The reply belongs to the BATCH, and it is kept the moment it arrives rather than
      // when the batch returns: everything after this point — validation, the paid gate,
      // a cut reply's re-ask — can throw, and a batch whose reply failed
      // validation is the one a human most wants to read (8.1). `Router.lastRawReply`
      // keeps only the last call's text, which by then is another batch's.
      batch.rawReply = answer.raw
      retain(answer.raw, of: batch, in: run)

      // The fold answers DOCUMENT TEXT: there is nothing per-id to validate
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
      // rejected: spending a call on a value nobody is allowed to write is
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
      // re-asked one id at a time, which is what a cut is not (5.3).
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

      // A rejected id is NOT repaired any more (reader, 2026-09-14): it is marked failed
      // here, carrying the defect that rejected it, and the run's own RETRY of the
      // failed batches is the recovery path (5.11). A per-item repair call cost a whole
      // request — L0, L1 and the payload — for ONE value, while the retry re-asks the
      // whole batch with that context shared (5.9/5.11). What the reader gets instead of
      // an invisible call in the middle of a batch is a failure they can see and re-run.
      var resolved = report.accepted
      for id in report.rejected {
        guard let position = Int(id), batch.items.indices.contains(position) else { continue }
        let item = batch.items[position]
        let language = language(of: item, in: batch)
        batch.items[position].phase = .failed
        fail(
          run, key: item.key, language: language,
          message: "no usable translation: \(Validator.describe(replies[id], of: item, language: language))",
          retryable: false)
      }

      // The paid gate, over everything about to be written (5.4).
      resolved = try await gate(resolved, of: batch, in: run)

      // Write-back: one unit, decided per slot at the moment it is applied (5.5).
      apply(resolved, of: &batch, in: run)

      // Anything still unanswered is reported, never retried forever: the run keeps
      // its other results. An item already marked failed was REPORTED where it was
      // rejected, with the defect that rejected it — reporting it a second time as "no
      // translation produced" said the wrong thing about it (a translation WAS produced;
      // it was thrown out) and doubled the entry in the failure list (reader,
      // 2026-09-14).
      for (position, item) in batch.items.enumerated()
      where writable.contains(position) && resolved[String(position)] == nil
        && batch.items[position].phase != .failed {
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

    /// Keeps a batch's raw reply on the RUN's own copy of it, at the moment the reply
    /// arrives.
    ///
    /// `performOne` works on a VALUE of the batch and only writes it back when it returns,
    /// so a reply that arrived and was then followed by a throw (the paid gate, a cut
    /// reply's re-ask) would be lost with it — and 8.1 wants that reply on the page,
    /// because it is the one that failed. Only the batch's OWN request is kept: the gate's
    /// review answers one id at a time and is not what a page shows, and a
    /// re-ask's half carries an id the run's list does not hold (`<batch>.r0`), so writing
    /// nothing for it is also what keeps the page's reply the batch's own.
    private func retain(_ raw: String?, of batch: Run.Batch, in run: Run) {
      guard let index = run.batches.firstIndex(where: { $0.id == batch.id }) else { return }
      run.batches[index].rawReply = raw
    }

    /// Keeps the batch's own REQUEST on the RUN's copy of it, for the same reason the reply
    /// is kept there: `performOne` works on a value and only writes it back when it returns,
    /// and a page reads the run's list — so an input reached only through the returned value
    /// would be invisible for the whole of a send that then threw.
    ///
    /// Only the batch's OWN request: the review gate answers one id at a time of its own and is
    /// not what a stage page shows, and a re-ask's half carries an id the
    /// run's list does not hold (`<batch>.r0`), so nothing is written for it.
    private func retain(_ request: Prompt.Request, of batch: Run.Batch, in run: Run) {
      guard let index = run.batches.firstIndex(where: { $0.id == batch.id }) else { return }
      run.batches[index].request = request
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
      // The send is counted BEFORE the call and whatever becomes of it: an attempt that fails
      // is an attempt the provider was asked for, and a retry only exists because of them
      // (5.7, 5.9). `readTelemetry`'s `requests` is the client's count of calls that came
      // back, so the two numbers differ by exactly the attempts that failed.
      run.tally.sends += 1
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
    /// The write set is decided HERE, per slot, and its rule is the slot's own status for a
    /// write of the value — and, for a write that only records what the machine produced,
    /// the narrower rule a machine record asks (`Run.writable(_:for:)`, 4.1/2.4).
    /// `.verified` and `.imported` are not editable as VALUES, whatever the request asked
    /// for. That is also why the check is here rather than in a scan — a slot the human
    /// confirms while the batch is in flight still survives it (4.6).
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
          Run.writable(project.data[row].targets[slot], for: batch.stage)
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
                + (previous.isEmpty ? "filled empty slot" : "differs from previous machine value"),
            // A request produced it: no memory answered this slot.
            memory: nil))
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
      /// The source text the value answers, as the request was shown it. `Memory` is
      /// addressed by (source text, language) GLOBALLY (6.2), so both the resolve's
      /// read and the hint write need it beside the slot they belong to.
      let source: String
      let target: StringBody?
      let machine: StringBody?
      let status: LocalizationString.Status?
      let versions: Context.Version?
      let previous: StringBody
      /// The model that answered this write. Empty for a write memory answered: no
      /// model was asked, and the record says so instead (see `memory`).
      let model: String
      let reason: String
      /// The memory entry the value was RESOLVED from, when it came from memory
      /// instead of a model: nil for every write a request produced.
      ///
      /// It decides two things and nothing else. The RECORD's provenance: a gold entry
      /// is a value a human confirmed, so the store keeps it `reviewed` with the
      /// human's provider and names translation memory as the editor — the shape the
      /// old pipeline's memory resolve leaves, read as precedent and never called. And
      /// whether the write leaves a HINT behind: a model's output does (6.1/6.2), while
      /// a write memory answered is already an entry — the gold it resolved from, or the
      /// hint it filled a slot with — so re-recording it would only rewrite its
      /// provenance with this run's name.
      let memory: Memory.Grade?
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
            // Who wrote it decides the state. A model's output is unreviewed
            // (`needs_review`); a gold memory entry is a value a HUMAN confirmed
            // (10.19b), which is the one shape the store's own projection reads back as
            // `.verified` — and it is never an auto-reviewed import.
            record.state =
              value.isEmpty ? .empty : (write.memory == .gold ? .reviewed : .needs_review)
            if write.memory == .gold {
              record.autoReviewed = false
              record.reviewedAt = .now
            }
          }
          if let machine = form.machine { record.machine = machine }
          // Provenance. A gold entry is the human's value, so the record says who
          // vouched for it (`manual`, as the old pipeline's memory resolve left it),
          // and a value memory answered names translation memory as its editor instead
          // of a model that was never asked.
          record.provider = write.memory == .gold ? .manual : .deepseek
          record.lastEditor = write.memory == nil ? write.model : Self.memoryEditor
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
      // seed a candidate, but it never overrides a value a human or a machine wrote —
      // the store refuses to let a hint touch gold — and nothing here reads a hint
      // back as an answer to a slot.
      //
      // Only a translate stage's own output is a hint: prelearn writes the machine
      // record of a slot a HUMAN owns (`target` stays nil), which is not a value
      // this run produced; learn writes gold; and a write MEMORY answered is already
      // an entry — the gold it resolved from, or the hint it filled an empty slot
      // with — so re-recording it would only rewrite its provenance with this run's
      // name and its project tag (10.19).
      if let produced = write.target, write.memory == nil {
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
      // A write memory answered is not one of this step's CUT items: it is counted where
      // the report can see it, beside the items the step sent (5.7).
      if write.memory == nil {
        run.tally.itemsDone += 1
        run.tally.byStage[batch.stage, default: 0] += 1
      } else {
        run.tally.resolved[batch.stage, default: 0] += 1
      }
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
    /// settled slot is never a defect and is never re-asked (5.3, 4.6). For a prelearn
    /// batch it is the machine-record rule instead, so the machine record the operation
    /// exists for is an answer somebody asks for rather than one nobody requires.
    private func writablePositions(of batch: Run.Batch) -> IndexSet {
      var positions = IndexSet()
      for (position, item) in batch.items.enumerated() {
        let language = language(of: item, in: batch)
        guard let row = rowPositions[item.key], project.data.indices.contains(row),
          let slot = project.data[row].target(language),
          Run.writable(slot, for: batch.stage)
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

    /// One failed ATTEMPT of a batch's own request, recorded while the batch is still going:
    /// the same reading `markFailed` reports, without failing the batch.
    ///
    /// It exists so the failures list is the retry's HISTORY — one entry per attempt, in
    /// order — instead of only what the batch finally died of (5.9). The last entry is the
    /// one the status bar shows (`Run.failure`), which is right: it is the attempt the run
    /// actually gave up on.
    private func fail(_ run: Run, _ error: Error, on batch: Run.Batch) {
      fail(
        run, key: batch.items.first?.key, language: batch.language,
        message: error.localizedDescription, retryable: Self.retryable(error))
    }

    /// Marks a batch and its items failed, and reports it once.
    private func markFailed(_ batch: Run.Batch, error: Error, in run: Run) {
      if let index = run.batches.firstIndex(where: { $0.id == batch.id }) {
        run.batches[index].phase = .failed
        for item in run.batches[index].items.indices { run.batches[index].items[item].phase = .failed }
      }
      fail(run, error, on: batch)
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
  /// placeholder or an empty reply must never cost a review call.
  ///
  /// The checks and their tolerances follow `TranslationValidator` — read as the
  /// precedent, never called — one level up: the ids are the items' POSITIONS as
  /// strings (a key never travels, 10.15), and an answer is required only for a slot
  /// the run may WRITE (5.3).
  enum Validator {
    struct Report {
      var accepted: [String: String] = [:]
      /// Ids that answered badly: each is marked failed with its own defect, and the
      /// run's retry of the failed batches is the recovery (5.11).
      var rejected: [String] = []
      /// The reply was CUT OFF. A different failure from a rejected id on
      /// purpose: a truncated reply is re-asked in halves, never id by id.
      var truncated: Bool = false
      /// Ids the request never asked for. Reported, never applied: there is no item
      /// behind them, so there is nothing to re-ask on their behalf.
      var invented: [String] = []
    }

    /// Everything wrong with one answer. Empty means it is acceptable.
    enum Defect: Equatable {
      case empty
      /// Placeholder multiset differs from the source's.
      case placeholders(expected: [String], got: [String])

      var description: String {
        switch self {
        case .empty:
          return "empty response"
        case .placeholders(let expected, let got):
          return "placeholders changed (expected \(expected.joined(separator: " ")), got \(got.joined(separator: " ")))"
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
    /// because the right response differs — re-ask in halves instead of id by id (5.3).
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
    /// to judge in an empty answer, a placeholder multiset that did not survive (5.3).
    ///
    /// An answer IDENTICAL to its source is NOT a defect (reader, 2026-09-14: "Start is
    /// start in danish, symbol is symbol"). A language reuses a source word far more
    /// often than a check can tell, and the reviewer sees the slot — so sameness is
    /// written as `.translated` and judged by a human, never thrown away here.
    static func defects(_ answer: StringBody, of item: Run.Item) -> [Defect] {
      guard !answer.isEmpty else { return [.empty] }
      var defects: [Defect] = []
      let expected = placeholders(in: item.payloadSource).sorted()
      let got = placeholders(in: answer).sorted()
      if expected != got {
        defects.append(.placeholders(expected: expected, got: got))
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
