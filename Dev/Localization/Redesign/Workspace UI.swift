//
//  Workspace UI.swift
//  Dev
//
//  Created by Dmitry on 14.09.26.
//
//  The workspace's surfaces (Design notes 8.1): the CLOSABLE OVERLAY that holds the
//  stage pages, the bottom status bar that keeps reporting a run after the overlay is
//  closed, and the SHELL that reaches them — the toolbar's Start, the pane's overlay and
//  the pane's bar are three surfaces of ONE run, and `Shell` is what they share. Neither
//  surface is a stage's layout — the four designed pages (`*UI.swift`) are used exactly
//  as they are, with their samples left where they belong (their own #Previews), and
//  everything here is the BINDING that hands them the run's own batches instead of the
//  fixture.
//
//  Nothing here starts a run except the one button, and nothing here stops one: closing
//  the overlay is a presentation change, and a run is not presentation.

import Foundation
import ComponentKit
import SwiftUI

extension Translation {
  /// The workspace as it is shown: the overlay over whatever the project's own surface
  /// is, with the status bar underneath it — the one part that outlives a closed overlay.
  struct WorkspaceView: View {
    let workspace: Workspace

    var body: some View {
      VStack(spacing: 0) {
        ZStack {
          WorkspaceBackdrop(workspace: workspace)
          if workspace.isOverlayPresented {
            WorkspaceOverlay(workspace: workspace).transition(.move(edge: .bottom))
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        WorkspaceStatusBar(workspace: workspace)
      }
      .animation(.smooth, value: workspace.isOverlayPresented)
      // `error` is what the workspace owes an alert (a missing credential, or the
      // failure the last run ended on), and the shell is where it can be shown whether
      // the overlay is open or closed.
      .alert(
        "Translation",
        isPresented: Binding(
          get: { workspace.error != nil },
          set: { if !$0 { workspace.error = nil } })
      ) {
        Button("OK") { workspace.error = nil }
      } message: {
        Text(workspace.error ?? "")
      }
    }
  }

  /// What the overlay covers.
  ///
  /// The workspace's other surfaces — the language bar, the table with its badges and
  /// inline editors, review and the inspector (8.1) — are the browser's, so what is
  /// behind the overlay here is the one thing a run owes the user while they look at the
  /// project instead of at the run: its edits live in memory until Save, because a run
  /// never writes the `.xcstrings` (5.8, 8.3).
  private struct WorkspaceBackdrop: View {
    let workspace: Workspace

    var body: some View {
      VStack(spacing: 8) {
        Text(workspace.project.id).font(.title3.bold())
        // The state, not a claim: what this says is what the app's own dirty flag says (8.3).
        Text(
          workspace.isDirty
            ? "The run's edits are in memory until Save — a run never writes the .xcstrings."
            : "Nothing is waiting for Save — the catalog carries everything this session produced.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(32)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.background)
    }
  }

  /// The overlay: the run's rail, the page of the step the run is on, and what the run
  /// is costing. A run in flight stays a run in flight while this is closed — the status
  /// bar is where it keeps reporting.
  struct WorkspaceOverlay: View {
    let workspace: Workspace

    /// Whether the run's pages are UP for a workspace: there is a run to page through, and
    /// the user has not closed them. The pane presents the overlay on exactly this, so a
    /// pane with no run shows the catalog itself and closing the pages is a presentation
    /// change that stops nothing (8.1).
    static func isPresented(_ workspace: Workspace) -> Bool {
      workspace.isOverlayPresented && workspace.run != nil
    }

    var body: some View {
      let run = workspace.run
      let pages = binding(of: run)
      VStack(spacing: 0) {
        header(run)
        Divider()
        rail(run)
        Divider()
        page(run, pages)
        Divider()
        footer(run)
      }
      .background(.background)
    }

    /// The pages' binding for a run — CACHED by the run's `frame` and the session's human
    /// edits, not rebuilt per paint. Every row a run writes repaints this view (the tally
    /// moves), and a binding is every page of a step mapped from the batches: rebuilding it
    /// per row is what made a long run's overlay crawl. A cache hit reads neither the batches
    /// nor the rows, so a row write alone no longer even invalidates the pages.
    private func binding(of run: Run?) -> RunBinding? {
      guard let run else { return nil }
      return pages.binding(for: run, sessionEdits: workspace.sessionEdits)
    }

    /// The overlay's one cached `RunBinding` (see `binding(of:)`).
    @State private var pages = PageCache()

    // MARK: - the run

    private func header(_ run: Run?) -> some View {
      HStack(spacing: 12) {
        Text(workspace.stage.title).font(.title2.bold())
        if let state = run?.state {
          Text(state.title).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          workspace.closeOverlay()
        } label: {
          Label("Close", systemImage: "chevron.down")
        }
        .help("Close the run's pages — the run keeps going")
      }
      .padding(12)
    }

    /// The stage rail: PROGRESS, not a menu. One step per operation of the run, in the
    /// order the run performs them, each carrying what it found to do and how much of it
    /// is done — so a step with nothing to do reads as a step that did nothing, which is
    /// the whole reason the counts are here instead of a button per stage (8.1).
    private func rail(_ run: Run?) -> some View {
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          if let run {
            ForEach(RailStep.steps(of: run)) { step in
              RailChip(step: step)
            }
          } else {
            Text("No run yet — Start runs prepare, prelearn, learn, translate and the row pass.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .scrollIndicators(.hidden)
    }

    /// The step the overlay shows: the one the run is on now — "reopen lands where the
    /// run is" — or, once the run is over, the last step it reached, so a finished run
    /// still has its output on screen rather than nothing.
    private func displayed(_ run: Run) -> Stage? {
      run.operation ?? (run.isFinished ? run.operations.last : nil)
    }

    /// One of the four designed pages, bound to the live run.
    ///
    /// A step with nothing to do has no batch to page through, and says so: the rail
    /// already reads 0 of 0 for it, and an empty pager would say the same thing worse.
    ///
    /// The row page is the one page the binding cannot fill from the run's batches —
    /// they carry what the pass SENT, never what it wrote — so it is handed the
    /// project's journal, as the binding copied it (4.6, 7.1).
    @ViewBuilder
    private func page(_ run: Run?, _ binding: RunBinding?) -> some View {
      if let run, let binding, let step = displayed(run) {
        switch step {
        case .prepare:
          Notice(icon: "gearshape", title: "Preparing", detail: "Reading the project's rows and the imported database. No model call.")
        case .prelearn:
          if binding.prelearn.isEmpty {
            Notice(icon: "wand.and.stars", title: "\(step.title) had nothing to do", detail: "No settled slot is missing its machine record.")
          } else {
            VerticalPrelearn.Content(
              index: binding.pageIndex(step), operations: binding.prelearn,
              exchanges: binding.exchanges(.prelearn))
          }
        case .learn:
          if binding.learn.isEmpty {
            Notice(icon: "graduationcap", title: "\(step.title) had nothing to do", detail: "No correction differs from what the model produced.")
          } else {
            VerticalLearn.Content(
              index: binding.pageIndex(step), operations: binding.learn,
              exchanges: binding.exchanges(.learn))
          }
        case .vertical:
          if binding.vertical.isEmpty {
            Notice(icon: "translate", title: "\(step.title) had nothing to do", detail: "Every slot of every column is already settled.")
          } else {
            VerticalTranslate.Content(
              index: binding.pageIndex(step), operations: binding.vertical,
              exchanges: binding.exchanges(.vertical))
          }
        case .horizontal:
          if binding.rows.isEmpty {
            Notice(icon: "tablecells", title: "\(step.title) had nothing to do", detail: "No translatable row to sweep.")
          } else {
            HorizontalTranslate.Content(
              index: binding.pageIndex(step), operations: binding.rows,
              exchanges: binding.exchanges(.horizontal),
              journal: binding.journal)
          }
        }
      } else {
        Notice(
          icon: "play.circle",
          title: workspace.canStart ? "Ready" : "No model configured",
          detail: workspace.museNote
            ?? "One button runs the whole plan: prepare, prelearn, learn, translate, then the row pass.")
      }
    }

    /// What the run is costing, and the one button (5.7, 8.1). Start lives here and
    /// nowhere else; pause, resume and cancel are the same run's controls, and no step
    /// has a button of its own.
    private func footer(_ run: Run?) -> some View {
      VStack(alignment: .leading, spacing: 6) {
        if let run, run.progress != nil {
          RunEstimateBar(run: run)
        }
        HStack(spacing: 12) {
          controls(run)
          Spacer()
          if let run {
            Text(Self.tally(run)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
          }
        }
        HStack(spacing: 12) {
          // What the run's results are waiting for, as the state the bar reports rather than a
          // sentence about the design (8.3): in memory until Save, or nothing owed at all.
          if workspace.isDirty {
            Label(
              "In memory until Save — the .xcstrings is unchanged.",
              systemImage: "square.and.arrow.down")
              .font(.caption)
              .foregroundStyle(.secondary)
            Button("Save") {
              Task { await workspace.save() }
            }
            .help(
              "Write this session's results into "
                + (workspace.fileName ?? "the catalog") + " — Save is the only writer of the file")
          } else {
            Label(
              "Nothing is waiting for Save — the catalog carries everything this session produced.",
              systemImage: "checkmark.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let failure = run?.failure {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(2)
          }
          if let note = workspace.museNote {
            HStack(spacing: 6) {
              Text(note).font(.caption).foregroundStyle(.secondary)
              if !workspace.canStart {
                SettingsLink { Text("Open Settings…") }
                  .controlSize(.small)
              }
            }
          }
        }
      }
      .padding(12)
    }

    @ViewBuilder
    private func controls(_ run: Run?) -> some View {
      if run?.isRetrying == true {
        // A re-ask (5.11) is stopped, not paused: the run it belongs to is already finished, so
        // there is no cursor to resume from. The batches it did not reach stay failed, and the
        // button below offers them again the moment the re-ask is over.
        Button("Stop") { workspace.stopRetry() }
          .help("Stop re-asking — the batches it did not reach stay failed and are offered again")
      } else {
        switch run?.state {
        case .scanning, .running:
          Button("Pause") { workspace.pause() }
          Button("Cancel") { workspace.cancel() }
        case .paused:
          Button("Resume") { Task { try? await workspace.resume() } }
            .buttonStyle(.borderedProminent)
          Button("Cancel") { workspace.cancel() }
        case .cancelled, .finished, .idle, nil:
          // 5.11: a FINISHED run that gave up on batches offers the re-ask BESIDE Start — the same
          // batches again, not a second run of the whole plan. It covers both translate jobs (the
          // column pass and the row pass), and a run with nothing failed offers nothing.
          if let run, run.canRetryFailedBatches {
            Button {
              Task { try? await workspace.retryFailedBatches() }
            } label: {
              Label(
                "Retry failed batches (\(run.failedBatches.count))",
                systemImage: "arrow.clockwise")
            }
            .disabled(!workspace.canStart)
            .help(
              "Re-ask exactly the batches this run gave up on — the column pass and the row pass. "
                + "No scan and no re-cut: they go out as they stand.")
          }
          Button("Start") { Task { try? await workspace.start() } }
            .buttonStyle(.borderedProminent)
            .disabled(!workspace.canStartRun)
            .help(workspace.museNote ?? "Runs prepare, prelearn, learn, translate and the row pass")
          // The SECOND way in, immediately after Start (reader, 2026-09-14: "Place it right after
          // start button with `forward.fill` icon"): the same run with the two learning steps left
          // out. Icon-only, because Start is the button that needs a word — this one differs from
          // it by ONE thing, and its tooltip is where that thing is spelled out. Same shape as
          // Start: the same disabled rule (`canStartRun`), the same `museNote` fallback.
          Button {
            Task { try? await workspace.startSkippingLearning() }
          } label: {
            Image(systemName: "forward.fill")
          }
          .disabled(!workspace.canStartRun)
          .help(workspace.museNote ?? Run.skipLearningHelp)
        }
      }
    }

    /// 5.7's numbers: batches and items against the plan the run has cut so far, the
    /// characters it is paying for, the requests, the CACHED SHARE — a flat zero there
    /// means the prompt stopped being a cacheable prefix, not that the provider was
    /// unlucky — and the per-model table, whose single entry is the cheapest proof that
    /// nothing else answered.
    ///
    /// A retry shows up here twice, because attempts are COST: the request count reads the
    /// SENDS while a re-ask is going on (a batch answered on its fourth attempt says four),
    /// and the batch being re-asked names the attempt it is on — so a batch waiting out a
    /// park reads as slow rather than as stuck (5.9). Static, so the line is a value a probe
    /// can read instead of a sentence only a window can produce.
    static func tally(_ run: Run) -> String {
      var parts = [
        "\(run.tally.batchesDone)/\(run.tally.batches) batches",
        "\(run.tally.itemsDone)/\(run.tally.items) strings",
        run.tally.sends == run.tally.requests
          ? "\(run.tally.requests) requests"
          : "\(run.tally.sends) requests (\(run.tally.requests) answered)",
        "cache \(run.tally.cachedShare.formatted(.percent.precision(.fractionLength(0))))",
      ]
      if let reask = run.reasking {
        parts.insert("attempt \(reask.attempt) of \(Limits.retries + 1) on \(reask.id)", at: 3)
      }
      let models = run.tally.byModel
        .sorted { $0.key < $1.key }
        .map { "\($0.key) × \($0.value)" }
        .joined(separator: ", ")
      if !models.isEmpty { parts.append(models) }
      return parts.joined(separator: " · ")
    }
  }

  /// The run's estimated progress and the time it has left (`RunProgress`), read on a timer
  /// while the run lasts; once it stops, the bar stays where it got to.
  struct RunEstimateBar: View {
    let run: Run

    var body: some View {
      let isActive = run.state == .running || run.state == .scanning
      TimelineView(.animation(minimumInterval: 0.5, paused: !isActive)) { _ in
        let estimate = run.estimate
        HStack(spacing: 12) {
          KitProgressBar(
            status: isActive
              ? .working(progress: estimate?.fraction)
              : run.state == .finished ? .done : .paused(progress: estimate?.fraction))
          Text(estimate?.line ?? (isActive ? "Estimating…" : ""))
            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
      }
    }
  }

  /// The bottom bar: the run's state, and the way back into its pages.
  ///
  /// It is the one surface that survives the overlay being closed (8.1), so it reports
  /// the run — running or not, the step it is on, how far it got, how many failures it
  /// carries — and it reopens the overlay WHEREVER THE RUN IS NOW, because the overlay
  /// derives its rail and its page from the run rather than from where it was left.
  ///
  /// It is shown for a project whose workspace exists, run or not: before the first run
  /// its line is the honest "No run yet", and the reopen button is offered only once
  /// there is a run to reopen.
  struct WorkspaceStatusBar<Trailing: View>: View {
    let workspace: Workspace
    /// What ends the bar after the run's own reading (the catalog's counts).
    @ViewBuilder var trailing: Trailing

    init(workspace: Workspace, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
      self.workspace = workspace
      self.trailing = trailing()
    }

    /// Whether the bar offers the way back into the run's pages: there IS a run, and its
    /// pages are not already up. A run that was never started has nothing to reopen.
    var showsReopen: Bool { !workspace.isOverlayPresented && workspace.run != nil }

    var body: some View {
      // The estimate moves with time, so the bar reads it on a timer while a run lasts.
      TimelineView(.animation(minimumInterval: 0.5, paused: !workspace.status.isRunning)) { _ in
        bar(workspace.run?.estimate)
      }
      // The shell's own failure channel: a run that could not start (no credential, 5.2)
      // has nothing on screen to report from, and the bar is the one surface that
      // outlives a closed overlay (8.1).
      .alert(
        "Translation",
        isPresented: Binding(
          get: { workspace.error != nil },
          set: { if !$0 { workspace.error = nil } })
      ) {
        Button("OK") { workspace.error = nil }
      } message: {
        Text(workspace.error ?? "")
      }
    }

    private func bar(_ estimate: Run.Estimate?) -> some View {
      // The run's state lives in the bar's live icon (the kit's rule: never a spinner); its
      // ring fills with the run's estimated progress.
      StatusBar(
        systemImage: "translate",
        status: workspace.status.isRunning ? .working(progress: estimate?.fraction) : .idle
      ) {
        Text(workspace.status.summary).monospacedDigit()
        if workspace.status.isRunning, let line = estimate?.line {
          Text(line).monospacedDigit().foregroundStyle(.secondary)
        }
        // A run's edits are in memory until Save (8.3), and the bar is where the user looks
        // once the run's pages are closed — so the state is a READING here, not a sentence
        // somewhere in the overlay, and the act is beside it. Save goes through the app's own
        // writer (5.8), which is the same one ⌘S reaches: the flag behind this reading is the
        // flag behind ⌘S, so the two can never disagree.
        if workspace.isDirty {
          Chip("Unsaved", systemImage: "square.and.arrow.down", hue: .orange).controlSize(.small)
          Button("Save") {
            Task { await workspace.save() }
          }
          .buttonStyle(.kitPlain)
          .help(
            "Write this session's results into "
              + (workspace.fileName ?? "the catalog") + " — Save is the only writer of the file")
        }
        // The way back into the pages, offered while there IS a run to go back to: the
        // overlay is presented FOR a run, so a bar with none has nothing to reopen.
        if showsReopen {
          Button("Show Run", systemImage: "chevron.up") {
            workspace.reopenOverlay()
          }
          .buttonStyle(.kitPlain)
          .help("Reopen the run's pages where the run is now")
        }
        trailing
      }
    }
  }

  /// A live `Run`, as the four designed pages expect to be handed their batches.
  ///
  /// This is the BINDING and nothing else. The pages' shapes are the stages' —
  /// `VerticalPrelearn.Operations` and friends, one page per batch — and what a batch
  /// does not carry is added here: the row's position in `project.data`, which is what a
  /// page means by `index`, and the CURRENT value of a slot, read off the open rows,
  /// because the write-back updates the rows and never the batch it came from (5.5).
  ///
  /// One pass builds the index, so a page's item lookup is a dictionary hit rather than
  /// a scan of the catalog.
  @MainActor final class RunBinding {
    let run: Run
    /// The project's journal as of this binding — a copy, so the row page's outcomes read the
    /// same moment as the rows it shows.
    let journal: HorizontalTranslate.Journal
    /// The open rows by key — where a slot's live value comes from — with the position
    /// each one sits at, which is what a page's `index` means (its fixtures index
    /// `project.data`).
    private let index: [String: Row]
    private struct Row {
      let key: LocalizationKey
      let position: Int
    }

    init(run: Run) {
      self.run = run
      journal = run.project.journal
      index = Dictionary(
        run.project.data.enumerated().map { ($0.element.key, Row(key: $0.element, position: $0.offset)) },
        uniquingKeysWith: { first, _ in first })
    }

    /// Which page of a step's paging view the run is on NOW: the ordinal of the cursor's
    /// batch among that step's batches, clamped — a step the run has finished has run
    /// past its last page. This is "reopen wherever the run is now", in one number (8.1).
    func pageIndex(_ step: Stage) -> Int {
      let leading = run.batches.prefix { $0.stage != step }.count
      let count = run.batches.dropFirst(leading).prefix { $0.stage == step }.count
      guard count > 0 else { return 0 }
      return min(max(run.batchIndex - leading, 0), count - 1)
    }

    // MARK: - the pages

    /// BOTH SIDES of every page of a step, PARALLEL to the step's pages
    /// (`prelearn` / `learn` / `vertical` / `rows`) — the right half of every stage page reads
    /// this and nothing else (8.1, "stage pages").
    ///
    /// ONE value per batch (`Run.Exchange`: the input that was sent and the reply that came
    /// back) and one shape for all four pages. It is built over the SAME batches the pages are
    /// built from, so page n and its exchange are the same batch by construction — and because
    /// the two sides are two fields of one value rather than two parallel arrays, batch N's
    /// input cannot be shown beside batch M's reply. Never parsed here: the pane prints both
    /// texts as they came.
    func exchanges(_ step: Stage) -> [Run.Exchange] {
      if let cached = exchangesByStep[step] { return cached }
      let made = batches(step).map(\.exchange)
      exchangesByStep[step] = made
      return made
    }
    private var exchangesByStep: [Stage: [Run.Exchange]] = [:]

    // Each step's pages are built on first read and kept for the life of the binding.
    private(set) lazy var prelearn = makePrelearn()
    private(set) lazy var learn = makeLearn()
    private(set) lazy var vertical = makeVertical()
    private(set) lazy var rows = makeRows()

    /// Prelearn's pages: a source and the machine version being produced for a slot a
    /// human already settled. It is never a translation anybody reads (4.1).
    private func makePrelearn() -> [VerticalPrelearn.Operations] {
      batches(.prelearn).map { batch in
        VerticalPrelearn.Operations(
          language: batch.language ?? "",
          items: batch.items.map { item in
            VerticalPrelearn.Operation(
              key: item.key,
              index: position(item.key),
              comment: item.comment,
              source: item.source,
              machine: machine(item),
              // The row's own state, so the page marks the ROW and not the batch (8.1).
              phase: item.phase)
          },
          isCompleted: batch.phase == .applied,
          isFailed: batch.phase == .failed)
      }
    }

    /// Learn's pages: the difference between what the model produced and what the human
    /// settled on, and the document line each one becomes (4.1).
    private func makeLearn() -> [VerticalLearn.Operations] {
      batches(.learn).map { batch in
        VerticalLearn.Operations(
          language: batch.language ?? "",
          items: batch.items.map { item in
            VerticalLearn.Operation(
              key: item.key,
              index: position(item.key),
              comment: item.comment,
              source: item.source,
              machine: machine(item),
              target: target(item),
              // The row's own state, so the page marks the ROW and not the batch (8.1).
              phase: item.phase)
          },
          isCompleted: batch.phase == .applied,
          isFailed: batch.phase == .failed)
      }
    }

    /// The column pages: one page per language batch, its items in the run's order.
    private func makeVertical() -> [VerticalTranslate.Operations] {
      batches(.vertical).map { batch in
        var group = VerticalTranslate.Operations(
          language: batch.language ?? "",
          items: batch.items.map { item in
            VerticalTranslate.Operation(
              key: item.key,
              index: position(item.key),
              comment: item.comment,
              maxWidth: item.maxWidth,
              source: item.source,
              target: target(item),
              // The row's own state, so the page marks the ROW and not the batch (8.1).
              phase: item.phase)
          })
        // This stage's group takes only its language and its items, so the batch's own
        // phase — what the page's reveal reads — is set here.
        group.isCompleted = batch.phase == .applied
        group.isFailed = batch.phase == .failed
        return group
      }
    }

    /// The row pages: one page per row batch, and a page per ROW rather than per item —
    /// a request carries every language of the row, so the batch is flat and the page is
    /// not (4.6).
    private func makeRows() -> [HorizontalTranslate.Operations] {
      batches(.horizontal).map { batch in
        HorizontalTranslate.Operations(
          items: Self.rows(of: batch).map { items in
            let first = items[0]
            return HorizontalTranslate.Operation(
              key: first.key,
              index: position(first.key),
              comment: first.comment,
              maxWidth: first.maxWidth,
              source: first.source,
              targets: row(first.key)?.targets ?? items.map {
                LocalizationString(language: $0.language ?? "", target: $0.target)
              },
              // A row page's item is a ROW, so its phase is the row's own reading of its
              // columns (8.1): the narrowest equivalent this page needs.
              phase: Self.rowPhase(items, of: batch))
          },
          isCompleted: batch.phase == .applied,
          isFailed: batch.phase == .failed)
      }
    }

    // MARK: - reading

    private func batches(_ step: Stage) -> [Run.Batch] {
      run.batches.filter { $0.stage == step }
    }

    /// A row batch's items, gathered back into rows. The batch is one item per
    /// (row, language) in row order, so the run of equal keys IS the row.
    private static func rows(of batch: Run.Batch) -> [[Run.Item]] {
      var rows: [[Run.Item]] = []
      for item in batch.items {
        if rows.last?.first?.key == item.key {
          rows[rows.count - 1].append(item)
        } else {
          rows.append([item])
        }
      }
      return rows
    }

    /// The phase ONE ROW of a row batch carries, read off the row's own items (8.1): failed
    /// when any column of the row failed, written when any was written — and otherwise the
    /// batch's own phase, because a row whose every column is context (a settled one that only
    /// travelled with the request) has nothing of its own to report.
    ///
    /// A row is where this page's "row" and the run's item meet: the request carries one item
    /// per (row, language) and the page draws one line per row, so this is the narrowest
    /// equivalent the page needs — never the batch's flag, which would mark every row of a
    /// batch for the one row that went wrong.
    private static func rowPhase(_ items: [Run.Item], of batch: Run.Batch) -> Run.Phase {
      if items.contains(where: { $0.phase == .failed }) { return .failed }
      if items.contains(where: { $0.phase == .applied }) { return .applied }
      return batch.phase
    }

    private func row(_ key: String) -> LocalizationKey? { index[key]?.key }

    private func position(_ key: String) -> Int { index[key]?.position ?? 0 }

    private func slot(_ item: Run.Item) -> LocalizationString? {
      row(item.key)?.targets.first { $0.language == item.language }
    }

    /// The machine record for an item: the row's live one when it has it, else what the
    /// batch was scanned with. The write-back updates the ROW, so this is what makes a
    /// page fill in as the run lands its batches.
    private func machine(_ item: Run.Item) -> StringBody {
      let live = slot(item)?.machine ?? .empty
      return live.isEmpty ? item.machine : live
    }

    /// The value a slot holds now — the row's live target, or what the batch was
    /// scanned with when the project has no row for it.
    private func target(_ item: Run.Item) -> StringBody {
      let live = slot(item)?.target ?? .empty
      return live.isEmpty ? item.target : live
    }
  }

  /// The overlay's cached `RunBinding`: rebuilt only when the run, its `frame` or the
  /// session's human edits move. What the binding reads beyond those — the session's rows,
  /// the journal — is read at build time, so a page lags a row write by at most one frame
  /// (`Runner.publishWindow`), which is the pace the pages were already published at.
  @MainActor final class PageCache {
    private struct Key: Equatable {
      let run: ObjectIdentifier
      let frame: Int
      let sessionEdits: Int
    }
    private var key: Key?
    private var cached: RunBinding?

    func binding(for run: Run, sessionEdits: Int) -> RunBinding {
      let key = Key(run: ObjectIdentifier(run), frame: run.frame, sessionEdits: sessionEdits)
      if key == self.key, let cached { return cached }
      let made = RunBinding(run: run)
      self.key = key
      cached = made
      return made
    }
  }

  /// One step of the rail: what the run found in it, and how much of it is done.
  private struct RailStep: Identifiable {
    let id: Stage
    /// The step the run is on now.
    let isCurrent: Bool
    /// True once the run has reached this step — including the step in progress.
    let hasRun: Bool
    /// Items done / items the step CUT. Zero of zero is a step that found nothing to do,
    /// which is a reading the rail has to be able to show (8.1).
    let done: Int
    let total: Int
    /// Preparation is a pass, not a batch: it has no counts to report.
    var showsCounts: Bool { id != .prepare }

    static func steps(of run: Run) -> [RailStep] {
      run.operations.enumerated().map { position, step in
        RailStep(
          id: step,
          isCurrent: step == run.operation,
          hasRun: position < run.operationIndex || step == run.operation,
          done: run.tally.byStage[step] ?? 0,
          total: run.batches.filter { $0.stage == step }.reduce(0) { $0 + $1.items.count })
      }
    }
  }

  private struct RailChip: View {
    let step: RailStep

    private var icon: String {
      if step.isCurrent { "arrow.triangle.2.circlepath" } else if step.hasRun { "checkmark.circle.fill" } else { "circle.dotted" }
    }

    var body: some View {
      HStack(spacing: 6) {
        Image(systemName: icon)
        Text(step.id.title)
        if step.showsCounts {
          Text("\(step.done)/\(step.total)").monospacedDigit().foregroundStyle(.secondary)
        }
      }
      .font(.callout)
      .foregroundStyle(step.hasRun ? .primary : .secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(
        Capsule().fill(Color.accentColor.opacity(step.isCurrent ? 0.15 : 0.06))
      )
    }
  }

  /// A step with nothing to page through, or a workspace with no run at all: one line
  /// where a page would be, instead of an empty pager.
  private struct Notice: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
      VStack(spacing: 8) {
        Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
      .padding(32)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - the shell

  /// The bridge between the app's shell and a project's run (8.1, "entry").
  ///
  /// The redesign's run has to be REACHABLE before it can be judged, and the three
  /// surfaces around it have to speak about ONE run: the toolbar's `Start`, the pane's
  /// overlay and the pane's status bar. This is what they share — it owns the redesign's
  /// `Store` handle over the app's ONE SwiftData container (10.16: the same records the
  /// browser reads, never a copy) and one `Workspace` per project, built exactly the way
  /// the design builds one: a `Global`, then `loadProject`, then the project's own
  /// `open`.
  ///
  /// A workspace is kept for the life of the shell, not the life of a pane: a pane that
  /// appears for another project focuses another workspace, and a run already going is
  /// never stopped by that — it keeps its own state and keeps reporting through its own
  /// bar. Nothing here writes the `.xcstrings` (Save is the only writer, 5.8).
  @Observable @MainActor final class Shell {
    /// The app's one SwiftData context, seen from the redesign.
    private let store: Store
    /// The registry every workspace is built through: the cross-project document and the
    /// resident projects.
    private var global: Global?
    /// One workspace per project, keyed by the redesign's project id.
    private var workspaces: [String: Workspace] = [:]
    /// The parsed catalog each project's pane handed over, by the catalog URL it came from.
    ///
    /// A workspace's rows are one per CATALOG key (4.8), so one can only be built from the
    /// artifact itself — and the toolbar's `Start` has a URL and nothing else. The pane is the
    /// one surface that holds the parsing (`LocalizationStore.catalog`), so it hands it over
    /// on focus and the shell keeps it for the Start.
    private var catalogs: [String: StringCatalog] = [:]
    /// Which project a catalog URL belongs to. A pane holds a FILE URL and nothing else,
    /// so the app's own row — resolved once, here — is what names its workspace.
    private var projects: [String: String] = [:]
    /// The store a pane handed over, and WHICH catalog it was showing when it did (5.8).
    ///
    /// A store belongs to a window and a catalog belongs to a project, so the two travel
    /// together: a workspace is only ever attached to the store that came with ITS OWN catalog.
    /// Attaching every workspace to the latest store would, with two windows open, hand project
    /// A's session to project B's catalog — where the store's own URL guard refuses it, and A's
    /// results would then never reach a file at all.
    private weak var handedOver: LocalizationStore?
    private var handedOverURL: String?
    /// What went wrong on the way IN (a store without that project, a workspace that
    /// could not be built). Carried here because there is no run yet to carry it.
    var error: String?

    init() {
      store = Store(context: TranslationStore.shared.context)
    }

    /// A shell over a store the caller already holds. The app's own shell is `init()`;
    /// this is for a caller that owns its own container handle.
    init(store: Store) {
      self.store = store
    }

    /// The workspace a pane is showing, once this shell has built one.
    func workspace(for catalogURL: URL) -> Workspace? {
      guard let project = projects[catalogURL.path] else { return nil }
      return workspaces[project]
    }

    /// The pane hands over the app's own store, TOGETHER WITH the catalog it is showing: the
    /// instance the browser displays and Save writes (5.8), and the file whose editing session it
    /// is. Called every time a bound pane appears, so a window reopened after another one closed
    /// attaches ITS store.
    ///
    /// The workspace of that catalog is attached at once if it already exists — a run's results
    /// must not wait for a focus — and `focus` attaches it for the workspace it is about to build.
    func handOver(store: LocalizationStore, catalogURL: URL) {
      handedOver = store
      handedOverURL = catalogURL.path
      if let project = projects[catalogURL.path] {
        workspaces[project]?.attach(store)
      }
    }

    /// Opens — or re-focuses — the workspace of the project a pane is showing, and hands
    /// it back. Building one is a store read plus the project's own open: its rows, the
    /// imported database (6.3) and where the last run of each stage stopped.
    ///
    /// Called by the pane when it appears and by `start` before a run, so a Start always
    /// acts on the workspace the pane is showing. `catalog` is the parsing the pane holds: the
    /// rows are one per CATALOG key (4.8), so the artifact the pane is showing is the only
    /// thing a workspace can be built from — and it is kept, because `start`'s own input is a
    /// URL and nothing else.
    ///
    /// A workspace whose rows are still empty is opened AGAIN. That is a RETRY, not a wait:
    /// an open that failed (a store fetch, a project row that is not there yet) leaves no rows
    /// behind, and a focus is the next moment to try again. The rows themselves no longer wait
    /// for the app's own reconcile — the catalog supplies them — which is what this re-open
    /// used to exist for.
    @discardableResult
    func focus(catalogURL: URL, catalog: StringCatalog) async -> Workspace? {
      guard let row = try? store.projectRow(id: catalogURL.path) else { return nil }
      projects[catalogURL.path] = row.name
      catalogs[catalogURL.path] = catalog
      if let workspace = workspaces[row.name] {
        if workspace.project.data.isEmpty {
          try? await workspace.open(catalog: catalog, from: catalogURL)
        }
        // A workspace built before this pane handed its store over learns about it HERE: its
        // session is published on attach, so a run that landed with no store to publish into
        // still reaches the catalog a Save writes (5.8). Only the store handed over WITH this
        // catalog is attached — see `handedOver`.
        if let handedOver, handedOverURL == catalogURL.path { workspace.attach(handedOver) }
        error = nil
        return workspace
      }
      do {
        if global == nil { global = try Global(store: store) }
        guard let global = self.global else { return nil }
        let workspace = Workspace(project: try global.loadProject(id: row.name), store: store)
        workspaces[row.name] = workspace
        try await workspace.open(catalog: catalog, from: catalogURL)
        if let handedOver, handedOverURL == catalogURL.path { workspace.attach(handedOver) }
        error = nil
        return workspace
      } catch {
        self.error = error.localizedDescription
        return nil
      }
    }

    /// Whether EITHER of the toolbar's start buttons can do anything for a pane: its workspace
    /// exists, Muse has a credential (5.2), and no run of it is in flight — a run already going
    /// is paused or cancelled from its own pages rather than started twice (8.1).
    ///
    /// One reading for the pair, and the same one the pane's own bar reads
    /// (`Workspace.canStartRun`): the toolbar offers BOTH starts, so a rule stated per button
    /// would be a rule that can drift from its twin.
    func canStart(_ catalogURL: URL) -> Bool {
      guard let workspace = workspace(for: catalogURL) else { return false }
      return workspace.canStartRun
    }

    /// The toolbar's Start: the run's pages come back up — a run the user just asked for
    /// is a run they can watch — and then the run itself starts, or the one already in
    /// flight is resumed. What a run reports about itself is the workspace's own.
    ///
    /// The artifact the pane handed over on focus is what a workspace is built from (4.8), and
    /// there is no other way in: `canStart` reads the same workspace, so the button this path
    /// belongs to is only enabled once the pane has handed it over.
    func start(_ catalogURL: URL) async {
      await start(catalogURL, mode: .full)
    }

    /// The toolbar's SECOND Start (reader, 2026-09-14): the same path with the learning steps
    /// left out of the plan. One implementation for both, because the two buttons differ by
    /// exactly one thing — the mode the run is built with — and everything else about starting
    /// (the focus, the pages coming back up, the run's own reporting) is the same act.
    func startSkippingLearning(_ catalogURL: URL) async {
      await start(catalogURL, mode: .skipLearning)
    }

    private func start(_ catalogURL: URL, mode: Translation.Run.Mode) async {
      guard let catalog = catalogs[catalogURL.path] else { return }
      guard let workspace = await focus(catalogURL: catalogURL, catalog: catalog) else { return }
      workspace.reopenOverlay()
      try? await workspace.run(.vertical, mode: mode)
    }

    /// The Start button's help: why it is not available, or what it runs. A run in flight
    /// is the nearer reason of the two — the button is offering a WAIT, not a broken app.
    func startHelp(_ catalogURL: URL) -> String {
      help(catalogURL, saying: "Run prepare, prelearn, learn, translate, then the row pass (8.1)")
    }

    /// The skip-learning button's help — the same shape, saying what THIS button does. The
    /// sentence itself lives on `Run` beside the plan it describes, so the toolbar's button and
    /// the pane's bar cannot end up describing two different runs.
    func skipLearningHelp(_ catalogURL: URL) -> String {
      help(catalogURL, saying: Translation.Run.skipLearningHelp)
    }

    /// What a start button says about itself, for either of the two: why it is not available,
    /// or the sentence the caller supplies for what it would run.
    private func help(_ catalogURL: URL, saying sentence: String) -> String {
      guard let workspace = workspace(for: catalogURL) else {
        return "The redesign's run starts once this project's catalog is open"
      }
      if workspace.status.isRunning { return "A run is in flight — pause or cancel it on its pages" }
      if let note = workspace.museNote { return note }
      return sentence
    }

    // MARK: - clearing the store (Design notes 7.5)

    /// True while ANY project's redesign run is in flight — one of the reasons the
    /// app-level clear waits (7.5). Every workspace is asked, not just the focused
    /// one: a run keeps going while its pane is looking at another project.
    var isRunning: Bool { workspaces.values.contains { $0.runner.isRunning } }

    /// Drops every cache this shell holds OVER the store, before a single row of it
    /// is deleted.
    ///
    /// The workspaces and the `Global` registry under them are what has to go, and
    /// they cannot be reloaded in place: a workspace's rows carry the slot states
    /// the store supplied and its runner's batches carry the values a run wrote,
    /// and a `Project` re-projects nothing once it has rows (its `loadData` is a
    /// one-shot builder). The parsed CATALOGS stay — they are the artifacts the
    /// panes handed over, and a clear never touches a file.
    func dropStoreCaches() {
      workspaces.removeAll()
      global = nil
      error = nil
    }

    /// Rebuilds every project's workspace from the artifact it was built from, once
    /// the store has emptied: the rows come from the catalog (4.8), so the project
    /// reads as untranslated work rather than as a project whose values were taken
    /// away.
    ///
    /// The artifact used is the pane's CURRENT one when the pane is holding it —
    /// the clear has just re-read that catalog from its file, and the shell's own
    /// copy is the parse from the last focus, which can still carry values a run
    /// had published into it. A project whose pane is closed falls back to the
    /// parse this shell kept.
    ///
    /// This is the same build a pane focus does, which is what makes a pane reopen
    /// after a clear a no-op: the workspace the pane asks for is already there and
    /// already empty of store state. It is done EAGERLY, so an open pane never
    /// keeps showing the run it had over a store that no longer holds it.
    func rebuildAfterStoreClear() {
      var handed = catalogs
      if let pane = handedOver, let path = handedOverURL, let catalog = pane.catalog {
        handed[path] = catalog
      }
      guard !handed.isEmpty else { return }
      Task { [weak self] in
        for (path, catalog) in handed {
          await self?.focus(catalogURL: URL(fileURLWithPath: path), catalog: catalog)
        }
      }
    }
  }
}

private extension Translation.Run.State {
  /// The word the overlay's header shows for a run's state.
  var title: String {
    switch self {
    case .idle: "Ready"
    case .scanning: "Scanning"
    case .running: "Running"
    case .paused: "Paused"
    case .cancelled: "Cancelled"
    case .finished: "Finished"
    }
  }
}

/// The shell with no run in it yet: the rail's empty reading, the workspace's backdrop
/// and the bar. A run only ever appears by pressing the button, so the bound half — the
/// four pages on live batches — is what the probe drives instead; a preview must not
/// spend a real call to show it.
#Preview("Workspace") {
  let store = Translation.Store(context: TranslationStore.shared.context)
  let global = try! Translation.Global(store: store)
  let project = try! global.loadProject(id: "Dev")
  Translation.WorkspaceView(workspace: Translation.Workspace(project: project, store: store))
    .frame(width: 900, height: 620)
}
