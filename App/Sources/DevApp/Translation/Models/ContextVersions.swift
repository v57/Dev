//
//  ContextVersions.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

/// Snapshot of the context-document versions a translation was produced
/// against: `global`/`project`/`language` match ContextDoc.version for the
/// doc of that scope (the language doc for the record's language). A nil
/// entry means that scope's doc did not exist (or was not used) at the
/// time. Captured on records, edits, and translation-memory entries so a
/// later pipeline run can tell stale output from fresh.
/// `nonisolated`: the module defaults to MainActor isolation, but SwiftData
/// encodes Codable stored properties in a nonisolated context.
nonisolated struct ContextVersions: Codable, Hashable, Sendable {
  var global: Int?
  var project: Int?
  var language: Int?

  init(global: Int? = nil, project: Int? = nil, language: Int? = nil) {
    self.global = global
    self.project = project
    self.language = language
  }
}
