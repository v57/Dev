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

  /// Picks the translation for a catalog language among the rows of one source
  /// text, or nil when the database cannot say which one is meant. Prefers the
  /// highest-priority spelling rank that has usable rows; within it, the target
  /// the most distinct apps agree on, and only when it is ahead: a source with
  /// several targets and no agreement between them is AMBIGUOUS ("Audio" as
  /// sound in one app and as headphones in another, "OK" as an answer and as a
  /// rating), and no tie-break between them reads the meaning, so the slot is
  /// left to the model. The database keeps one row per (source, language,
  /// target), which makes such ties the common case. A target that is not a
  /// translation at all (`usable`) never counts. `appRowCounts` (whole-DB
  /// per-app totals, when the background scan finished) only picks the app shown
  /// for the winner. `source` is the English, for the usability check.
  nonisolated static func hit(
    in rows: [ImportedDBRow],
    forCatalogLanguage code: String,
    appRowCounts: [String: Int64],
    source: String? = nil
  ) -> ImportedDBHit? {
    for spelling in candidates(for: code) {
      let matching = rows.filter {
        $0.language == spelling && !$0.target.isBlankOrEmpty
          && usable($0.target, source: source, language: code)
      }
      guard !matching.isEmpty else { continue }

      // Group by target: how many distinct apps (and total rows) back each.
      var byTarget: [String: (apps: Set<String>, rows: Int)] = [:]
      for row in matching {
        var group = byTarget[row.target] ?? (Set<String>(), 0)
        group.apps.insert(row.app)
        group.rows += 1
        byTarget[row.target] = group
      }
      let ranked = byTarget.sorted { lhs, rhs in
        if lhs.value.apps.count != rhs.value.apps.count { return lhs.value.apps.count > rhs.value.apps.count }
        return lhs.key < rhs.key
      }
      let best = ranked[0]
      if ranked.count > 1, ranked[1].value.apps.count == best.value.apps.count { return nil }
      let app = bestApp(in: matching, target: best.key, appRowCounts: appRowCounts)
      return ImportedDBHit(
        value: best.key,
        app: app,
        agreeingApps: best.value.apps.count,
        matchedLanguage: spelling)
    }
    return nil
  }

  /// Whether a target is a translation at all: not a string-table identifier
  /// (`ACTION_CANCEL`), not shouted when the English is not (`ABBRECHEN` for
  /// "Cancel"), without a Windows menu accelerator (`キャンセル(C)`, `&Open`), and
  /// written in the language's own script when that is not Latin (`Cancelar`
  /// filed under Russian). A target equal to the English is a name kept as is.
  nonisolated static func usable(_ target: String, source: String?, language: String) -> Bool {
    let text = target.trimmingCharacters(in: .whitespaces)
    if let source, text == source { return true }
    let english = source ?? ""
    if text.contains("_"), !text.contains(" "), !english.contains("_") { return false }
    let cased = text.unicodeScalars.filter { CharacterSet.uppercaseLetters.contains($0) || CharacterSet.lowercaseLetters.contains($0) }
    if cased.count >= 2, cased.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }),
      english.unicodeScalars.contains(where: { CharacterSet.lowercaseLetters.contains($0) })
    {
      return false
    }
    if text.range(of: #"\(&?[A-Za-z0-9]\)$"#, options: .regularExpression) != nil, !english.hasSuffix(")") { return false }
    if text.range(of: #"&\p{L}"#, options: .regularExpression) != nil, !english.contains("&") { return false }
    let script = Translation.Languages.script(of: language)
    if !script.ranges.isEmpty {
      let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
      if !letters.isEmpty, !letters.contains(where: script.contains) { return false }
    }
    return true
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
