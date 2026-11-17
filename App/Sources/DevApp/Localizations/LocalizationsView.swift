//
//  LocalizationsView.swift
//  Dev
//
//  The Translations tool: every v57 app's strings in the translations repository. The list is the progress: a card
//  for what runs now (or what to do next), then the apps' and the kits' sources, each saying where it is in the run.
//  The Overview holds the coverage, the three steps (Scan, Translate, Build and Commit), the recent runs and the
//  setup; a source's page shows its run live, or its languages and problems. Design: the ComponentKit canvas, Dev
//  page, "Translations" row (Ideas/ComponentKit/translations-boards).
//

import ComponentKit
import SwiftUI

/// The Translations row in Dev's sidebar: the ring and the one line say what the tool is doing from any other tool.
struct LocalizationsSidebarRow: View {
  private var store: LocalizationsStore { .shared }

  var body: some View {
    SidebarRow(value: SidebarSelection.translations, "Translations", systemImage: "globe", status: store.workStatus) {
      if let fraction = store.jobFraction, store.job != .scan {
        Text(fraction, format: .percent.precision(.fractionLength(0)))
          .kitFont(.caption)
          .monospacedDigit()
          .foregroundStyle(.kitSecondary)
      } else if let finished = store.finishedTranslate, finished.failures + finished.failedSources > 0 {
        Count(finished.failures + finished.failedSources, .attention)
      }
    }
    .subtitle { LocalizationsLine(compact: true) }
    .kitHelp(
      String(localized: "Translations"), meta: store.activity.map { "\($0)" } ?? String(localized: "Every app's strings in the translations repository"),
      systemImage: "globe")
  }
}

/// One line on what the tool is doing: the sidebar row's subtitle and the run card's meta.
private struct LocalizationsLine: View {
  var compact = false
  private var store: LocalizationsStore { .shared }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      line(now: context.date)
    }
  }

  @ViewBuilder private func line(now: Date) -> some View {
    switch store.job {
    case .translate:
      if let until = store.providerWaitUntil {
        Text("Provider busy · again in \(LocalizationsStore.duration(max(1, until.timeIntervalSince(now))))")
      } else {
        let position = store.jobPosition
        let left = store.jobRemaining(now: now).map { String(localized: " · \(LocalizationsStore.duration($0)) left") } ?? ""
        Text("\(store.current ?? "") · \(position.index) of \(position.count)\(left)")
      }
    case .scan:
      if let app = store.current {
        Text("Building \(app) · \(store.scanIndex + 1) of \(store.scanTotal) apps")
      } else {
        Text("Writing catalogs")
      }
    case .build:
      if let source = store.current {
        Text("Committing \(source) · \(store.queue.firstIndex(of: source).map { $0 + 1 } ?? 1) of \(store.queue.count)")
      } else {
        Text("Running Scripts/build")
      }
    case nil:
      if let finished = store.finishedTranslate {
        Text(finished.failures + finished.failedSources > 0
          ? "Translated \(finished.done.formatted()) · \(finished.failures + finished.failedSources) failed"
          : "Translated \(finished.done.formatted())")
      } else if store.repoURL == nil {
        Text("No repository")
      } else if store.needingWork.isEmpty {
        Text("Every source translated")
      } else {
        Text(compact
          ? "\(store.needingWork.count) of \(store.plannedNames.count) need work"
          : "\(store.needingWork.count) of \(store.plannedNames.count) sources need work")
      }
    }
  }
}

struct LocalizationsView: View {
  @Environment(Translation.Shell.self) private var shell
  /// The source shown, "" for the overview.
  @State private var selected: String? = ""
  @State private var addingLanguages = false
  @State private var editingApps = false
  private var store: LocalizationsStore { .shared }

  var body: some View {
    ResizableSplit("translations.listWidth", pane: .leading, width: 300, range: 260...400, mainMinWidth: 460) {
      Group {
        if store.repoURL == nil {
          EmptyState(
            systemImage: "globe", title: "No Translations Repository",
            message: "Choose the checkout of v57/Localizations: one String Catalog per app and kit."
          ) {
            Button("Choose…") { store.chooseRepo() }.buttonStyle(.kitPrimary)
          }
        } else if let name = selected, !name.isEmpty {
          LocalizationsSourcePage(name: name)
            .id(name)
        } else {
          LocalizationsOverview(addingLanguages: $addingLanguages, editingApps: $editingApps)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } pane: {
      sourceList
    }
    .toolbar {
      KitToolbarItem(placement: .primaryAction) {
        ToolGroup {
          if store.isBusy {
            Button("Stop", systemImage: "stop.fill") { store.cancel() }
              .kitHelp("Stop", meta: "Stop the build or the run; what's done is kept", systemImage: "stop.fill")
          } else {
            Button("Scan All", systemImage: "text.magnifyingglass") { store.scan() }
              .disabled(store.repoURL == nil)
              .kitHelp("Scan All", meta: "Build every included app with string extraction on and update the catalogs", systemImage: "text.magnifyingglass")
            Button("Build and Commit", systemImage: "checkmark.seal") { store.buildAndCommit() }
              .disabled(store.repoURL == nil)
              .kitHelp("Build and Commit", meta: "Run Scripts/build, then commit each source that changed", systemImage: "checkmark.seal")
            Button("Translate All", systemImage: "play.fill") { store.translate(shell: shell) }
              .disabled(store.needingWork.isEmpty)
              .kitHelp("Translate All", meta: "Translate every source that needs it into every language, one after the other", systemImage: "play.fill")
          }
        }
      }
    }
    .kitSheet(isPresented: $addingLanguages) {
      LocalizationsLanguagesSheet()
    }
    .kitSheet(isPresented: $editingApps) {
      LocalizationsAppsSheet()
    }
    .kitNotice(
      "Translations", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.dismissError() } }),
      message: store.error.map { "\($0)" })
    .task { store.refreshProgress() }
    #if DEBUG
      .onChange(of: store.debugShow, initial: true) { _, show in
        if let show { selected = show }
      }
    #endif
  }

  private var sourceList: some View {
    let names = store.sourceNames
    let apps = names.filter { store.source($0)?.kind == .app }
    let kits = names.filter { store.source($0)?.kind == .kit }
    let others = names.filter { store.source($0) == nil }
    return KitList(selection: $selected) {
      LocalizationsJobCard()
      SidebarRow(value: "", "Overview", systemImage: "square.grid.2x2")
      if !apps.isEmpty {
        KitSection("Apps", meta: sectionMeta(apps, kind: .app), systemImage: "app", hue: .blue) {
          ForEach(apps, id: \.self) { LocalizationsSourceRow(name: $0) }
        }
      }
      if !kits.isEmpty {
        KitSection("Kits", meta: sectionMeta(kits, kind: .kit), systemImage: "shippingbox", hue: .purple) {
          ForEach(kits, id: \.self) { LocalizationsSourceRow(name: $0) }
        }
      }
      if !others.isEmpty {
        KitSection("Not in a Scan", meta: String(localized: "No included app makes these"), systemImage: "questionmark.folder", hue: .gray) {
          ForEach(others, id: \.self) { LocalizationsSourceRow(name: $0) }
        }
      }
    }
    .kitPane(.secondary)
  }

  private func sectionMeta(_ names: [String], kind: LocalizationsSource.Kind) -> String {
    let count = kind == .app ? String(localized: "\(names.count) apps") : String(localized: "\(names.count) kits")
    switch store.job ?? store.lastJob {
    case .translate where !store.queue.isEmpty:
      let done = names.filter {
        switch store.sourceStates[$0] {
        case .translated, .upToDate: true
        default: false
        }
      }.count
      let waiting = names.filter { store.sourceStates[$0] == .waiting }.count
      var parts = [count, String(localized: "\(done) done")]
      if store.job != nil, waiting > 0 { parts.append(String(localized: "\(waiting) waiting")) }
      return parts.joined(separator: " · ")
    case .build where !store.queue.isEmpty:
      let committed = names.filter { if case .committed = store.sourceStates[$0] { true } else { false } }.count
      return "\(count) · " + String(localized: "\(committed) committed")
    default:
      let finished = names.filter { store.progress[$0] != nil && store.missing($0) == 0 }.count
      return "\(count) · " + String(localized: "\(finished) translated")
    }
  }
}

// MARK: - The job card

/// The list's first card: the job running (its bar, totals and Stop), the finished run's outcome, or what to do next.
private struct LocalizationsJobCard: View {
  @Environment(Translation.Shell.self) private var shell
  private var store: LocalizationsStore { .shared }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      card(now: context.date)
    }
  }

  @ViewBuilder private func card(now: Date) -> some View {
    switch store.job {
    case .translate: translating(now: now)
    case .scan: scanning
    case .build: building
    case nil:
      if let finished = store.finishedTranslate {
        finishedCard(finished)
      } else {
        ready
      }
    }
  }

  @ViewBuilder private func translating(now: Date) -> some View {
    let waiting = store.providerWaitUntil
    let fraction = store.jobFraction ?? 0
    KitSection(
      waiting == nil ? (store.queue.count > 1 ? String(localized: "Translate All") : String(localized: "Translating"))
        : String(localized: "Waiting for the provider"),
      systemImage: waiting == nil ? "globe" : "clock", hue: .accent, status: store.workStatus
    ) {
      VStack(alignment: .leading, spacing: 6) {
        KitProgressBar(value: fraction, hue: waiting == nil ? .accent : .gray)
        if let waiting {
          note("\(store.liveModel ?? String(localized: "The model")) is parked; it's asked again in \(LocalizationsStore.duration(max(1, waiting.timeIntervalSince(now)))).")
          note(String(localized: "Nothing is lost: \(store.current ?? "") picks up where it stopped."))
        } else {
          let left = store.jobRemaining(now: now).map { String(localized: " · about \(LocalizationsStore.duration($0)) left") } ?? ""
          note(String(localized: "\(store.jobDone.formatted()) of \(store.plannedStrings.formatted()) strings\(left)"))
          let elapsed = store.jobStartedAt.map { LocalizationsStore.duration(now.timeIntervalSince($0)) } ?? ""
          let failures = store.jobFailures > 0 ? String(localized: " · \(store.jobFailures) failed") : ""
          note(String(localized: "\(store.jobRequests.formatted()) requests · \(LocalizationsStore.count(store.jobTokens)) tokens · \(elapsed)\(failures)"))
        }
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
    } meta: {
      LocalizationsLine()
    } accessory: {
      stop
    }
  }

  private var scanning: some View {
    KitSection(String(localized: "Scanning"), systemImage: "text.magnifyingglass", hue: .accent, status: store.workStatus) {
      VStack(alignment: .leading, spacing: 6) {
        KitProgressBar(value: store.jobFraction ?? 0)
        note(String(localized: "Each app is built with string extraction on, at low priority."))
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
    } meta: {
      LocalizationsLine()
    } accessory: {
      stop
    }
  }

  private var building: some View {
    KitSection(String(localized: "Build and Commit"), systemImage: "checkmark.seal", hue: .accent, status: store.workStatus) {
      VStack(alignment: .leading, spacing: 6) {
        if let fraction = store.jobFraction {
          KitProgressBar(value: fraction)
        } else {
          KitProgressBar(status: .working())
        }
        note(String(localized: "One commit per source. Nothing is pushed."))
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
    } meta: {
      LocalizationsLine()
    } accessory: {
      stop
    }
  }

  private func finishedCard(_ finished: (done: Int, failures: Int, failedSources: Int, sources: Int)) -> some View {
    let failed = store.sourcesWithFailures
    let problems = finished.failures > 0 || finished.failedSources > 0
    let elapsed = store.jobStartedAt.flatMap { start in store.jobFinishedAt.map { LocalizationsStore.duration($0.timeIntervalSince(start)) } }
    var meta: [String] = []
    if finished.failedSources > 0 {
      meta.append(finished.failedSources == 1 ? String(localized: "1 source failed") : String(localized: "\(finished.failedSources) sources failed"))
    }
    if finished.failures > 0 { meta.append(String(localized: "\(finished.failures) batches failed")) }
    return KitSection(
      String(localized: "Translation finished"), systemImage: problems ? "exclamationmark.triangle" : "checkmark",
      hue: problems ? .orange : .green, status: .idle
    ) {
      VStack(alignment: .leading, spacing: 6) {
        if finished.sources == 0, !problems {
          note(String(localized: "Nothing was left to translate."))
        } else {
          let sources = finished.sources == 1 ? String(localized: "1 source") : String(localized: "\(finished.sources) sources")
          note(String(localized: "\(finished.done.formatted()) strings in \(sources)\(elapsed.map { " · \($0)" } ?? "")"))
          note(String(localized: "\(store.jobRequests.formatted()) requests · \(LocalizationsStore.count(store.jobTokens)) tokens"))
        }
        HStack(spacing: 6) {
          if !failed.isEmpty {
            Button(failed.count == 1 ? "Retry \(failed[0])" : "Retry \(failed.count) Sources", systemImage: "arrow.clockwise") {
              store.translate(failed, shell: shell)
            }
          }
          if finished.done > 0 {
            Button("Build and Commit") { store.buildAndCommit() }
              .buttonStyle(.kitPrimary)
          }
        }
        .padding(.top, 2)
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
    } meta: {
      Text(problems ? meta.joined(separator: " · ") : String(localized: "Nothing failed"))
        .foregroundStyle(problems ? AnyShapeStyle(Hue.orange.text) : AnyShapeStyle(.kitSecondary))
    } accessory: {
      EmptyView()
    }
  }

  private var ready: some View {
    let total = store.totalSlots
    let translated = store.totalTranslated
    let missing = store.totalMissing
    let fraction = total > 0 ? Double(translated) / Double(total) : 0
    let needing = store.needingWork
    return KitSection(
      String(localized: "\(min(fraction, missing > 0 ? 0.99 : 1).formatted(.percent.precision(.fractionLength(0)))) translated"), systemImage: "globe",
      hue: .accent, status: .idle
    ) {
      VStack(alignment: .leading, spacing: 6) {
        KitProgressBar(value: fraction, hue: missing == 0 ? .green : .accent)
        note(String(localized: "\(translated.formatted()) of \(total.formatted()) strings in \(store.languages.count) languages"))
        if missing > 0 {
          note(String(localized: "\(missing.formatted()) to go · about \(LocalizationsStore.duration(store.estimate(missing))), \(LocalizationsStore.count(store.tokenEstimate(missing))) tokens"))
          Button(needing.count == 1 ? "Translate 1 Source" : "Translate \(needing.count) Sources", systemImage: "play.fill") {
            store.translate(needing, shell: shell)
          }
          .buttonStyle(.kitPrimary)
          .padding(.top, 2)
        }
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
    } meta: {
      Text("\(store.plannedNames.count - needing.count) of \(store.plannedNames.count) sources done")
    } accessory: {
      EmptyView()
    }
  }

  private var stop: some View {
    Button("Stop", systemImage: "stop.fill") { store.cancel() }
      .labelStyle(.iconOnly)
      .foregroundStyle(Hue.red.text)
      .kitHelp("Stop", meta: "What's done is kept; a new run picks up where this one stopped", systemImage: "stop.fill")
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .kitFont(.caption)
      .monospacedDigit()
      .foregroundStyle(.kitSecondary)
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: - A source's row

/// A source in the list: its ring and line say where it is in the job, or how far it is translated.
private struct LocalizationsSourceRow: View {
  let name: String
  private var store: LocalizationsStore { .shared }

  var body: some View {
    let source = store.source(name)
    let state = store.sourceStates[name]
    SidebarRow(
      value: name, name, systemImage: source?.kind == .kit ? "shippingbox" : "app", hue: source == nil ? .gray : nil,
      status: status(state)
    ) {
      trailing(state)
    }
    .subtitle { subtitle(state, source: source) }
  }

  private func status(_ state: LocalizationsSourceState?) -> WorkStatus {
    switch state {
    case .translating:
      if store.providerWaitUntil != nil { return .paused(progress: store.liveRun?.estimate?.fraction) }
      return .working(progress: store.liveRun?.estimate?.fraction)
    case .committing: return .working()
    case .failed(let message): return .failed(message)
    case .waiting: return .waiting
    default: return .idle
    }
  }

  @ViewBuilder private func trailing(_ state: LocalizationsSourceState?) -> some View {
    switch state {
    case .translating:
      if let fraction = store.liveRun?.estimate?.fraction { percent(fraction) }
    case .waiting:
      if let position = store.queuePosition(name) { StepNumber(position) }
    case .translated(let record):
      if record.failures > 0 { Count(record.failures, .attention) } else { check }
    case .upToDate, .committed: check
    case .failed, .stopped, .committing: EmptyView()
    case nil:
      if store.progress[name] != nil {
        if store.missing(name) == 0 { check } else { percent(min(store.fraction(name), 0.99)) }
      }
    }
  }

  @ViewBuilder private func subtitle(_ state: LocalizationsSourceState?, source: LocalizationsSource?) -> some View {
    switch state {
    case .translating:
      if let run = store.liveRun {
        Text(LocalizationsRunText.stageLine(run, languages: store.languages.count))
          .foregroundStyle(Hue.accent.text)
      } else {
        Text("Opening the catalog")
      }
    case .waiting:
      let missing = store.missing(name)
      if store.job == .build {
        Text("Waiting")
      } else if missing > 0 {
        Text("\(missing.formatted()) strings · about \(LocalizationsStore.duration(store.estimate(missing)))")
      } else {
        Text("Up to date, checked when its turn comes")
      }
    case .upToDate: Text("Up to date")
    case .translated(let record):
      if record.failures > 0 {
        Text("\(record.done.formatted()) translated · \(record.failures) batches failed").foregroundStyle(Hue.orange.text)
      } else {
        Text("\(record.done.formatted()) translated · \(LocalizationsStore.duration(record.seconds))")
      }
    case .failed(let message): Text(message).foregroundStyle(Hue.red.text)
    case .stopped: Text("Stopped before its turn")
    case .committing: Text("Committing")
    case .committed(let hash): Text("Committed \(hash)")
    case nil:
      if let progress = store.progress[name] {
        let missing = store.missing(name)
        if missing == 0 {
          Text("\(progress.keys.formatted()) strings")
        } else if store.translatedSlots(name) == 0 {
          Text("\(progress.keys.formatted()) strings · not translated")
        } else {
          Text("\(missing.formatted()) missing")
        }
      } else if source == nil {
        Text("No scanned app uses it")
      }
    }
  }

  private var check: some View {
    Image(systemName: "checkmark")
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(Hue.green.text)
      .accessibilityLabel("Translated")
  }

  private func percent(_ value: Double) -> some View {
    Text(value, format: .percent.precision(.fractionLength(0)))
      .kitFont(.caption)
      .monospacedDigit()
      .foregroundStyle(.kitSecondary)
  }
}

/// Words a run's state reads as, shared by the list and the source page.
@MainActor
enum LocalizationsRunText {
  /// "Translate · 60 of 95 languages", "Check by row · 12 of 40", "Prepare".
  static func stageLine(_ run: Translation.Run, languages: Int) -> String {
    guard let operation = run.operation else {
      return run.state == .finished ? String(localized: "Saving") : String(localized: "Starting")
    }
    switch operation {
    case .prepare:
      return String(localized: "Prepare")
    case .vertical:
      let done = languagesDone(run).count
      return String(localized: "Translate · \(done) of \(languages) languages")
    case .horizontal:
      let batches = run.batches.filter { $0.stage == .horizontal }
      let landed = batches.filter { $0.phase == .applied || $0.phase == .failed }.count
      return String(localized: "Check by row · \(landed) of \(batches.count)")
    }
  }

  /// The languages whose column batches have all landed.
  static func languagesDone(_ run: Translation.Run) -> Set<String> {
    let batches = run.batches.filter { $0.stage == .vertical }
    let byLanguage = Dictionary(grouping: batches) { $0.language ?? "" }
    return Set(byLanguage.compactMap { language, batches in
      batches.allSatisfy { $0.phase == .applied || $0.phase == .failed } ? language : nil
    })
  }
}

// MARK: - Overview

private struct LocalizationsOverview: View {
  @Binding var addingLanguages: Bool
  @Binding var editingApps: Bool
  @Environment(Translation.Shell.self) private var shell
  @State private var modelLine = ""
  private var store: LocalizationsStore { .shared }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        coverage
        steps
        HStack(alignment: .top, spacing: KitMetrics.gutter) {
          recent.frame(maxWidth: .infinity, alignment: .top)
          setup.frame(maxWidth: .infinity, alignment: .top)
        }
        if !store.log.isEmpty {
          FormCard("Log") {
            ScrollView {
              Text(store.log.suffix(200).joined(separator: "\n"))
                .kitFont(.caption)
                .monospaced()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: 200)
          }
        }
      }
      .padding(KitMetrics.gutter)
    }
    .kitPane()
    .onAppear {
      let model = RoutedModel.current
      let effort = ModelSettings.reasoningEffort.map { String(localized: "\($0.capitalized) reasoning") } ?? String(localized: "the provider's reasoning")
      modelLine = model.map { String(localized: "\($0.name) on \($0.providerName), \(effort)") } ?? String(localized: "None chosen")
    }
  }

  // MARK: coverage

  private var coverage: some View {
    let names = store.plannedNames.filter { store.progress[$0] != nil }
    let done = names.filter { store.missing($0) == 0 }
    let partly = names.filter { store.missing($0) > 0 && store.translatedSlots($0) > 0 }
    let total = store.totalSlots
    let fraction = total > 0 ? Double(store.totalTranslated) / Double(total) : 0
    let doneSlots = done.reduce(0) { $0 + store.slots($1) }
    let partlySlots = partly.reduce(0) { $0 + store.translatedSlots($1) }
    let segments = [
      MeterSegment(
        String(localized: "\(done.count) sources done"), value: Double(doneSlots), hue: .green,
        valueText: doneSlots.formatted()),
      MeterSegment(
        String(localized: "\(partly.count) partly"), value: Double(partlySlots), hue: .accent,
        valueText: partlySlots.formatted()),
    ]
    let free = MeterSegment(
      String(localized: "\(names.count - done.count - partly.count) not started · \(store.totalMissing.formatted()) strings to go"),
      value: Double(store.totalMissing), hue: .gray, valueText: store.totalMissing.formatted())
    return HStack(alignment: .bottom, spacing: 18) {
      VStack(alignment: .leading, spacing: 2) {
        Text(min(fraction, store.totalMissing > 0 ? 0.99 : 1), format: .percent.precision(.fractionLength(0)))
          .font(.system(size: 30, weight: .bold))
          .monospacedDigit()
        Text("of every app's strings, in \(store.languages.count) languages")
          .kitFont(.caption)
          .foregroundStyle(.kitSecondary)
      }
      VStack(alignment: .leading, spacing: 6) {
        MeterBar(segments: segments, total: Double(max(1, total)), height: 8)
        MeterLegend(segments: segments, free: free)
      }
      .padding(.bottom, 2)
    }
  }

  // MARK: the three steps

  private enum Step { case scan, translate, build }

  private var next: Step {
    let unscanned = store.apps.contains { $0.included && store.state.scans[$0.name] == nil }
    if unscanned { return .scan }
    return store.needingWork.isEmpty ? .build : .translate
  }

  private var steps: some View {
    let needing = store.needingWork
    let missing = store.totalMissing
    let lastScan = store.state.scans.values.map(\.date).max()
    let included = store.apps.filter(\.included)
    let strings = store.plannedNames.reduce(0) { $0 + (store.progress[$1]?.keys ?? 0) }
    return HStack(alignment: .top, spacing: 12) {
      stepCard(1, "Scan", step: .scan, done: lastScan != nil) {
        if let lastScan {
          Text("Built \(included.count) apps on \(lastScan.formatted(date: .abbreviated, time: .omitted)) and found **\(strings.formatted()) strings** in \(store.plannedNames.count) sources. Scan again after changing an app's text.")
        } else {
          Text("Builds each included app with string extraction on and writes a catalog per app and kit.")
        }
      } action: {
        Button("Scan All", systemImage: "text.magnifyingglass") { store.scan() }
          .disabled(store.isBusy)
      }
      stepCard(2, "Translate", step: .translate, done: needing.isEmpty) {
        if needing.isEmpty {
          Text("Every source is translated into all \(store.languages.count) languages.")
        } else {
          Text("**\(needing.count) sources** need work: **\(missing.formatted()) strings**. About \(LocalizationsStore.duration(store.estimate(missing))) and \(LocalizationsStore.count(store.tokenEstimate(missing))) tokens; stop at any time and keep what's done.")
        }
      } action: {
        Button(needing.count == 1 ? "Translate 1 Source" : "Translate \(needing.count) Sources", systemImage: "play.fill") {
          store.translate(needing, shell: shell)
        }
        .buttonStyle(.kitPrimary)
        .disabled(store.isBusy || needing.isEmpty)
      }
      stepCard(3, "Build and Commit", step: .build, done: false) {
        Text("Scripts/build compiles every catalog, then **one commit per source** that changed. Nothing is pushed.")
      } action: {
        Button("Build and Commit", systemImage: "checkmark.seal") { store.buildAndCommit() }
          .disabled(store.isBusy)
      }
    }
  }

  private func stepCard<Body: View, Action: View>(
    _ number: Int, _ title: LocalizedStringKey, step: Step, done: Bool, @ViewBuilder body: () -> Body,
    @ViewBuilder action: () -> Action
  ) -> some View {
    let isNext = next == step && !store.isBusy
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        StepNumber(number, isCurrent: isNext)
        Text(title).kitFont(.headline)
        Spacer(minLength: 0)
        if isNext {
          Chip("Next", hue: .accent)
        } else if done {
          Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Hue.green.text)
        }
      }
      body()
        .kitFont(.caption)
        .foregroundStyle(.kitSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Spacer(minLength: 0)
      action()
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .kitSurface(.card)
    .overlay {
      if isNext {
        RoundedRectangle(cornerRadius: KitMetrics.radiusCard).strokeBorder(Hue.accent.fill, lineWidth: 2)
      }
    }
  }

  // MARK: recent runs and setup

  private var recent: some View {
    let records = Array(store.records.suffix(6).reversed())
    return FormCard("Recent Runs") {
      if records.isEmpty {
        FormRow("No runs yet", help: "A run's figures show here when it ends.", systemImage: "clock", hue: .gray)
      }
      ForEach(records) { record in
        FormRow(
          record.source, help: recordLine(record), systemImage: record.failures > 0 ? "exclamationmark.triangle" : "checkmark",
          hue: record.failures > 0 ? .orange : .green)
      }
    }
  }

  private func recordLine(_ record: LocalizationsRunRecord) -> String {
    var parts = [record.date.formatted(date: .abbreviated, time: .shortened)]
    parts.append(record.done == record.items ? record.done.formatted() : String(localized: "\(record.done.formatted()) of \(record.items.formatted())"))
    if record.failures > 0 { parts.append(String(localized: "\(record.failures) batches failed")) }
    if record.corrected > 0 { parts.append(String(localized: "\(record.corrected) corrected by row")) }
    parts.append(LocalizationsStore.duration(record.seconds))
    parts.append(String(localized: "\(LocalizationsStore.count(record.tokens)) tokens"))
    return parts.joined(separator: " · ")
  }

  private var setup: some View {
    let included = store.apps.filter(\.included)
    let excluded = store.apps.filter { !$0.included }.map(\.name)
    return FormCard("Setup") {
      FormRow("Repository", help: store.repoURL.map { "\($0.path)" } ?? "", systemImage: "folder") {
        Button("Choose…") { store.chooseRepo() }
      }
      FormRow(
        "Apps", help: excluded.isEmpty ? String(localized: "\(included.count) included") : String(localized: "\(included.count) of \(store.apps.count) included; \(excluded.joined(separator: ", ")) off"),
        systemImage: "app"
      ) {
        Button("Edit…") { editingApps = true }
      }
      FormRow(
        "Languages", help: String(localized: "\(store.languages.count): \(store.languages.prefix(8).joined(separator: ", "))\(store.languages.count > 8 ? "…" : "")"),
        systemImage: "globe"
      ) {
        Button("Edit…") { addingLanguages = true }
      }
      FormRow(
        "Shipped Translations", help: store.importedDatabase.map { "\($0.lastPathComponent): exact matches fill first" } ?? String(localized: "None: every string goes to the model"),
        systemImage: "externaldrive"
      ) {
        Button("Import…") { store.importDatabase() }
          .disabled(store.isBusy)
      }
      FormRow("Model", help: modelLine, systemImage: "sparkles")
    }
  }
}

// MARK: - One source

/// A source's page: its run live while it translates, else its coverage, its problems and its languages.
private struct LocalizationsSourcePage: View {
  let name: String
  private var store: LocalizationsStore { .shared }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if store.job == .translate, store.sourceStates[name] == .translating {
          LocalizationsLiveRun(name: name)
        } else {
          LocalizationsSourceSummary(name: name)
        }
      }
      .padding(KitMetrics.gutter)
    }
    .kitPane()
  }
}

/// The page's top line: the source's icon, name and what it is doing.
private struct LocalizationsSourceHeader<Trailing: View>: View {
  let name: String
  var status: WorkStatus = .idle
  var hue: Hue = .accent
  let line: String
  @ViewBuilder var trailing: Trailing
  private var store: LocalizationsStore { .shared }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      LiveIcon(
        systemImage: store.source(name)?.kind == .kit ? "shippingbox" : "app", hue: hue, status: status, size: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text(name).kitFont(.title1)
        Text(line)
          .kitFont(.caption)
          .monospacedDigit()
          .foregroundStyle(.kitSecondary)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      trailing
    }
  }
}

/// A source while it translates: its bar, the three stages, the languages and the requests in flight.
private struct LocalizationsLiveRun: View {
  let name: String
  private var store: LocalizationsStore { .shared }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      content(now: context.date)
    }
  }

  @ViewBuilder private func content(now: Date) -> some View {
    if let run = store.liveRun {
      let estimate = run.estimate
      let waiting = store.providerWaitUntil
      VStack(alignment: .leading, spacing: 16) {
        LocalizationsSourceHeader(
          name: name, status: waiting == nil ? .working(progress: estimate?.fraction) : .paused(progress: estimate?.fraction),
          line: line(run, waiting: waiting, now: now)
        ) {
          Button("Stop", systemImage: "stop.fill") { store.cancel() }
            .kitHelp("Stop", meta: "What's done is kept; a new run picks up where this one stopped", systemImage: "stop.fill")
        }
        KitProgressBar(value: estimate?.fraction ?? 0, hue: waiting == nil ? .accent : .gray)
        stages(run)
        languages(run)
        batches(run)
        StatusBar(systemImage: "sparkles", status: waiting == nil ? .working() : .paused(), alignment: .leading) {
          Text(store.liveModel ?? String(localized: "Starting"))
          Text("\(run.tally.requests.formatted()) requests")
            .foregroundStyle(.kitSecondary)
          Text("\(LocalizationsStore.count(run.tally.promptTokens + run.tally.completionTokens)) tokens")
            .foregroundStyle(.kitSecondary)
          if run.tally.cachedTokens > 0 {
            Text("\(run.tally.cachedShare.formatted(.percent.precision(.fractionLength(0)))) cached")
              .foregroundStyle(.kitSecondary)
          }
          if !run.failures.isEmpty {
            Count(run.failures.count, .attention)
          }
        }
        .padding(.horizontal, -KitMetrics.gutter)
      }
    } else {
      LocalizationsSourceHeader(name: name, status: .working(), line: String(localized: "Opening the catalog")) {
        EmptyView()
      }
    }
  }

  private func line(_ run: Translation.Run, waiting: Date?, now: Date) -> String {
    if let waiting {
      return String(localized: "The provider is busy; asked again in \(LocalizationsStore.duration(max(1, waiting.timeIntervalSince(now)))). Nothing is lost.")
    }
    var parts = [String(localized: "\(run.tally.items.formatted()) strings into \(store.languages.count) languages")]
    if let started = run.startedAt { parts.append(LocalizationsStore.duration(now.timeIntervalSince(started))) }
    if let remaining = store.liveRemaining(now: now) { parts.append(String(localized: "about \(LocalizationsStore.duration(remaining)) left")) }
    return parts.joined(separator: " · ")
  }

  // MARK: stages

  private func stages(_ run: Translation.Run) -> some View {
    HStack(alignment: .top, spacing: 10) {
      ForEach(Array(run.operations.enumerated()), id: \.offset) { index, stage in
        let status: WorkStatus =
          index < run.operationIndex || run.state == .finished ? .done
          : index == run.operationIndex ? .working() : .idle
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            LiveIcon(systemImage: icon(stage), hue: status == .idle ? .gray : .accent, status: status, size: 22)
            Text(title(stage)).kitFont(.headline)
          }
          Text(detail(stage, run: run, status: status))
            .kitFont(.caption)
            .monospacedDigit()
            .foregroundStyle(.kitSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .kitSurface(.card)
        .overlay {
          if index == run.operationIndex, run.state != .finished {
            RoundedRectangle(cornerRadius: KitMetrics.radiusCard).strokeBorder(Hue.accent.fill, lineWidth: 2)
          }
        }
      }
    }
  }

  private func icon(_ stage: Translation.Stage) -> String {
    switch stage {
    case .prepare: "tray.full"
    case .vertical: "globe"
    case .horizontal: "checklist"
    }
  }

  private func title(_ stage: Translation.Stage) -> String {
    switch stage {
    case .prepare: String(localized: "Prepare")
    case .vertical: String(localized: "Translate")
    case .horizontal: String(localized: "Check by Row")
    }
  }

  private func detail(_ stage: Translation.Stage, run: Translation.Run, status: WorkStatus) -> String {
    let batches = run.batches.filter { $0.stage == stage }
    let landed = batches.filter { $0.phase == .applied || $0.phase == .failed }.count
    switch stage {
    case .prepare:
      let filled = run.tally.resolved[.prepare] ?? 0
      return status == .idle ? String(localized: "Fills what memory and shipped translations know")
        : String(localized: "\(filled.formatted()) filled from memory and shipped translations")
    case .vertical:
      if status == .idle { return String(localized: "One language per request, four at once") }
      let done = LocalizationsRunText.languagesDone(run).count
      return String(localized: "\(done) of \(store.languages.count) languages · \(landed) of \(batches.count) requests")
    case .horizontal:
      if status == .idle { return String(localized: "Reads each string across the languages and corrects what disagrees") }
      return String(localized: "\(landed) of \(batches.count) requests · \((run.tally.byStage[.horizontal] ?? 0).formatted()) corrected")
    }
  }

  // MARK: languages

  private func languages(_ run: Translation.Run) -> some View {
    let batches = run.batches.filter { $0.stage == .vertical }
    let byLanguage = Dictionary(grouping: batches) { $0.language ?? "" }
    let started = run.operation != .prepare && run.operation != nil || run.state == .finished
    return VStack(alignment: .leading, spacing: 8) {
      Text("Languages").kitFont(.headline)
      KitFlowLayout(spacing: 5) {
        ForEach(store.languages, id: \.self) { code in
          let batches = byLanguage[code] ?? []
          let failed = batches.contains { $0.phase == .failed }
          let landed = batches.allSatisfy { $0.phase == .applied || $0.phase == .failed }
          let sent = batches.contains { $0.phase == .sent || $0.phase == .validated }
          if failed {
            Chip(code, systemImage: "exclamationmark.triangle", hue: .orange)
          } else if sent {
            Chip(code, hue: .accent, style: .solid)
          } else if started, landed {
            Chip(code, systemImage: "checkmark", hue: .green)
          } else {
            Chip(code, style: .quiet)
          }
        }
      }
    }
  }

  // MARK: requests

  @ViewBuilder private func batches(_ run: Translation.Run) -> some View {
    let inFlight = run.batches.filter { $0.phase == .sent || $0.phase == .validated }
    let landed = run.batches.filter { $0.phase == .applied || $0.phase == .failed }.suffix(4)
    let shown = inFlight + landed.reversed()
    if !shown.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Requests").kitFont(.headline)
        RunBlocks {
          ForEach(shown) { batch in
            RunBlock(
              batchName(batch), command: batchCommand(batch), id: batch.id, systemImage: icon(batch.stage),
              hue: batch.phase == .failed ? .orange : .accent, status: batchStatus(batch, run: run),
              progress: batch.attempt > 1 ? String(localized: "attempt \(batch.attempt)") : nil)
          }
        }
      }
    }
  }

  private func batchName(_ batch: Translation.Run.Batch) -> String {
    let code = batch.language ?? String(localized: "rows")
    let language = batch.language.flatMap { Locale.current.localizedString(forIdentifier: $0) }
    return [title(batch.stage), language.map { "\($0) (\(code))" } ?? code].joined(separator: " · ")
  }

  private func batchCommand(_ batch: Translation.Run.Batch) -> String {
    let strings = String(localized: "\(batch.items.count) strings")
    return batch.model.isEmpty ? strings : "\(strings) · \(batch.model)"
  }

  private func batchStatus(_ batch: Translation.Run.Batch, run: Translation.Run) -> WorkStatus {
    switch batch.phase {
    case .pending: .waiting
    case .sent, .validated: .working()
    case .applied: .done
    case .failed:
      .failed(run.failures.last { $0.language != nil && $0.language == batch.language }?.message ?? String(localized: "failed"))
    }
  }
}

/// A source between runs: how far it is, what went wrong last, the catalog and each language.
private struct LocalizationsSourceSummary: View {
  let name: String
  @Environment(Translation.Shell.self) private var shell
  /// Why a run can't start (no provider, no key): read once, it reads the keychain.
  @State private var problem: String?
  private var store: LocalizationsStore { .shared }

  var body: some View {
    let source = store.source(name)
    let progress = store.progress[name] ?? SourceProgress()
    let missing = store.missing(name)
    let fraction = store.fraction(name)
    let catalog = store.repoURL.map { LocalizationsRepo.catalog(name, in: $0) }
    let record = store.lastRecord(name)
    VStack(alignment: .leading, spacing: 16) {
      LocalizationsSourceHeader(name: name, hue: missing == 0 && progress.keys > 0 ? .green : .accent, line: headerLine(source, progress, fraction)) {
        Button(missing > 0 ? "Translate \(missing.formatted())" : "Translate", systemImage: "play.fill") {
          store.translate([name], shell: shell)
        }
        .buttonStyle(.kitPrimary)
        .disabled(store.isBusy || problem != nil)
        .kitHelp("Translate", meta: translateHelp(missing), systemImage: "play.fill")
      }
      KitProgressBar(value: fraction, hue: missing == 0 ? .green : .accent)
      if store.job == .translate, let position = store.queuePosition(name) {
        Banner(
          "Waiting its turn", message: String(localized: "Number \(position) in the queue; \(store.current ?? "") translates now."),
          systemImage: "clock", hue: .blue
        ) { EmptyView() }
      }
      if let record, record.failures > 0 {
        let languages = record.failedLanguages.isEmpty ? "" : String(localized: " in \(Set(record.failedLanguages).sorted().joined(separator: ", "))")
        Banner(
          String(localized: "\(record.failures) batches failed in the last run"),
          message: String(localized: "Their strings stayed empty\(languages). Translating again sends only those; what was done is kept."),
          systemImage: "exclamationmark.triangle", hue: .orange
        ) {
          Button("Retry", systemImage: "arrow.clockwise") { store.translate([name], shell: shell) }
            .disabled(store.isBusy)
        }
      }
      FormCard("Source") {
        FormRow(
          source?.kind == .kit ? "Kit" : source?.kind == .app ? "App" : "Not in the scan",
          help: kindHelp(source), systemImage: source?.kind == .app ? "app" : "shippingbox")
        FormRow(
          "\(progress.keys.formatted()) strings",
          help: progress.stale > 0 ? "\(progress.stale) stale (no longer in the code; kept, not translated)" : nil,
          systemImage: "text.quote")
        if let catalog {
          FormRow("Catalog", help: "\(catalog.lastPathComponent)", systemImage: "doc.text") {
            HStack(spacing: 8) {
              Button("Open in Xcode") { KitDesktop.open([catalog], withApp: "com.apple.dt.Xcode") }
              Button("Show in Finder") { KitDesktop.reveal([catalog]) }
            }
          }
        }
        FormRow(
          "About", help: aboutHelp, systemImage: "text.bubble", hue: .gray,
          field: TextField(
            "About", text: Binding(get: { store.description(of: name) }, set: { store.setDescription($0, of: name) }),
            prompt: Text(source?.kind == .kit ? "the shared controls of the apps" : "a code editor for Mac")))
        if let record {
          FormRow(
            "Last Run", help: recordLine(record), systemImage: record.failures > 0 ? "exclamationmark.triangle" : "clock",
            hue: record.failures > 0 ? .orange : .gray)
        }
      }
      FormCard("Languages", footer: missing > 0 ? "Least translated first." : nil) {
        ForEach(sortedLanguages(progress), id: \.self) { code in
          let done = min(progress.translated[code] ?? 0, progress.keys)
          let review = progress.needsReview[code] ?? 0
          let complete = done >= progress.keys && progress.keys > 0
          let shown = String(localized: "\(code) · \(done.formatted()) of \(progress.keys.formatted())")
          FormRow(
            "\(Locale.current.localizedString(forIdentifier: code) ?? code)",
            help: review > 0 ? shown + " · " + String(localized: "\(review) to review") : shown,
            systemImage: complete ? "checkmark.circle" : "globe", hue: complete ? .green : .accent
          ) {
            MicroBar(value: progress.fraction(code), hue: complete ? .green : .accent, width: 120)
          }
        }
      }
    }
    .onAppear { problem = ModelSettings.problem }
  }

  private func sortedLanguages(_ progress: SourceProgress) -> [String] {
    store.languages.enumerated().sorted { left, right in
      let a = progress.fraction(left.element)
      let b = progress.fraction(right.element)
      return a == b ? left.offset < right.offset : a < b
    }.map(\.element)
  }

  private func headerLine(_ source: LocalizationsSource?, _ progress: SourceProgress, _ fraction: Double) -> String {
    let kind = source?.kind == .kit ? String(localized: "Kit") : source?.kind == .app ? String(localized: "App") : String(localized: "Not in the scan")
    let missing = store.missing(name)
    var parts = [kind, String(localized: "\(progress.keys.formatted()) strings"), min(fraction, store.missing(name) > 0 ? 0.99 : 1).formatted(.percent.precision(.fractionLength(0)))]
    if missing > 0 {
      parts.append(String(localized: "\(missing.formatted()) to go, about \(LocalizationsStore.duration(store.estimate(missing)))"))
    }
    return parts.joined(separator: " · ")
  }

  private func translateHelp(_ missing: Int) -> String {
    if let problem { return problem }
    return String(localized: "Into \(store.languages.count) languages with the Localization tab's pipeline; the catalog is saved when the run ends")
  }

  /// What the model is told: the `About:` lines, as a translation writes them into the source's project rules.
  private var aboutHelp: String {
    let lines = store.about(name).map { String($0.dropFirst(LocalizationsStore.aboutPrefix.count)) }
    return lines.isEmpty
      ? String(localized: "What this is, in a phrase: the model is told, so it translates for this app.")
      : lines.joined(separator: "\n")
  }

  private func kindHelp(_ source: LocalizationsSource?) -> LocalizedStringKey {
    guard let source else { return "The repository has its catalog, but no included app's scan makes it" }
    let repo = URL(fileURLWithPath: source.repo).lastPathComponent
    switch source.kind {
    case .app: return "\(name)'s own strings (\(source.modules.joined(separator: ", ")))"
    case .kit: return "\(source.modules.joined(separator: ", ")) from \(repo), used by \(source.usedBy.joined(separator: ", "))"
    }
  }

  private func recordLine(_ record: LocalizationsRunRecord) -> String {
    var parts = [record.date.formatted(date: .abbreviated, time: .shortened)]
    parts.append(String(localized: "\(record.done.formatted()) of \(record.items.formatted()) translated"))
    if record.corrected > 0 { parts.append(String(localized: "\(record.corrected) corrected by row")) }
    parts.append(LocalizationsStore.duration(record.seconds))
    parts.append(String(localized: "\(LocalizationsStore.count(record.tokens)) tokens"))
    if record.stopped { parts.append(String(localized: "stopped")) }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Apps

/// The apps a scan builds: include or leave out each one, scan one, add one from elsewhere.
private struct LocalizationsAppsSheet: View {
  @Environment(\.kitDismiss) private var dismiss
  private var store: LocalizationsStore { .shared }

  var body: some View {
    KitSheet(
      title: "Apps", meta: "Scan builds each included app's -Local workspace with string extraction on. A kit another app links is a source of its own.",
      systemImage: "app", width: 620
    ) {
      ScrollView {
        FormCard {
          ForEach(store.apps) { app in
            FormRow(app.name, help: appHelp(app), systemImage: "app", hue: app.included ? .accent : .gray) {
              HStack(spacing: 8) {
                Button("Scan") { store.scan([app.name]) }
                  .disabled(store.isBusy)
                Toggle("Include", isOn: Binding(get: { app.included }, set: { store.setIncluded(app.name, $0) }))
                  .toggleStyle(.kitSwitch)
                  .labelsHidden()
              }
            }
          }
        }
        .padding(.horizontal, KitMetrics.gutter)
      }
      .frame(height: 380)
    } footer: {
      Button("Add App…") { store.chooseApp() }
        .disabled(store.isBusy)
      Spacer()
      Button("Done") { dismiss() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
    }
  }

  private func appHelp(_ app: LocalizationsApp) -> String {
    guard let scan = store.state.scans[app.name] else { return String(localized: "Not scanned yet") }
    let sources = store.plan.lookup[app.name] ?? []
    let strings = sources.isEmpty ? String(localized: "no strings") : sources.joined(separator: " → ")
    return String(localized: "Scanned \(scan.date.formatted(date: .abbreviated, time: .shortened)) · \(strings)")
  }
}

// MARK: - Languages

private struct LocalizationsLanguagesSheet: View {
  @Environment(\.kitDismiss) private var dismiss
  @State private var selection: Set<String> = []
  private var store: LocalizationsStore { .shared }

  /// What the Localization tab offers, plus the bundled defaults it spells differently.
  private var offered: [String] {
    let all = LocalizationStore.offeredLanguages.filter { $0 != "en" }
    return all + LocalizationsState.defaultLanguages.filter { !all.contains($0) }
  }

  var body: some View {
    KitSheet(
      title: "Languages", meta: "\(selection.count) selected. Every source is translated into these.",
      systemImage: "globe", width: 680
    ) {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .leading)], alignment: .leading,
          spacing: 7
        ) {
          ForEach(offered.sorted(), id: \.self) { code in
            Toggle(
              code,
              isOn: Binding(
                get: { selection.contains(code) },
                set: { if $0 { selection.insert(code) } else { selection.remove(code) } })
            )
            .toggleStyle(.kitCheckbox)
            .help(Locale(identifier: "en").localizedString(forIdentifier: code) ?? code)
          }
        }
        .padding(10)
      }
      .frame(height: 340)
      .padding(.horizontal, KitMetrics.gutter)
    } footer: {
      Button("Select All") { selection = Set(offered) }
      Button("Defaults") { selection = Set(LocalizationsState.defaultLanguages) }
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Save") {
        for code in store.languages where !selection.contains(code) { store.removeLanguage(code) }
        store.addLanguages(offered.filter { selection.contains($0) })
        dismiss()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
    }
    .onAppear { selection = Set(store.languages) }
  }
}
