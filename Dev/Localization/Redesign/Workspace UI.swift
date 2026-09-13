//
//  Workspace UI.swift
//  Dev
//
//  Created by Dmitry on 14.09.26.
//
//  The workspace's two surfaces (Design notes 8.1): the CLOSABLE OVERLAY that holds the
//  stage pages, and the bottom status bar that keeps reporting a run after the overlay
//  is closed. Neither is a stage's layout — the four designed pages (`*UI.swift`) are
//  used exactly as they are, with their samples left where they belong (their own
//  #Previews), and everything here is the BINDING that hands them the run's own batches
//  instead of the fixture.
//
//  Nothing here starts a run except the one button, and nothing here stops one: closing
//  the overlay is a presentation change, and a run is not presentation.

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
        Text("The run's edits are in memory until Save — a run never writes the .xcstrings.")
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

    /// The pages' binding for a run, built once per paint: it indexes the open rows, so
    /// a page's item lookup is a dictionary hit and not a scan of the catalog.
    private func binding(of run: Run?) -> RunBinding? {
      guard let run else { return nil }
      return RunBinding(run: run)
    }

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
    /// they carry what the pass SENT, never what it wrote — so it is handed its
    /// project's journal on the way past, through the page's own reader (4.6, 7.1).
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
            VerticalPrelearn.Content(index: binding.pageIndex(step), operations: binding.prelearn)
          }
        case .learn:
          if binding.learn.isEmpty {
            Notice(icon: "graduationcap", title: "\(step.title) had nothing to do", detail: "No correction differs from what the model produced.")
          } else {
            VerticalLearn.Content(index: binding.pageIndex(step), operations: binding.learn)
          }
        case .vertical:
          if binding.vertical.isEmpty {
            Notice(icon: "translate", title: "\(step.title) had nothing to do", detail: "Every slot of every column is already settled.")
          } else {
            VerticalTranslate.Content(index: binding.pageIndex(step), operations: binding.vertical)
          }
        case .horizontal:
          if binding.rows.isEmpty {
            Notice(icon: "tablecells", title: "\(step.title) had nothing to do", detail: "No translatable row to sweep.")
          } else {
            HorizontalTranslate.Content(
              index: binding.pageIndex(step), operations: binding.rows,
              journal: HorizontalTranslate.journal(of: run.project))
          }
        }
      } else {
        Notice(
          icon: "play.circle",
          title: workspace.canStart ? "Ready" : "Muse is not configured",
          detail: workspace.museNote
            ?? "One button runs the whole plan: prepare, prelearn, learn, translate, then the row pass.")
      }
    }

    /// What the run is costing, and the one button (5.7, 8.1). Start lives here and
    /// nowhere else; pause, resume and cancel are the same run's controls, and no step
    /// has a button of its own.
    private func footer(_ run: Run?) -> some View {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 12) {
          controls(run)
          Spacer()
          if let run {
            Text(tally(run)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
          }
        }
        HStack(spacing: 12) {
          Label(
            "A run's results are in memory until Save — it never writes the .xcstrings.",
            systemImage: "square.and.arrow.down")
            .font(.caption)
            .foregroundStyle(.secondary)
          if let failure = run?.failure {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(2)
          }
          if let note = workspace.museNote {
            Text(note).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .padding(12)
    }

    @ViewBuilder
    private func controls(_ run: Run?) -> some View {
      switch run?.state {
      case .scanning, .running:
        Button("Pause") { workspace.pause() }
        Button("Cancel") { workspace.cancel() }
      case .paused:
        Button("Resume") { Task { try? await workspace.resume() } }
          .buttonStyle(.borderedProminent)
        Button("Cancel") { workspace.cancel() }
      case .cancelled, .finished, .idle, nil:
        Button("Start") { Task { try? await workspace.start() } }
          .buttonStyle(.borderedProminent)
          .disabled(!workspace.canStart)
          .help(workspace.museNote ?? "Runs prepare, prelearn, learn, translate and the row pass")
      }
    }

    /// 5.7's numbers: batches and items against the plan the run has cut so far, the
    /// characters it is paying for, the requests, the CACHED SHARE — a flat zero there
    /// means the prompt stopped being a cacheable prefix, not that the provider was
    /// unlucky — and the per-model table, whose single entry is the cheapest proof that
    /// nothing else answered.
    private func tally(_ run: Run) -> String {
      var parts = [
        "\(run.tally.batchesDone)/\(run.tally.batches) batches",
        "\(run.tally.itemsDone)/\(run.tally.items) strings",
        "\(run.tally.requests) requests",
        "cache \(run.tally.cachedShare.formatted(.percent.precision(.fractionLength(0))))",
      ]
      let models = run.tally.byModel
        .sorted { $0.key < $1.key }
        .map { "\($0.key) × \($0.value)" }
        .joined(separator: ", ")
      if !models.isEmpty { parts.append(models) }
      return parts.joined(separator: " · ")
    }
  }

  /// The bottom bar: the run's state, and the way back into its pages.
  ///
  /// It is the one surface that survives the overlay being closed (8.1), so it reports
  /// the run — running or not, the step it is on, how far it got, how many failures it
  /// carries — and it reopens the overlay WHEREVER THE RUN IS NOW, because the overlay
  /// derives its rail and its page from the run rather than from where it was left.
  struct WorkspaceStatusBar: View {
    let workspace: Workspace

    var body: some View {
      HStack(spacing: 10) {
        Group {
          if workspace.status.isRunning {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
          }
        }
        .frame(width: 16)
        Text(workspace.status.summary).font(.callout).monospacedDigit()
        Spacer()
        if !workspace.isOverlayPresented {
          Button {
            workspace.reopenOverlay()
          } label: {
            Label("Show run", systemImage: "chevron.up")
          }
          .help("Reopen the run's pages where the run is now")
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 28)
      .background(.bar)
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
  struct RunBinding {
    let run: Run
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

    /// Prelearn's pages: a source and the machine version being produced for a slot a
    /// human already settled. It is never a translation anybody reads (4.1).
    var prelearn: [VerticalPrelearn.Operations] {
      batches(.prelearn).map { batch in
        VerticalPrelearn.Operations(
          language: batch.language ?? "",
          items: batch.items.map { item in
            VerticalPrelearn.Operation(
              key: item.key,
              index: position(item.key),
              comment: item.comment,
              source: item.source,
              machine: machine(item))
          },
          isCompleted: batch.phase == .applied,
          isFailed: batch.phase == .failed)
      }
    }

    /// Learn's pages: the difference between what the model produced and what the human
    /// settled on, and the document line each one becomes (4.1).
    var learn: [VerticalLearn.Operations] {
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
              target: target(item))
          },
          isCompleted: batch.phase == .applied,
          isFailed: batch.phase == .failed)
      }
    }

    /// The column pages: one page per language batch, its items in the run's order.
    var vertical: [VerticalTranslate.Operations] {
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
              target: target(item))
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
    var rows: [HorizontalTranslate.Operations] {
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
              })
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
