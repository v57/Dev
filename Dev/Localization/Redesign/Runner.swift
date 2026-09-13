//
//  Runner.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  Design only: signatures with placeholder bodies that compile and change no
//  behaviour. Semantics are in "Design notes.md", section 5.
//
//  The stage classes know WHAT to send; this is what knows HOW: admission, prompt
//  assembly, the model, validation, repair, the paid gate, write-back, checkpoint,
//  telemetry. Every call goes to Muse (there is no chain to walk), and it never
//  writes the artifact (Save is the only writer of the .xcstrings).
//
//  Nothing here is referenced by the current pipeline and nothing here calls into
//  it: the two implementations run side by side until the old one is deleted.
//

import SwiftUI

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
    /// Cursor into `batches`: the next batch to start. Persisted, so an
    /// interrupted run resumes at the next unstarted batch instead of re-billing
    /// the finished ones.
    var batchIndex: Int = 0
    var batches: [Batch] = []
    var tally = Tally()
    var failure: Failure?
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
      /// The L1 language for a per-language batch; nil for a row batch, where the
      /// language is named inside each item.
      let language: String?
      var items: [Item]
      let characters: Int
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
      var phase: Phase = .pending
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
  }

  /// Executes a run. One runner per project: a project can have at most one run
  /// of a stage going, and `learn` is a single writer of language documents.
  @Observable @MainActor class Runner {
    let project: Project
    private(set) var runs: [Stage: Run] = [:]
    var isRunning: Bool { false }

    init(project: Project) {
      self.project = project
    }
    /// Runs a stage's whole plan, one batch at a time, from its first operation to
    /// its last: a translate run is prepare -> prelearn -> learn -> translate.
    @discardableResult
    func run(_ stage: Stage) async throws -> Run {
      Run(stage: stage, project: project)
    }
    /// Continues a run from its cursor, skipping everything already applied.
    func resume(_ run: Run) async throws {

    }
    /// Cancels the batch in flight and keeps everything already applied.
    func pause(_ run: Run) {

    }
    func cancel(_ run: Run) {

    }
    /// One batch, start to applied: admission, prompt, chain, validation, repair,
    /// gate, write-back, checkpoint, telemetry.
    private func perform(_ batch: Run.Batch, in run: Run) async throws {

    }
    /// The write-back a batch owns: `target`, `machine`, status -> `.translated`,
    /// the version stamp of the documents the request was built against, the
    /// producing model's name, and one journal row — then the checkpoint.
    ///
    /// The write set is decided HERE, per slot, and its only rule is the slot's own
    /// status: `.verified` and `.imported` are not editable, whatever the request
    /// asked for. That is also why the check is here rather than in a scan — a slot
    /// the human confirms while the batch is in flight still survives it.
    private func apply(_ results: [String: String], of batch: Run.Batch, in run: Run) {

    }
    /// Persists the cursor and the tally. A batch is resumable at batch
    /// granularity; nothing finer is promised.
    private func checkpoint(_ run: Run) async throws {

    }
  }

  /// The one model client. Every call in the redesign goes to Muse: no free tier, no
  /// fallback ladder, no second opinion. What survives from the current
  /// implementation's routing work is admission and cooldown — neither was ever
  /// about model choice, both are about not burning a batch on a provider that is
  /// known to be down.
  @Observable @MainActor class Router {
    /// Muse, the only candidate there is.
    struct Candidate: Identifiable {
      let id: String
      let model: String
      var cooldownUntil: Date?
    }
    let muse: Candidate
    init(muse: Candidate) {
      self.muse = muse
    }
    /// Muse, unless it is cooling down — in which case a run WAITS. There is nothing
    /// to fall back to, which is the point.
    func next() -> Candidate? { nil }
    /// A quota answer parks Muse until its `Retry-After`; anything else for a fixed
    /// window. One dead provider then costs one call per window, not one per record.
    func coolDown(_ candidate: Candidate, retryAfter: TimeInterval?) {

    }
    /// Admission: suspends while the provider's requests-per-minute budget is full,
    /// rather than failing the batch.
    func admit(_ candidate: Candidate) async throws {

    }
    /// One request. Returns one value per id the model actually answered — a
    /// missing id is the validator's business, not an error here.
    func send(_ request: Prompt.Request, using candidate: Candidate) async throws -> [String: String] {
      [:]
    }
    /// Is Muse usable at all (referenced, not cooling down)? Asked before a run
    /// starts, so an unconfigured app fails at the button and not per batch.
    var isEligible: Bool { false }
  }

  /// Deterministic, free, and always run before the paid gate: a dropped
  /// placeholder, an echoed source or an empty reply must never cost a review
  /// call.
  enum Validator {
    struct Report {
      var accepted: [String: String] = [:]
      /// Ids that answered badly: repaired one at a time, in their own language.
      var rejected: [String] = []
      /// The reply was CUT OFF. A different failure from a rejected id on
      /// purpose: a truncated reply is re-asked in halves, never repaired one id
      /// at a time.
      var truncated: Bool = false
    }
    /// Id set, placeholder multiset per item, untranslated echo, empty reply.
    /// An answer is required only for a slot the run may write — the same per-slot
    /// status check the write-back makes. A settled value travelled as context, and
    /// an empty or different answer for it is not a defect: rejecting it would spend
    /// a repair call on a value nobody is allowed to write.
    static func validate(_ reply: [String: String], for items: [Run.Item]) -> Report {
      Report()
    }
    static func isTruncated(_ raw: String) -> Bool { false }
  }
}
