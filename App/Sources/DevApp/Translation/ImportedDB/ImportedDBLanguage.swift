//
//  ImportedDBLanguage.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import Foundation

// MARK: - ImportedDBRow

/// One raw row of an imported translation database: a shipped (language,
/// source -> target) pair tagged by the owning app. Decoded from the
/// `translations` table (language/source/target/app columns) of the
/// localization.sqlite format. `nonisolated`: pure value type (Dev's
/// MainActor default isolation must not leak in).
nonisolated struct ImportedDBRow: Equatable, Sendable {
  var language: String
  var target: String
  var app: String
}

// MARK: - ImportedDBHit

/// The winning translation for one catalog slot, chosen among the raw rows
/// that matched (see ImportedDBLanguage.hit). `value`/`app` are what the
/// pipeline writes into the record (value + provenance).
nonisolated struct ImportedDBHit: Equatable, Sendable {
  var value: String
  var app: String
  /// How many distinct apps carry this exact target (evidence weight).
  var agreeingApps: Int
  /// The db language code that matched (rank-0 exact when possible).
  var matchedLanguage: String
}

// MARK: - ImportedDBLanguage

/// Maps a catalog language code (BCP-47-ish, e.g. "pt_PT", "zh-Hans", "de")
/// onto the messy spellings found in imported translation DBs, and picks the
/// winner among a source's rows. `nonisolated`: pure logic, usable from any
/// executor.
///
/// DB language codes are NOT clean BCP-47 (verified 2026-09-10 against the
/// 11M-row ../Localization/localization.sqlite): plain ("ru", "de"),
/// region-underscore ("pt_PT", "zh_CN"), region-dash ("zh-CN", "pt-BR"),
/// macOS/device suffixes ("ru-macos", "zh_CN~iphone"), case variants
/// ("zh-Hans" vs "zh-hans"). Only the spellings listed here are ever queried;
/// device-suffixed variants match nothing on the catalog side and are simply
/// never candidates (the bare/dash/underscore spellings cover them).
enum ImportedDBLanguage {
  /// Ordered candidate spellings of a catalog code, best first. The FIRST
  /// rank that has any row for a source wins — a lower rank is only
  /// consulted when every higher rank came up empty.
  nonisolated static func candidates(for code: String) -> [String] {
    var out: [String] = []
    func add(_ spelling: String) {
      if !out.contains(spelling) { out.append(spelling) }
    }
    add(code)
    let lower = code.lowercased()
    if lower != code { add(lower) }
    let swapped = swappingSeparators(code)
    if swapped != code { add(swapped) }
    let swappedLower = swapped.lowercased()
    if swappedLower != code && swappedLower != lower && swappedLower != swapped {
      add(swappedLower)
    }
    if let base = baseLanguage(of: code), !out.contains(base) { add(base) }
    return out
  }

  /// Picks the best translation for a catalog language among the rows of one
  /// source text. Prefers the highest-priority spelling rank that has rows;
  /// within it, the target the most distinct apps agree on; ties fall to row
  /// count, then the target text itself (deterministic). `appRowCounts`
  /// (whole-DB per-app totals, when the background scan finished) breaks
  /// same-app-count ties by app popularity; without it, app names decide.
  nonisolated static func hit(
    in rows: [ImportedDBRow],
    forCatalogLanguage code: String,
    appRowCounts: [String: Int64]
  ) -> ImportedDBHit? {
    for spelling in candidates(for: code) {
      let matching = rows.filter { $0.language == spelling && !$0.target.isBlankOrEmpty }
      guard !matching.isEmpty else { continue }

      // Group by target: how many distinct apps (and total rows) back each.
      var byTarget: [String: (apps: Set<String>, rows: Int)] = [:]
      for row in matching {
        var group = byTarget[row.target] ?? (Set<String>(), 0)
        group.apps.insert(row.app)
        group.rows += 1
        byTarget[row.target] = group
      }
      let best = byTarget.max { lhs, rhs in
        let l = lhs.value
        let r = rhs.value
        if l.apps.count != r.apps.count { return l.apps.count < r.apps.count }
        if l.rows != r.rows { return l.rows < r.rows }
        return lhs.key > rhs.key
      }!
      let app = bestApp(in: matching, target: best.key, appRowCounts: appRowCounts)
      return ImportedDBHit(
        value: best.key,
        app: app,
        agreeingApps: best.value.apps.count,
        matchedLanguage: spelling)
    }
    return nil
  }

  /// The app to show for a winning target: the one carrying the most of that
  /// target's rows; ties prefer the whole-DB-biggest app (stats), then the
  /// alphabetically first name — stable across runs either way.
  nonisolated private static func bestApp(
    in rows: [ImportedDBRow],
    target: String,
    appRowCounts: [String: Int64]
  ) -> String {
    var perApp: [String: Int] = [:]
    for row in rows where row.target == target {
      perApp[row.app, default: 0] += 1
    }
    return perApp.keys.max { lhs, rhs in
      let l = perApp[lhs]!
      let r = perApp[rhs]!
      if l != r { return l < r }
      let lRank = appRowCounts[lhs] ?? 0
      let rRank = appRowCounts[rhs] ?? 0
      if lRank != rRank { return lRank < rRank }
      return lhs > rhs
    } ?? rows.first?.app ?? ""
  }

  /// Swaps each separator to the other family: "pt_PT" <-> "pt-PT",
  /// "zh-Hans" -> "zh_Hans". Idempotent for codes with one separator kind.
  nonisolated private static func swappingSeparators(_ code: String) -> String {
    String(code.map { $0 == "-" ? "_" : ($0 == "_" ? "-" : $0) })
  }

  /// The bare language of a region-flagged code ("pt_PT" -> "pt",
  /// "es-419" -> "es"), nil when there is no region part or the language is
  /// script-flagged ("zh-Hans"/"zh-Hant" MUST NOT collapse to "zh" — script
  /// distinguishes simplified from traditional, and imported DBs spell the
  /// scripts separately).
  nonisolated private static func baseLanguage(of code: String) -> String? {
    guard let separator = code.firstIndex(where: { $0 == "-" || $0 == "_" }) else {
      return nil
    }
    let prefix = code[..<separator]
    let suffix = code[code.index(after: separator)...]
    guard !suffix.isEmpty, (2...3).contains(prefix.count) else { return nil }
    guard prefix.allSatisfy({ $0.isLetter }) else { return nil }
    let base = String(prefix).lowercased()
    guard base != "zh" else { return nil }
    return base
  }
}
