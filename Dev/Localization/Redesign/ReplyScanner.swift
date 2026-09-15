//
//  ReplyScanner.swift
//  Dev
//
//  Created by Dmitry on 15.09.26.
//
//  Reading a reply: the rows a model answered, and the moment each one is COMPLETE.
//
//  A reply's shape is the payload's shape (10.15): an array of `{"id": <position>,
//  "text": <value>}` rows. What a model actually writes is looser than that, and every
//  way it drifts is the same problem read once — find the objects the reply holds, take
//  the `(id, text)` pair out of each, and keep every row that CLOSED, whatever the text
//  after it did:
//
//    · a plain array of rows, in a markdown fence or with prose around it,
//    · a PLURAL answer, which is an object of categories under `text`,
//    · an id-keyed object instead of an array (`{"0": "Hallo", "1": …}`), which is what
//      a model reaches for when it is told "a map of ids to translations",
//    · a wrapper (`{"translations": [...]}`) or one object per line (JSONL),
//    · a reply CUT OFF mid-answer, which leaves the array open (5.3) — the rows before
//      the cut are real output and are kept, the open one is not.
//
//  `Scanner` is that read, made INCREMENTAL on purpose. The runner feeds it the deltas of
//  a streamed reply and writes the rows that close while the model is still writing
//  (5.5), so a long batch lands row by row instead of all at once — and a stream that
//  breaks in the middle loses only the row that was open when it broke. `rows(in:)` is
//  the same scanner over a whole reply, which is what a one-shot reading (a probe, a
//  design page, `Validator.answers`) asks for.
//
//  What this deliberately does NOT do: it never invents a row. An object that carries an
//  `id` is a ROW and nothing else (an id with no usable text answers nothing), a value
//  that is neither a string nor an object of strings is not an answer, and an id no item
//  stands behind is left for the validator to report as invented (5.3).

import Foundation

extension Translation.Validator {
  /// One row of an answer: the id the model echoed and the text it answered with, in
  /// the shape the wire used — a flat value as its own text, an object of plural
  /// categories as its own JSON (10.15, "a reply's text mirrors the payload body").
  struct Row: Equatable {
    let id: String
    let text: String
  }

  /// A reply read as it arrives. `feed` takes what has been written since the last
  /// call and answers with the rows that just closed, in the order they closed; a row
  /// the model repeats REPLACES the one it echoed before (the last answer for an id is
  /// the answer), so a correction later in a reply is not lost behind an earlier one.
  struct Scanner {
    /// Everything fed so far. A character array rather than a `String` because the
    /// scan holds a cursor across calls, and appending to a `String` would invalidate
    /// every index into it.
    private var buffer: [Character] = []
    /// How far the scan has read. Only ever moves forward: each character is looked at
    /// once, however many chunks it arrives in.
    private var cursor = 0
    private var inString = false
    private var escaped = false
    /// Brace depth of the object being read: 0 means "not inside one", which is also
    /// where a top-level object is emitted.
    private var depth = 0
    private var objectStart: Int?
    /// A container — array or object — has been opened at least once. What tells a
    /// reply that was CUT from a model that answered prose and stopped.
    private var opened = false

    /// Every row the reply has produced so far, in the order it produced them. A row the
    /// model repeats REPLACES the one it echoed before — through `positions`, so the order
    /// of the answer survives the correction.
    private var rows: [Row] = []
    /// Row id -> its position in `rows`, so a repeated id replaces its row in place.
    private var positions: [String: Int] = [:]

    init() {}

    /// The rows that closed in this chunk — the caller's cue to write them (5.5).
    mutating func feed(_ chunk: String) -> [Row] {
      buffer.append(contentsOf: chunk)
      return scan(final: false)
    }

    /// The same, for a reply that has ENDED. A fence line the reply stopped inside is
    /// dropped rather than waited for, so the last row of a fenced reply is not lost to
    /// a missing newline.
    mutating func finish() -> [Row] {
      scan(final: true)
    }

    /// The reply was CUT OFF: its structure never closed — or never opened at all, which
    /// is a model that answered prose instead of a row set. Distinguished from a bad row
    /// because the right response differs: a cut reply is re-asked in halves, a bad row
    /// is reported (5.3).
    var isCut: Bool {
      !opened || depth > 0 || inString
    }

    // MARK: - the scan

    private mutating func scan(final: Bool) -> [Row] {
      var found: [Row] = []
      while cursor < buffer.count {
        let character = buffer[cursor]
        if inString {
          if escaped {
            escaped = false
          } else if character == "\\" {
            escaped = true
          } else if character == "\"" {
            inString = false
          }
          cursor += 1
          continue
        }
        // A markdown fence is prose around the JSON, never part of it — and it is only
        // prose while nothing is open (a backtick inside a translation is text, and the
        // string state above already covers that case). Only the MARKER is skipped:
        // a model that opens a fence and starts the array on the same line is answering,
        // and skipping its whole line would eat the answer.
        if character == "`", depth == 0 {
          let rest = buffer[cursor...]
          if rest.count < 3, rest.allSatisfy({ $0 == "`" }), !final { break }
          if rest.count >= 3, rest.prefix(3).allSatisfy({ $0 == "`" }) {
            skipFenceMarker()
            continue
          }
        }
        switch character {
        case "\"":
          inString = true
        case "{":
          if depth == 0 { objectStart = cursor }
          depth += 1
          opened = true
        case "}":
          depth -= 1
          // Only a brace that CLOSES an outermost object ends it: a nested object's
          // brace is part of its parent, and treating it as the end would forget where
          // the parent began (a wrapper, or a plural answer under `text`).
          if depth <= 0, let start = objectStart {
            emit(from: start, through: cursor, into: &found)
            depth = 0
            objectStart = nil
          }
        case "[":
          opened = true
        default:
          break
        }
        cursor += 1
      }
      return found
    }

    /// Skips a fence MARKER: the three backticks and the language word some models put
    /// after them (`json`). The rest of the line is left to the scan, because the array
    /// may start on it.
    private mutating func skipFenceMarker() {
      cursor = min(cursor + 3, buffer.count)
      while cursor < buffer.count, buffer[cursor].isLetter { cursor += 1 }
    }

    /// One complete object, read as rows. A row object answers one row; anything else is
    /// read as a map of id -> answer, which is also how a wrapper's own list is reached.
    private mutating func emit(from start: Int, through end: Int, into found: inout [Row]) {
      guard start <= end, end < buffer.count else { return }
      let text = String(buffer[start...end])
      guard let parsed = Self.object(from: text) else { return }
      for row in Self.rows(in: parsed) {
        if let position = positions[row.id] {
          rows[position] = row
        } else {
          positions[row.id] = rows.count
          rows.append(row)
        }
        found.append(row)
      }
    }

    // MARK: - one object

    /// The rows one parsed object carries.
    ///
    /// An object with an `id` IS a row, and nothing else is read out of it: if its text
    /// is unusable the answer is unusable, and reading its other members as an id map
    /// would turn `{"id": 0, "text": ""}` into a row called `id` with the answer `0`.
    ///
    /// Everything else is a map: each member whose value is a string is one id's answer,
    /// each member whose value is an object is one id's PLURAL answer (or a nested map,
    /// read as one), and each member whose value is an array is a list of further objects
    /// — which is how `{"translations": [...]}` and a JSONL reply both resolve to the
    /// rows they hold.
    static func rows(in object: [String: Any]) -> [Row] {
      if let id = idText(object["id"]) {
        guard let text = answerText(object["text"]) ?? answerText(object["translation"]) else {
          return []
        }
        return [Row(id: id, text: text)]
      }
      var rows: [Row] = []
      for key in orderedKeys(of: object) {
        guard let value = object[key] else { continue }
        if let value = value as? String {
          if let text = answerText(value) {
            rows.append(Row(id: key, text: text))
          }
          continue
        }
        if let value = value as? [String: Any] {
          if idText(value["id"]) != nil {
            rows.append(contentsOf: self.rows(in: value))
          } else if let text = answerText(value) {
            rows.append(Row(id: key, text: text))
          }
          continue
        }
        if let value = value as? [Any] {
          for element in value {
            guard let nested = element as? [String: Any] else { continue }
            rows.append(contentsOf: self.rows(in: nested))
          }
        }
      }
      return rows
    }

    /// A map's members in a stable order: an id-keyed object is read in id order when
    /// every key is a number (which is what the ids are), and in lexicographic order
    /// otherwise — a dictionary out of `JSONSerialization` carries no order of its own.
    private static func orderedKeys(of object: [String: Any]) -> [String] {
      let keys = object.keys
      let numbers = keys.compactMap(Int.init)
      guard numbers.count == keys.count else { return keys.sorted() }
      return keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }

    /// A parsed JSON object, when the text is one. A trailing comma before the closing
    /// brace is dropped first: it is the one JSON defect models produce often enough to
    /// be worth repairing, and it is repaired on TEXT (never inside a string).
    private static func object(from text: String) -> [String: Any]? {
      guard text.hasPrefix("{") else { return nil }
      let cleaned = droppingTrailingCommas(text)
      guard let data = cleaned.data(using: .utf8) else { return nil }
      return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The text without a comma that sits immediately before a closing brace or bracket.
    /// String state is tracked so a comma inside a translation is left alone.
    static func droppingTrailingCommas(_ text: String) -> String {
      var out: [Character] = []
      var inString = false
      var escaped = false
      for character in text {
        if inString {
          if escaped {
            escaped = false
          } else if character == "\\" {
            escaped = true
          } else if character == "\"" {
            inString = false
          }
          out.append(character)
          continue
        }
        if character == "\"" { inString = true }
        if character == "}" || character == "]" {
          while let last = out.last, last == " " || last == "\n" || last == "\t" || last == "," {
            out.removeLast()
          }
        }
        out.append(character)
      }
      return String(out)
    }

    /// An id as the text it means: the model may echo a position as a number or as a
    /// string, and both address the same row.
    static func idText(_ any: Any?) -> String? {
      if let text = any as? String { return text }
      if let number = any as? NSNumber { return number.stringValue }
      return nil
    }

    /// A value as the text the wire used: a string as it is, an object of plural
    /// categories as its own JSON (which `Validator.decode` reads back). An empty answer
    /// is not an answer, so it is dropped here and its id is left unanswered.
    static func answerText(_ any: Any?) -> String? {
      if let text = any as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      }
      if let object = any as? [String: Any], !object.isEmpty,
        let data = try? JSONSerialization.data(
          withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
      {
        let text = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
      }
      return nil
    }
  }

  /// Every row a whole reply holds, in the order they closed.
  static func rows(in raw: String) -> [Row] {
    var scanner = Scanner()
    return scanner.feed(raw) + scanner.finish()
  }
}
