import CodeProgress
import Foundation
import Testing

@testable import DevApp

private typealias Progress = ServerRun.Progress

@Suite struct ServerRunProgressTests {
  let model = "openrouter:some-model"

  @Test func requestIsARemoteStageSizedByItsStrings() {
    let stage = Progress.vertical(model: model, locale: "de", strings: 12)
    #expect(stage.id == "translation.server.vertical openrouter:some-model de")
    #expect(stage.resource == .remote)
    #expect(stage.timing == .static)
    #expect(stage.size == 12)
  }

  @Test func requestsShareHistoryByModelAndLocaleNotByStrings() {
    let small = Progress.vertical(model: model, locale: "de", strings: 10)
    let large = Progress.vertical(model: model, locale: "de", strings: 1000)
    #expect(small.id == large.id)
    let french = Progress.vertical(model: model, locale: "fr", strings: 10)
    let otherModel = Progress.vertical(model: "local:other", locale: "de", strings: 10)
    let row = Progress.horizontal(model: model, locale: "de")
    #expect(Set([small.id, french.id, otherModel.id, row.id]).count == 4)
    // Not the project run's requests: the server run's history is its own.
    #expect(small.id != "translation.vertical openrouter:some-model de")
  }

  @Test func serverRequestsAreNetworkStages() {
    for stage in [Progress.learn, Progress.worklist, Progress.rows, Progress.write(3)] {
      #expect(stage.resource == .network)
      #expect(stage.id.hasPrefix("translation.server."))
    }
    #expect(Progress.write(3).id == Progress.write(40).id)
    #expect(Progress.write(3).size == 3)
    #expect(Progress.horizontal(model: model, locale: "de").resource == .remote)
  }

  @Test func operationPerPlan() {
    #expect(Progress.operation(.full) == "translation.server.full")
    #expect(Progress.operation(.skipLearning) == "translation.server.skipLearning")
  }

  /// The worklist streams: a run plans the stages the same plan ran last time, its requests
  /// moved onto this run's model and locale.
  @Test func plansLastRunOnThisModelAndLocale() {
    let last = [
      Progress.learn, Progress.worklist,
      Progress.vertical(model: "local:old", locale: "fr", strings: 30), Progress.write(30),
      Progress.worklist, Progress.rows, Progress.horizontal(model: "local:old", locale: "fr"),
      Progress.write(1),
    ]
    let plan = Progress.planned(last: last, model: model, locale: "de")
    #expect(
      plan.map(\.id) == [
        Progress.learn.id, Progress.worklist.id,
        Progress.vertical(model: model, locale: "de", strings: 30).id, Progress.write(30).id,
        Progress.worklist.id, Progress.rows.id, Progress.horizontal(model: model, locale: "de").id,
        Progress.write(1).id,
      ])
    #expect(plan[2].size == 30)
    #expect(Progress.planned(last: [], model: model, locale: "de").isEmpty)
  }

  /// A run times its stages in the order the run begins them; the next run with the same
  /// plan knows how long it has before it reads a page.
  @Test func nextRunEstimatesFromTheLast() {
    let history = ProgressHistory()
    let clock = Clock()
    let operation = Progress.operation(.skipLearning)
    let request = Progress.vertical(model: model, locale: "de", strings: 50)
    let first = ProgressTracker(operation: operation, history: history) { clock.date }
    first.begin(Progress.worklist)
    clock.advance(1)
    first.begin(request)
    clock.advance(5)
    first.begin(Progress.write(50))
    clock.advance(1)
    first.begin(Progress.worklist)
    clock.advance(1)
    first.complete()

    let second = ProgressTracker(
      operation: operation,
      stages: Progress.planned(last: history.plan(for: operation) ?? [], model: model, locale: "de"),
      history: history) { clock.date }
    #expect(second.snapshot().stageCount == 4)
    #expect(near(second.snapshot().remaining, 8))
    second.begin(Progress.worklist)
    clock.advance(1)
    second.begin(request)
    #expect(near(second.snapshot().fraction, 1.0 / 8))
  }

  @Test func noEstimateBeforeARun() {
    #expect(ServerRun(progressHistory: ProgressHistory()).estimate == nil)
  }
}

private func near(_ value: Double?, _ expected: Double, _ tolerance: Double = 0.01) -> Bool {
  guard let value else { return false }
  return abs(value - expected) < tolerance
}
