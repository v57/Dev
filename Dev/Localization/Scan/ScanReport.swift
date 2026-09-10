//
//  ScanReport.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import Foundation

/// One scanned Swift package.
nonisolated struct ScanPackageOutcome: Identifiable, Sendable {
  var name: String
  var root: URL
  var buildWarning: String
  var moduleCount: Int
  var keyCount: Int

  var id: String { root.path }
}

/// Everything one scan learned — the preview the user reviews before the
/// merge touches the catalog.
nonisolated struct ScanReport: Sendable {
  var root: URL
  var startedAt: Date
  var duration: TimeInterval
  var packages: [ScanPackageOutcome]
  var modules: [ScanModuleOutcome]
  /// Union of every module's keys (a key found in two modules is ONE key),
  /// keyed to the comments the compiler recorded.
  var extracted: [String: Set<String>]
  /// Key -> the modules it was found in (sorted), for the diff UI.
  var keyOwners: [String: [String]]
  var skippedTableKeys: Int
  var warnings: [String]
  var cancelled: Bool
  var errorMessage: String?

  var extractedKeyCount: Int { extracted.count }
  var failedModules: [ScanModuleOutcome] { modules.filter(\.failed) }
  var totalKeysAcrossModules: Int { modules.reduce(0) { $0 + $1.keyCount } }

  /// True when the root yielded anything scannable at all (a package or an
  /// Xcode target) — false means the wrong folder was picked.
  var hasTargets: Bool { !packages.isEmpty || !modules.isEmpty }
}

// MARK: - Merge plan

/// One key the scan found that the catalog does not carry yet.
nonisolated struct ScanAddedKey: Identifiable, Sendable {
  var key: String
  var comment: String?
  var modules: [String]

  var id: String { key }
}

/// The merge the scan PROPOSES: what would be added to the open catalog.
/// Nothing is written until the user applies it.
nonisolated struct ScanMergePlan: Sendable {
  var catalogURL: URL
  /// Keys already in the catalog (left completely untouched).
  var existingKeyCount: Int
  /// Keys the catalog lacks — the merge adds exactly these.
  var added: [ScanAddedKey]

  var addedCount: Int { added.count }
  var catalogKeyCount: Int
  var totalAfterMerge: Int { catalogKeyCount + added.count }

  /// Plain-text variant for the report's Copy button.
  func textSummary(report: ScanReport) -> String {
    var lines: [String] = []
    lines.append("Scan Strings report")
    lines.append("root: \(report.root.path)")
    lines.append("catalog: \(catalogURL.path)")
    lines.append(String(
      format: "duration: %.1fs", report.duration))
    lines.append("packages: \(report.packages.count), modules: \(report.modules.count) (\(report.failedModules.count) failed)")
    lines.append("extracted keys: \(report.extractedKeyCount) unique, \(report.totalKeysAcrossModules) key-hits across modules")
    lines.append("catalog keys: \(catalogKeyCount) -> \(totalAfterMerge) after merge")
    lines.append("new keys: \(added.count), already present: \(existingKeyCount)")
    if report.skippedTableKeys > 0 {
      lines.append("skipped keys in non-Localizable tables: \(report.skippedTableKeys)")
    }
    if !report.warnings.isEmpty {
      lines.append("")
      lines.append("warnings:")
      for warning in report.warnings { lines.append("  - \(warning.replacingOccurrences(of: "\n", with: " "))") }
    }
    lines.append("")
    lines.append("modules:")
    for module in report.modules.sorted(by: { $0.id < $1.id }) {
      var status = module.failed ? "FAILED (\(module.detail))" : "\(module.keyCount) keys"
      if !module.skippedFiles.isEmpty {
        status += ", \(module.skippedFiles.count) file(s) skipped"
      }
      let kind = module.origin == .packageTarget ? "package" : "project"
      lines.append("  \(kind)  \(module.id)  [\(status)]  \(module.fileCount) files")
      if !module.skippedFiles.isEmpty {
        lines.append("      skipped: \(module.skippedFiles.joined(separator: ", "))")
      }
    }
    if !added.isEmpty {
      lines.append("")
      lines.append("new keys (\(added.count)):")
      for entry in added {
        var line = "  \(entry.key)"
        if let comment = entry.comment, !comment.isEmpty {
          line += "   // \(comment)"
        }
        lines.append(line)
      }
    }
    return lines.joined(separator: "\n")
  }
}

/// Pure merge of a scan's extracted keys into the open catalog document.
///
/// Additive ONLY, mirroring the verified standalone tool's contract: existing
/// entries — every localization, state, variation and unknown field — are
/// preserved untouched; a key the catalog lacks is added with its comment and
/// `extractionState: "manual"` (Xcode keeps manually-added keys and never
/// marks them stale) and NO localizations, so the key reads as missing in
/// every language and the existing translate pipeline fills it.
nonisolated enum ScanMerge {
  static func plan(
    extracted: [String: Set<String>],
    keyOwners: [String: [String]],
    catalog: StringCatalog,
    catalogURL: URL
  ) -> ScanMergePlan {
    var added: [ScanAddedKey] = []
    var existing = 0
    for key in extracted.keys.sorted() {
      if catalog.strings[key] != nil {
        existing += 1
        continue
      }
      let comment = (extracted[key] ?? [])
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .sorted()
        .joined(separator: "\n")
      added.append(
        ScanAddedKey(
          key: key,
          comment: comment.isEmpty ? nil : comment,
          modules: keyOwners[key] ?? []))
    }
    return ScanMergePlan(
      catalogURL: catalogURL,
      existingKeyCount: existing,
      added: added,
      catalogKeyCount: catalog.strings.count)
  }

  /// The merged document. `plan.added` entries are inserted; everything else
  /// in `catalog` is carried through unchanged.
  static func apply(_ plan: ScanMergePlan, to catalog: StringCatalog) -> StringCatalog {
    var merged = catalog
    for entry in plan.added where merged.strings[entry.key] == nil {
      var item = StringCatalog.Entry()
      item.comment = entry.comment
      item.extractionState = "manual"
      merged.strings[entry.key] = item
    }
    return merged
  }
}
