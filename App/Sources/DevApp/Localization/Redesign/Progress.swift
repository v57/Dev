//
//  Progress.swift
//  Dev
//
//  How a run's work maps onto CodeProgress: each model request is a stage on the remote
//  resource, sized by the strings it carries, so the history learns a model's fixed latency
//  and its cost per string (10 strings against 1000 in one request). The batches of one run
//  that go to the same model for the same languages share a stage id, so a batch slower than
//  usual predicts the rest of them. Preparation reads the store (disk) and a step's scan cuts
//  its batches and asks translation memory (cpu).
//

import CodeProgress
import Foundation

extension Translation {
  enum RunProgress {
    /// What every stage id starts with: Dev's history is one file, shared with whatever else
    /// in the app keeps progress.
    static let prefix = "translation"

    /// The history a run's plan is kept under: one per stage and mode, since a run without
    /// the learning steps is a different list of stages.
    static func operation(_ stage: Stage, mode: Run.Mode) -> String {
      "\(prefix).\(stage.rawValue).\(mode.rawValue)"
    }

    /// The history a re-ask of a finished run's failed batches is kept under (5.11).
    static let retryOperation = "\(prefix).retry"

    /// Reading the project's rows and the imported database (4.1).
    static let prepare = ProgressStage(
      id: "\(prefix).prepare", title: Stage.prepare.title, resource: .disk)

    /// Cutting a step's batches and answering what translation memory can (6.2).
    static func scan(_ operation: Stage) -> ProgressStage {
      ProgressStage(id: "\(prefix).scan.\(operation.rawValue)", title: operation.title, resource: .cpu)
    }

    /// One request: the step that sends it, the model it goes to and the languages it
    /// translates into name its history, never the strings themselves, and its size is the
    /// number of strings it carries.
    static func stage(for batch: Run.Batch, model: String) -> ProgressStage {
      ProgressStage(
        id: "\(batchPrefix(batch.stage))\(model) \(languages(of: batch).joined(separator: ","))",
        title: batch.stage.title, resource: .remote, timing: .static,
        size: Double(batch.items.count))
    }

    /// A step's request ids all start with this.
    static func batchPrefix(_ operation: Stage) -> String {
      "\(prefix).\(operation.rawValue) "
    }

    /// The languages a request translates into: the batch's own, or a row batch's items'.
    static func languages(of batch: Run.Batch) -> [String] {
      if let language = batch.language { return [language] }
      return Set(batch.items.compactMap(\.language)).sorted()
    }

    /// The model requests go to, as the history tells models apart: provider and model.
    static var model: String { RoutedModel.current?.id ?? "none" }

    /// The stages a run has left from where it is: preparation, and for each step still to
    /// come either the batches it has cut or, before its scan, the scan and the batches the
    /// same step sent last time.
    static func planned(
      for run: Run, model: String, last: [ProgressStage]
    ) -> [ProgressStage] {
      planned(
        operations: run.operations[min(run.operationIndex, run.operations.count)...],
        batches: run.batches[min(run.batchIndex, run.batches.count)...], model: model, last: last)
    }

    /// `operations` are the steps left and `batches` the cut batches not yet sent.
    static func planned(
      operations: ArraySlice<Stage>, batches: ArraySlice<Run.Batch>, model: String,
      last: [ProgressStage]
    ) -> [ProgressStage] {
      var stages: [ProgressStage] = []
      for operation in operations {
        let cut = batches.filter { $0.stage == operation }
        if operation == .prepare {
          stages.append(prepare)
        } else if !cut.isEmpty {
          stages += cut.map { stage(for: $0, model: model) }
        } else {
          stages.append(scan(operation))
          stages += last.filter { $0.id.hasPrefix(batchPrefix(operation)) }
        }
      }
      return stages
    }
  }
}

extension Translation.Run {
  /// How far the run got, from 0 to 1, and the time it has left while it runs.
  struct Estimate: Equatable {
    var fraction: Double?
    var remaining: TimeInterval?
  }

  /// The tracker's reading now, continued from where a paused run's bar stood. Nil before
  /// the run first started.
  var estimate: Estimate? {
    guard let snapshot = progress?.snapshot() else { return nil }
    let fraction = snapshot.fraction.map { progressBase + (1 - progressBase) * $0 }
      ?? (progressBase > 0 ? progressBase : nil)
    let isActive = state == .running || state == .scanning
    return Estimate(fraction: fraction, remaining: isActive ? snapshot.remaining : nil)
  }
}

extension Translation.Run.Estimate {
  /// "42% · about 3 min left", or nil while nothing is known.
  var line: String? {
    var parts: [String] = []
    if let fraction { parts.append(fraction.formatted(.percent.precision(.fractionLength(0)))) }
    if let remaining { parts.append("about \(Self.format(remaining)) left") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// Minutes and hours, or seconds in fives under a minute.
  static func format(_ remaining: TimeInterval) -> String {
    if remaining < 60 {
      let seconds = max(5, (remaining / 5).rounded() * 5)
      return Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .abbreviated))
    }
    return Duration.seconds(remaining.rounded()).formatted(
      .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
  }
}
