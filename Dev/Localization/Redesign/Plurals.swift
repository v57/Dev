//
//  Plurals.swift
//  Dev
//
//  Created by Dmitry on 12.09.26.
//

/// The plural forms of one slot in one language — the `.plural` payload of a
/// `StringBody`.
///
/// A plural slot is NOT a set of separate slots: the three bodies of the slot
/// (`target`, `machine`, `reviewed`) are parallel plural bodies over the SAME rule
/// set, and the slot's status covers all of its forms — Xcode treats a plural like
/// any other string, so a form is empty or filled and the slot is reviewed or not.
/// There is no per-form status.
struct Plurals: Hashable {
  var isEmpty: Bool {
    !values.contains(where: { !$0.value.isEmpty })
  }
  var count: Int {
    values.reduce(into: 0, { $0 += $1.value.count })
  }
  var values: [Plural]
  init(language: String) {
    values = Plural.rules(language: language).map { Plural(rule: $0, value: "") }
  }
  init(array: [Plural]) {
    self.values = array
  }
  /// The text of one form; empty when the form is not filled.
  func value(for rule: Plural.Rule) -> String {
    values.first { $0.rule == rule }?.value ?? ""
  }
  /// Writes one form. A form is written as a unit — never merged, never
  /// reordered — so the rule set stays the same across the slot's bodies.
  mutating func set(_ value: String, for rule: Plural.Rule) {
    guard let index = values.firstIndex(where: { $0.rule == rule }) else { return }
    values[index].value = value
  }
}
struct Plural: Hashable, Identifiable {
  var rule: Rule
  var value: String
  var id: Rule { rule }
  enum Rule: String {
    case zero, one, two, few, many, other
  }
  /// The categories a language actually uses.
  ///
  /// The switch below is the SAME 58 entries as the app's `PluralRules.nonDefault`
  /// (Xcode's own table, plus CLDR fills for `ars` / `sa` / `sat`) — measured
  /// equal, so it is complete relative to what the app uses today. It is still a
  /// SECOND copy of that table, which is the actual defect: one table, read from one
  /// place. "docs/Translation design notes.md" 9.4 has the delta against CURRENT CLDR (27 locales it
  /// lacks, 3 sets it gets differently) and 10.13 has which source wins.
  ///
  /// The default is right for everything NOT listed: every language absent from the
  /// table is one/other in CLDR. What the default cannot express is an `other`-ONLY
  /// language the table lacks (jv, su, wo, …): those inherit a `one` they do not
  /// have.
  static func rules(language: String) -> [Rule] {
    // Region-tagged codes reduce to their base: "pt-BR" / "zh-Hans" / "es-419" are
    // pt, zh, es. `PluralRules.categories(for:)` already does this; switching on the
    // raw string would send every tagged code to the default and silently drop the
    // forms of the language it names.
    let base = language.split(separator: "-").first?.split(separator: "_").first.map(String.init)?.lowercased() ?? language.lowercased()
    return switch base {
      case "ar": [.zero, .one, .two, .few, .many, .other]
      case "be": [.one, .few, .many, .other]
      case "bm": [.other]
      case "bo": [.other]
      case "br": [.one, .two, .few, .many, .other]
      case "bs": [.one, .few, .other]
      case "cs": [.one, .few, .many, .other]
      case "cy": [.zero, .one, .two, .few, .many, .other]
      case "dsb": [.one, .two, .few, .other]
      case "dz": [.other]
      case "ga": [.one, .two, .few, .many, .other]
      case "gd": [.one, .two, .few, .other]
      case "gv": [.one, .two, .few, .many, .other]
      case "he": [.one, .two, .many, .other]
      case "hr": [.one, .few, .other]
      case "hsb": [.one, .two, .few, .other]
      case "id": [.other]
      case "ig": [.other]
      case "ii": [.other]
      case "iu": [.one, .two, .other]
      case "ja": [.other]
      case "kde": [.other]
      case "kea": [.other]
      case "km": [.other]
      case "ko": [.other]
      case "ksh": [.zero, .one, .other]
      case "kw": [.one, .two, .other]
      case "lag": [.zero, .one, .other]
      case "lkt": [.other]
      case "lo": [.other]
      case "lt": [.one, .few, .many, .other]
      case "lv": [.zero, .one, .other]
      case "ms": [.other]
      case "mt": [.one, .few, .many, .other]
      case "my": [.other]
      case "naq": [.one, .two, .other]
      case "pl": [.one, .few, .many, .other]
      case "ro": [.one, .few, .other]
      case "ru": [.one, .few, .many, .other]
      case "sah": [.other]
      case "se": [.one, .two, .other]
      case "ses": [.other]
      case "sg": [.other]
      case "shi": [.one, .few, .other]
      case "sk": [.one, .few, .many, .other]
      case "sl": [.one, .two, .few, .other]
      case "smn": [.one, .two, .other]
      case "sr": [.one, .few, .other]
      case "th": [.other]
      case "to": [.other]
      case "uk": [.one, .few, .many, .other]
      case "vi": [.other]
      case "yo": [.other]
      case "yue": [.other]
      case "zh": [.other]
      case "ars": [.zero, .one, .two, .few, .many, .other]
      case "sa": [.one, .two, .other]
      case "sat": [.one, .two, .other]
    default: [.one, .other]
    }
  }
}
