import CodeProgress
import Foundation
import Testing

@testable import DevApp

private typealias RunProgress = Translation.RunProgress
private typealias Batch = Translation.Run.Batch

final class Clock: @unchecked Sendable {
  var date = Date(timeIntervalSinceReferenceDate: 0)
  func advance(_ seconds: TimeInterval) { date += seconds }
}

private func batch(
  _ stage: Translation.Stage, _ language: String?, strings: Int, languages: [String] = [],
  ordinal: Int = 0
) -> Batch {
  let items = (0..<strings).map { index in
    Translation.Run.Item(
      key: "key.\(index)", language: language ?? languages[index % languages.count],
      source: .value("Source \(index)"), target: .empty, comment: "", maxWidth: 0)
  }
  return Batch(
    id: "\(stage.rawValue).\(language ?? "row").\(ordinal)", stage: stage, language: language,
    items: items, characters: items.reduce(0) { $0 + $1.characters })
}

private func near(_ value: Double?, _ expected: Double, _ tolerance: Double = 0.01) -> Bool {
  guard let value else { return false }
  return abs(value - expected) < tolerance
}

@Suite struct TranslationProgressTests {
  let model = "openrouter:some-model"

  @Test func requestIsARemoteStageSizedByItsStrings() {
    let stage = RunProgress.stage(for: batch(.vertical, "de", strings: 3), model: model)
    #expect(stage.id == "translation.vertical openrouter:some-model de")
    #expect(stage.resource == .remote)
    #expect(stage.timing == .static)
    #expect(stage.size == 3)
    #expect(stage.title == Translation.Stage.vertical.title)
  }

  @Test func rowBatchIsNamedByItsLanguageSet() {
    let row = batch(.horizontal, nil, strings: 5, languages: ["fr", "de", "fr"])
    let stage = RunProgress.stage(for: row, model: model)
    #expect(stage.id == "translation.horizontal openrouter:some-model de,fr")
    #expect(stage.size == 5)
  }

  @Test func batchesShareHistoryByModelAndLanguagesNotByStrings() {
    let first = RunProgress.stage(for: batch(.vertical, "de", strings: 10, ordinal: 0), model: model)
    let second = RunProgress.stage(for: batch(.vertical, "de", strings: 1000, ordinal: 1), model: model)
    #expect(first.id == second.id)
    #expect(first.size != second.size)
    let french = RunProgress.stage(for: batch(.vertical, "fr", strings: 10), model: model)
    let otherModel = RunProgress.stage(for: batch(.vertical, "de", strings: 10), model: "local:other")
    let prelearn = RunProgress.stage(for: batch(.prelearn, "de", strings: 10), model: model)
    #expect(Set([first.id, french.id, otherModel.id, prelearn.id]).count == 4)
  }

  @Test func localStagesAreDiskAndCPU() {
    #expect(RunProgress.prepare.resource == .disk)
    #expect(RunProgress.scan(.vertical).resource == .cpu)
    #expect(RunProgress.scan(.vertical).id != RunProgress.scan(.learn).id)
  }

  @Test func freshRunPlansScansAndLastRunsBatches() {
    let lastVertical = RunProgress.stage(for: batch(.vertical, "de", strings: 40), model: model)
    let lastRow = RunProgress.stage(
      for: batch(.horizontal, nil, strings: 8, languages: ["de"]), model: model)
    let unrelated = ProgressStage(id: "something.else")
    let plan = RunProgress.planned(
      operations: Translation.Run.plan(for: .vertical)[...], batches: [], model: model,
      last: [unrelated, lastVertical, lastVertical, lastRow])
    #expect(
      plan.map(\.id) == [
        RunProgress.prepare.id,
        RunProgress.scan(.prelearn).id,
        RunProgress.scan(.learn).id,
        RunProgress.scan(.vertical).id, lastVertical.id, lastVertical.id,
        RunProgress.scan(.horizontal).id, lastRow.id,
      ])
  }

  @Test func resumedRunPlansTheBatchesItCut() {
    let cut = [batch(.vertical, "de", strings: 12), batch(.vertical, "fr", strings: 30)]
    let lastRow = RunProgress.stage(
      for: batch(.horizontal, nil, strings: 8, languages: ["de"]), model: model)
    let plan = RunProgress.planned(
      operations: [.vertical, .horizontal], batches: cut[...], model: model, last: [lastRow])
    #expect(
      plan.map(\.id) == cut.map { RunProgress.stage(for: $0, model: model).id }
        + [RunProgress.scan(.horizontal).id, lastRow.id])
    #expect(plan.first?.size == 12)
  }

  /// Ten strings and a thousand in one request: the history learns the latency and the cost
  /// of a string, and estimates a request of any size from them.
  @Test func historyLearnsLatencyAndCostPerString() {
    let history = ProgressHistory()
    let clock = Clock()
    let small = RunProgress.stage(for: batch(.vertical, "de", strings: 10), model: model)
    let large = RunProgress.stage(for: batch(.vertical, "de", strings: 1000), model: model)
    let run = ProgressTracker(operation: "test", stages: [small, large], history: history) { clock.date }
    run.begin(small)
    clock.advance(2 + 0.01 * 10)
    run.begin(large)
    clock.advance(2 + 0.01 * 1000)
    run.complete()

    let medium = RunProgress.stage(for: batch(.vertical, "de", strings: 500), model: model)
    #expect(near(history.duration(for: medium), 7))
    #expect(history.plan(for: "test")?.map(\.size) == [10, 1000])
  }

  /// Batches of one run share their stage: one slower than usual predicts the rest.
  @Test func slowBatchPredictsTheRestOfTheRun() {
    let history = ProgressHistory()
    let clock = Clock()
    let stage = RunProgress.stage(for: batch(.vertical, "de", strings: 100), model: model)
    history.record(.init(duration: 3, size: 100), for: stage.id)
    let run = ProgressTracker(
      operation: "test", stages: [stage, stage, stage], history: history) { clock.date }
    run.begin(stage)
    #expect(near(run.snapshot().remaining, 9))
    clock.advance(6)
    run.begin(stage)
    #expect(near(run.snapshot().fraction, 1.0 / 3))
    #expect(near(run.snapshot().remaining, 12))
  }

  @Test func estimateLine() {
    typealias Estimate = Translation.Run.Estimate
    let percent = { (value: Double) in value.formatted(.percent.precision(.fractionLength(0))) }
    #expect(
      Estimate(fraction: 0.42, remaining: 200).line
        == "\(percent(0.42)) · about \(Estimate.format(200)) left")
    #expect(Estimate(fraction: 0.5, remaining: nil).line == percent(0.5))
    #expect(Estimate(fraction: nil, remaining: nil).line == nil)
    // Seconds in fives under a minute, minutes above.
    #expect(Estimate.format(12) == Estimate.format(10))
    #expect(Estimate.format(1) == Estimate.format(5))
    #expect(Estimate.format(125) == Estimate.format(140))
  }
}
