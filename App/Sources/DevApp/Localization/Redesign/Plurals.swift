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
nonisolated struct Plurals: Hashable, Sendable {
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
nonisolated struct Plural: Hashable, Identifiable, Sendable {
  var rule: Rule
  var value: String
  var id: Rule { rule }
  enum Rule: String, Sendable {
    case zero, one, two, few, many, other
  }
  /// The categories a language uses: `PluralRules`, the one table (generated from ICU, which is what
  /// Foundation selects a form with), read here rather than copied. A region-tagged code reduces to its
  /// base ("pt-BR", "zh-Hans" and "es-419" are pt, zh and es).
  static func rules(language: String) -> [Rule] {
    PluralRules.categories(for: language).compactMap(Rule.init(rawValue:))
  }
}
