//
//  ServerRunProgress.swift
//  Dev
//
//  How a server run's work maps onto CodeProgress, in the project run's terms
//  (`Translation.RunProgress`, Localization/Redesign/Progress.swift): each model request
//  is a stage on the remote resource, sized by the strings it carries and named by its step,
//  model and locale, so the history learns a model's latency and its cost per string. What
//  the run asks the server (a worklist page, a write, the learn step's reads, the row pass's
//  inventory walk) is a network stage.
//
//  The worklist streams, so the run can't know its batches up front: it plans from the stages
//  the same plan ran last time, moved onto this run's model and locale.
//

import CodeProgress
import Foundation

extension ServerRun {
  enum Progress {
    /// What every stage id starts with: the history is the app's one file, shared with
    /// the project run.
    static let prefix = "\(Translation.RunProgress.prefix).server"

    /// The history a run's plan is kept under: one per plan, since a run without the
    /// learning step is a different list of stages.
    static func operation(_ plan: Plan) -> String {
      "\(prefix).\(plan.rawValue)"
    }

    /// Reading the server's verified values for the locale, every page of it.
    static let learn = ProgressStage(
      id: "\(prefix).learn", title: Phase.learning.title, resource: .network)

    /// Waiting for the next worklist page.
    static let worklist = ProgressStage(
      id: "\(prefix).worklist", title: Phase.vertical.title, resource: .network)

    /// The row pass's walk of the inventory for the rows the run wrote.
    static let rows = ProgressStage(
      id: "\(prefix).rows", title: Phase.horizontal.title, resource: .network)

    /// Pushing accepted values, sized by how many.
    static func write(_ count: Int) -> ProgressStage {
      ProgressStage(
        id: "\(prefix).write", title: "writing values", resource: .network, size: Double(count))
    }

    /// One translateBatch request: its model and locale name its history, its size is the
    /// strings in the chunk.
    static func vertical(model: String, locale: String, strings: Int) -> ProgressStage {
      ProgressStage(
        id: "\(verticalPrefix)\(model) \(locale)", title: Phase.vertical.title,
        resource: .remote, timing: .static, size: Double(strings))
    }

    /// One row the row pass re-asks.
    static func horizontal(model: String, locale: String) -> ProgressStage {
      ProgressStage(
        id: "\(horizontalPrefix)\(model) \(locale)", title: Phase.horizontal.title,
        resource: .remote, timing: .static, size: 1)
    }

    static let verticalPrefix = "\(prefix).vertical "
    static let horizontalPrefix = "\(prefix).horizontal "

    /// The model requests go to, as the project run names it.
    static var model: String { Translation.RunProgress.model }

    /// The stages the same plan ran last time, its requests moved onto this run's model and
    /// locale (sizes kept): a run into another language or with another model is still about
    /// as many batches, and stages it would never begin would hold the estimate back.
    static func planned(last: [ProgressStage], model: String, locale: String) -> [ProgressStage] {
      last.map { stage in
        if stage.id.hasPrefix(verticalPrefix) {
          return vertical(model: model, locale: locale, strings: Int(stage.size ?? 0))
        }
        if stage.id.hasPrefix(horizontalPrefix) {
          return horizontal(model: model, locale: locale)
        }
        return stage
      }
    }
  }

  /// The tracker's reading now; nil before the first run.
  var estimate: Translation.Run.Estimate? {
    guard let snapshot = progress?.snapshot() else { return nil }
    return Translation.Run.Estimate(
      fraction: snapshot.fraction, remaining: isRunning ? snapshot.remaining : nil)
  }
}
