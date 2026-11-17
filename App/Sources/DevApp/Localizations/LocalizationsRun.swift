//
//  LocalizationsRun.swift
//  Dev
//
//  What the Translations tool shows while it works and after: the job running (scan, translate, build and commit),
//  where each source is in it, the run's totals and estimate, and the history of finished translations. The list,
//  Dev's sidebar row and the pages all read these, so they say the same thing.
//

import ComponentKit
import Foundation

/// One source's finished translation, kept between launches (the Overview's recent runs, a source's last run).
nonisolated struct LocalizationsRunRecord: Codable, Hashable, Sendable, Identifiable {
  var id = UUID()
  var source: String
  var date: Date
  /// Strings the run had to translate, and how many it did.
  var items = 0
  var done = 0
  var failures = 0
  /// The languages of the failed batches.
  var failedLanguages: [String] = []
  var requests = 0
  var promptTokens = 0
  var cachedTokens = 0
  var completionTokens = 0
  var seconds = 0.0
  /// The row pass: values it read across the languages, and how many it corrected.
  var checked = 0
  var corrected = 0
  var stopped = false

  var tokens: Int { promptTokens + completionTokens }
}

/// Where a source is in the job that runs now, or in the one that ran last.
enum LocalizationsSourceState: Equatable {
  /// In the queue, not started.
  case waiting
  case translating
  /// Had nothing to translate.
  case upToDate
  case translated(LocalizationsRunRecord)
  case failed(String)
  /// The run was stopped before it got here.
  case stopped
  case committing
  case committed(String)
}

/// What the tool is doing.
enum LocalizationsJob: Equatable {
  case scan
  case translate
  case build
}

/// Seconds per string at Low reasoning with four batches at once (the real runs of 16 Nov 2026): what an estimate
/// starts from before a run has timed its own.
let localizationsSecondsPerString = 0.165

extension LocalizationsStore {
  // MARK: coverage

  /// Strings to translate in a source: its keys in every language.
  func slots(_ name: String) -> Int { (progress[name]?.keys ?? 0) * languages.count }

  /// Strings a source has in the tool's languages.
  func translatedSlots(_ name: String) -> Int {
    guard let progress = progress[name] else { return 0 }
    return languages.reduce(0) { $0 + min(progress.translated[$1] ?? 0, progress.keys) }
  }

  func missing(_ name: String) -> Int { max(0, slots(name) - translatedSlots(name)) }

  func fraction(_ name: String) -> Double {
    let total = slots(name)
    return total == 0 ? 0 : Double(translatedSlots(name)) / Double(total)
  }

  /// The sources a scan makes (not the catalogs no included app makes now).
  var plannedNames: [String] { plan.sources.map(\.name) }

  /// The planned sources with strings left to translate, in the list's order.
  var needingWork: [String] { plannedNames.filter { progress[$0] != nil && missing($0) > 0 } }

  var totalSlots: Int { plannedNames.reduce(0) { $0 + slots($1) } }
  var totalTranslated: Int { plannedNames.reduce(0) { $0 + translatedSlots($1) } }
  var totalMissing: Int { plannedNames.reduce(0) { $0 + missing($1) } }

  /// How long `strings` take, from the recent runs' own pace (the default until there is one).
  func estimate(_ strings: Int) -> TimeInterval {
    let recent = state.records?.suffix(10).filter { $0.done > 200 && !$0.stopped } ?? []
    let done = recent.reduce(0) { $0 + $1.done }
    let seconds = recent.reduce(0) { $0 + $1.seconds }
    let pace = done > 0 ? seconds / Double(done) : localizationsSecondsPerString
    return Double(strings) * pace
  }

  /// The tokens `strings` cost, from the recent runs (about 160 a string at Low reasoning).
  func tokenEstimate(_ strings: Int) -> Int {
    let recent = state.records?.suffix(10).filter { $0.done > 200 } ?? []
    let done = recent.reduce(0) { $0 + $1.done }
    let tokens = recent.reduce(0) { $0 + $1.tokens }
    let perString = done > 0 ? Double(tokens) / Double(done) : 160
    return Int(Double(strings) * perString)
  }

  var records: [LocalizationsRunRecord] { state.records ?? [] }

  func lastRecord(_ name: String) -> LocalizationsRunRecord? { records.last { $0.source == name } }

  // MARK: the run now

  /// The current source's live run: batches, tally, estimate.
  var liveRun: Translation.Run? { translator?.workspace?.runner.runs[.vertical] }

  /// The model answering the current run, as its batches are stamped.
  var liveModel: String? { liveRun?.batches.last { !$0.model.isEmpty }?.model }

  /// When the provider may be asked again, while it is parked during a run.
  var providerWaitUntil: Date? {
    guard job == .translate else { return nil }
    return translator?.workspace?.runner.router.cooldownUntil
  }

  /// Strings the current source's run has written in its columns (the row pass corrects; it adds none).
  var liveDone: Int {
    guard let run = liveRun else { return 0 }
    return run.tally.itemsDone - (run.tally.byStage[.horizontal] ?? 0)
  }

  /// The translate job's records so far, in queue order.
  var jobRecords: [LocalizationsRunRecord] {
    queue.compactMap { if case .translated(let record) = sourceStates[$0] { record } else { nil } }
  }

  /// Strings the translate job has written.
  var jobDone: Int { jobRecords.reduce(0) { $0 + $1.done } + (job == .translate ? liveDone : 0) }
  var jobRequests: Int { jobRecords.reduce(0) { $0 + $1.requests } + (job == .translate ? liveRun?.tally.requests ?? 0 : 0) }
  var jobTokens: Int {
    let live = job == .translate ? (liveRun?.tally).map { $0.promptTokens + $0.completionTokens } ?? 0 : 0
    return jobRecords.reduce(0) { $0 + $1.tokens } + live
  }
  var jobFailures: Int { jobRecords.reduce(0) { $0 + $1.failures } + (job == .translate ? liveRun?.failures.count ?? 0 : 0) }

  /// How far the job is, 0…1.
  var jobFraction: Double? {
    switch job {
    case .translate:
      return plannedStrings > 0 ? min(1, Double(jobDone) / Double(plannedStrings)) : nil
    case .scan:
      return scanTotal > 0 ? Double(scanIndex) / Double(scanTotal) : nil
    case .build:
      let total = queue.count
      let done = queue.filter { if case .committed = sourceStates[$0] { true } else { false } }.count
      return total > 0 ? Double(done) / Double(total) : nil
    case nil:
      return nil
    }
  }

  /// The translate job's time left: its own pace once it has one, else the recent runs'.
  func jobRemaining(now: Date = .now) -> TimeInterval? {
    guard job == .translate, let started = jobStartedAt else { return nil }
    let left = max(0, plannedStrings - jobDone)
    let elapsed = now.timeIntervalSince(started)
    guard jobDone > 50, elapsed > 20 else { return estimate(left) }
    return Double(left) * elapsed / Double(jobDone)
  }

  /// The sources the translate job has to translate, in order, and the place of a waiting one among them.
  func queuePosition(_ name: String) -> Int? {
    let waiting = queue.filter { sourceStates[$0] == .waiting && (missing($0) > 0 || progress[$0] == nil) }
    return waiting.firstIndex(of: name).map { $0 + 1 }
  }

  /// The current source's time left, paced like the job's: its own pace once it has one, else the recent runs'.
  func liveRemaining(now: Date = .now) -> TimeInterval? {
    guard let run = liveRun, run.state != .finished else { return nil }
    let left = max(0, run.tally.items - liveDone)
    guard let started = run.startedAt else { return estimate(left) }
    let elapsed = now.timeIntervalSince(started)
    guard liveDone > 50, elapsed > 20 else { return estimate(left) }
    return Double(left) * elapsed / Double(liveDone)
  }

  /// "Shell · 6 of 18": the source being translated and its place in the job.
  var jobPosition: (index: Int, count: Int) {
    let worked = queue.filter { name in
      switch sourceStates[name] {
      case .upToDate: false
      default: true
      }
    }
    let index = (current.flatMap { worked.firstIndex(of: $0) } ?? 0) + 1
    return (index, worked.count)
  }

  /// The ring on the tool's icons: what the job is doing and how far.
  var workStatus: WorkStatus {
    guard let job else { return .idle }
    if job == .translate, providerWaitUntil != nil { return .paused(progress: jobFraction) }
    return .working(progress: jobFraction)
  }

  /// The finished translate job's outcome, while its states are still shown (until the next job).
  var finishedTranslate: (done: Int, failures: Int, failedSources: Int, sources: Int)? {
    guard job == nil, lastJob == .translate, !queue.isEmpty else { return nil }
    let records = jobRecords
    let failedSources = queue.filter { if case .failed = sourceStates[$0] { true } else { false } }.count
    return (records.reduce(0) { $0 + $1.done }, records.reduce(0) { $0 + $1.failures }, failedSources, records.count)
  }

  /// The sources whose run failed or left failed batches: what Retry translates again.
  var sourcesWithFailures: [String] {
    queue.filter {
      switch sourceStates[$0] {
      case .translated(let record): record.failures > 0
      case .failed: true
      default: false
      }
    }
  }

  // MARK: formatting

  static func duration(_ seconds: TimeInterval) -> String {
    guard seconds >= 60 else { return Duration.seconds(max(1, seconds.rounded())).formatted(.units(allowed: [.seconds], width: .narrow)) }
    return Duration.seconds(seconds.rounded()).formatted(
      .units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2))
  }

  static func count(_ value: Int) -> String {
    value >= 1_000_000
      ? (Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(1))) + "M"
      : value >= 10_000 ? (Double(value) / 1000).formatted(.number.precision(.fractionLength(0))) + "k" : value.formatted()
  }
}
