//
//  ReplyScanner.swift
//  Dev
//
//  Created by Dmitry on 15.09.26.
//
//  Reading a reply: the rows a model answered, and the moment each one is COMPLETE.
//
//  A reply is LINES (`Prompt`'s wire contract): `<id><TAB><text>` for a string,
//  `<id>.<form><TAB><text>` for one plural form, and a last line `END`. A line is complete
//  when its line break arrives, so a flat row is written the moment its line ends; a plural
//  row is complete when a line for another id arrives (or END, or the reply ends), and it
//  is handed on as a JSON object of form -> text, which is what `Validator.decode` reads.
//
//  What a model actually writes is looser than that, and the scanner reads the drift it
//  has seen rather than rejecting it:
//
//    · a code fence around the answer, prose before it, blank lines,
//    · a space (or `: `) instead of the tab after the id,
//    · the language echoed between the id and the text (`3<TAB>de<TAB>…`, a row pass
//      answering in the shape it was shown),
//    · a reply CUT OFF: with no END it is cut, and every row completed before the cut is
//      real output and kept.
//
//  What this deliberately does NOT do: it never invents a row. A line whose head is not a
//  number is prose and is skipped, an empty answer answers nothing, and an id no item stands
//  behind is left for the validator to report as invented (5.3).

import Foundation

extension Translation.Validator {
  /// One row of an answer: the id the model echoed and the text it answered with — a flat
  /// value as its own text, a plural answer as a JSON object of its forms.
  struct Row: Equatable {
    let id: String
    let text: String
  }

  /// A reply read as it arrives. `feed` takes what has been written since the last call and
  /// answers with the rows that just closed, in the order they closed. A row the model
  /// repeats is answered again: the last answer for an id is the answer.
  struct Scanner {
    /// The current line, not yet ended.
    private var line = ""
    /// The plural row being collected: its id and its forms in the order they came.
    private var plural: (id: String, forms: [(String, String)])?
    /// The reply said END: everything after it is not an answer.
    private(set) var ended = false

    init() {}

    /// The rows that closed in this chunk — the caller's cue to write them (5.5).
    mutating func feed(_ chunk: String) -> [Row] {
      var found: [Row] = []
      for character in chunk {
        guard !ended else { break }
        if character == "\n" || character == "\r\n" || character == "\r" {
          read(line, into: &found)
          line = ""
        } else {
          line.append(character)
        }
      }
      return found
    }

    /// The same, for a reply that has ENDED: the last line needs no line break, and a
    /// plural row still open is complete.
    mutating func finish() -> [Row] {
      var found: [Row] = []
      if !ended, !line.isEmpty {
        read(line, into: &found)
        line = ""
      }
      flushPlural(into: &found)
      return found
    }

    /// The reply was CUT OFF: it never said END. A model that answered prose instead of
    /// lines is cut too, which is right — a cut reply's unanswered rows are re-asked.
    var isCut: Bool { !ended }

    // MARK: - one line

    private mutating func read(_ raw: String, into found: inout [Row]) {
      let text = raw.trimmingCharacters(in: .whitespaces)
      if text == "END" || text == "END." {
        flushPlural(into: &found)
        ended = true
        return
      }
      guard let parsed = Self.parse(text) else { return }
      if let form = parsed.form {
        if plural?.id != parsed.id {
          flushPlural(into: &found)
          plural = (parsed.id, [])
        }
        plural?.forms.append((form, parsed.text))
        return
      }
      flushPlural(into: &found)
      let answer = parsed.text.trimmingCharacters(in: .whitespaces)
      guard !answer.isEmpty else { return }
      found.append(Row(id: parsed.id, text: answer))
    }

    private mutating func flushPlural(into found: inout [Row]) {
      guard let open = plural else { return }
      plural = nil
      var object: [String: String] = [:]
      for (form, text) in open.forms {
        let value = text.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty { object[form] = value }
      }
      guard !object.isEmpty,
        let data = try? JSONSerialization.data(
          withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
        let json = String(data: data, encoding: .utf8)
      else { return }
      found.append(Row(id: open.id, text: json))
    }

    /// One answer line's parts: the id, the plural form when the id names one, and the
    /// text. Nil for a line that is not an answer (prose, a fence, a blank line).
    static func parse(_ line: String) -> (id: String, form: String?, text: String)? {
      var rest = Substring(line)
      let digits = rest.prefix { $0.isASCII && $0.isNumber }
      guard !digits.isEmpty else { return nil }
      rest = rest.dropFirst(digits.count)
      var form: String?
      if rest.first == "." {
        let name = rest.dropFirst().prefix { $0.isASCII && $0.isLetter }
        if !name.isEmpty, Plural.Rule(rawValue: String(name)) != nil {
          form = String(name)
          rest = rest.dropFirst(1 + name.count)
        }
      }
      // The separator: a tab as asked, or what a model writes instead of one.
      if rest.first == "\t" {
        rest = rest.dropFirst()
      } else if rest.hasPrefix(": ") || rest.hasPrefix(". ") || rest.hasPrefix(") ") {
        rest = rest.dropFirst(2)
      } else if rest.first == " " {
        rest = rest.drop { $0 == " " }
      } else {
        return nil
      }
      // `<lang><TAB><text>`: the language echoed back from a row pass.
      if let tab = rest.firstIndex(of: "\t") {
        let head = rest[..<tab]
        if head.count <= 12, !head.isEmpty,
          head.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
          head.first?.isLetter == true
        {
          rest = rest[rest.index(after: tab)...]
        }
      }
      return (String(digits), form, String(rest))
    }
  }

  /// Every row a whole reply holds, in the order they closed.
  static func rows(in raw: String) -> [Row] {
    var scanner = Scanner()
    return scanner.feed(raw) + scanner.finish()
  }
}
