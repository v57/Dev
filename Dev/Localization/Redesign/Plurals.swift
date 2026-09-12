//
//  Plurals.swift
//  Dev
//
//  Created by Dmitry on 12.09.26.
//

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
}
struct Plural: Hashable {
  var rule: Rule
  var value: String
  enum Rule: String {
    case zero, one, two, few, many, other
  }
  static func rules(language: String) -> [Rule] {
    switch language {
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
