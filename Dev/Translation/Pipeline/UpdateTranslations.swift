//
//  UpdateTranslations.swift
//  Dev
//
//  Created by Dmitry on 11.09.26.
//

import Foundation
import SwiftData

// MARK: - UpdateTranslations

/// Selection for the explicit "Update Translations" pass — the ONE channel a
/// project-context rule has to the records that predate it.
///
/// A project-doc version bump deliberately auto-enqueues nothing (see
/// `PipelineRunContext.isStale`: the project scope is excluded from the
/// staleness predicate, because re-running every record of a project is the
/// widest paid sweep in the system). This type owns the predicate both ends
/// must agree on — the toolbar counts exactly the slots the pass will send.
///
/// Deliberately free of pipeline/router types (Foundation + SwiftData only) so
/// the selection math is exercised by the reconcile probe harness.
enum UpdateTranslations {
  /// True when the pass sweeps one record:
  ///  - a project context doc exists and the record's stored project snapshot
  ///    is OLDER than it. A nil snapshot (`?? -1`) predates any doc — the same
  ///    math the staleness predicate uses — so a record written before the doc
  ///    existed, or never written at all, qualifies.
  ///  - the record is not human-owned: `state == .reviewed` (a human confirmed
  ///    it) and `provider == .manual` (a human typed it) are refused even on a
  ///    forced run, by the pipeline's `needsTarget`. A rule therefore CANNOT
  ///    reach them until they are explicitly un-confirmed (row menu "Needs
  ///    Review").
  ///  - its source text carries something to translate.
  static func qualifies(_ record: TranslationRecord, projectVersion: Int?) -> Bool {
    guard let projectVersion else { return false }
    guard record.state != .reviewed, record.provider != .manual else { return false }
    guard !record.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    return (record.contextVersions.project ?? -1) < projectVersion
  }

  /// The records the pass would send, in the input order.
  static func candidates(
    in records: [TranslationRecord],
    projectVersion: Int?
  ) -> [TranslationRecord] {
    records.filter { qualifies($0, projectVersion: projectVersion) }
  }

  /// Distinct keys (rows) among the swept records — the "M row(s)" of the
  /// pre-run count, since the pass sends ONE request per row.
  static func rowCount(of records: [TranslationRecord]) -> Int {
    Set(records.map(\.key)).count
  }
}
