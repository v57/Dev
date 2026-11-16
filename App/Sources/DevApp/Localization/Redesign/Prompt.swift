//
//  Prompt.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  Every prompt is assembled here, because the block ORDER is a cache contract: what is
//  the same for every batch of a run comes first, so a provider's prompt cache covers it.
//
//  THE WIRE CONTRACT
//
//    A language batch : system, then the user message: L0 (CONTEXT — GLOBAL, CONTEXT —
//                       PROJECT, identical for every language), L1 (TARGET LANGUAGE and its
//                       STYLE, identical for every batch of one language), then what this
//                       batch alone carries (GLOSSARY, KEEP) and ITEMS last.
//    A row batch      : system, L0, then ROWS: each row's English, the settled translations
//                       as references and the machine ones it may correct.
//
//  Both are LINES, not JSON: an item is `<id><TAB><English>` (a plural form
//  `<id>.<form><TAB><English>`) with indented `note:`, `max:`, `forms:`, `now:` and
//  `problem:` lines under it, and the answer is `<id><TAB><text>` per line, then `END`.
//  JSON spent about as many tokens on keys, quotes and braces as on the strings, and the
//  answer is where tokens cost most. A real line break or tab inside a text travels as the
//  two characters `\n` / `\t` (`escaped`), and the reader turns them back (`unescaped`).
//
//  The KEY is never sent: the ids the model echoes are the items' POSITIONS in the batch,
//  and the key stays app-side, where it applies a reply, addresses memory and journals the
//  edit. A row batch answers only the ids it corrects; a language batch answers every id.

import Foundation

extension Translation {
  enum Prompt {
    // MARK: - requests

    /// A language batch: every item of one target language, answered in full.
    static func languageBatch(language: String, items: [Run.Item], project: Project) -> Request {
      languageRequest(
        language: language, items: items, shared: sharedBlocks(project: project),
        style: style(language: language, project: project),
        glossary: glossary(language: language, items: items, project: project),
        keep: keep(items))
    }

    /// The language batch from its parts, with no project: what the design preview and the
    /// tests assemble, and what `languageBatch` hands its project's parts to.
    static func languageRequest(
      language: String, items: [Run.Item], shared: [String], style: String, glossary: [String],
      keep: [String] = []
    ) -> Request {
      var stable = ["TARGET LANGUAGE\n\(Languages.name(of: language)) (\(language))"]
      if !style.isEmpty { stable.append("STYLE\n\(style)") }
      var varying: [String] = []
      if !glossary.isEmpty { varying.append("GLOSSARY\n" + glossary.joined(separator: "\n")) }
      if !keep.isEmpty { varying.append("KEEP\n" + keep.joined(separator: ", ")) }
      varying.append("ITEMS\n" + itemLines(items, language: language))
      return request(
        system: translateSystem, prefix: shared + stable, rest: varying, ids: positions(count: items.count))
    }

    /// A row batch: the rows' machine translations, each with every settled translation of
    /// its row as the reference, answered with the corrections only.
    ///
    /// `items` are the slots the pass may correct, grouped by row in the order given. The
    /// settled columns are read off the project here rather than carried as items: nothing
    /// is written to them, so nothing is asked about them.
    static func rowBatch(items: [Run.Item], project: Project) -> Request {
      rowRequest(items: items, shared: sharedBlocks(project: project)) { key in
        (project.row(key)?.targets ?? []).compactMap { slot in
          guard !slot.target.isEmpty, slot.status == .verified || slot.status == .imported else { return nil }
          return (slot.language, slot.target.catalogValue)
        }
      }
    }

    /// The row batch from its parts: `settled` answers a row's settled translations.
    static func rowRequest(
      items: [Run.Item], shared: [String], settled: (String) -> [(language: String, value: String)]
    ) -> Request {
      var rows: [(key: String, item: Run.Item, editable: [(id: Int, item: Run.Item)])] = []
      for (index, item) in items.enumerated() {
        if let last = rows.indices.last, rows[last].key == item.key {
          rows[last].editable.append((index, item))
        } else {
          rows.append((item.key, item, [(index, item)]))
        }
      }
      var lines: [String] = []
      for row in rows {
        lines.append("ROW\t" + escaped(row.item.payloadSource.catalogValue))
        lines += notes(of: row.item)
        let editable = Set(row.editable.map { $0.item.language ?? "" })
        for slot in settled(row.key) where !editable.contains(slot.language) {
          lines.append("\(slot.language)\t\(escaped(slot.value))")
        }
        for (id, item) in row.editable {
          lines.append("\(id)\t\(item.language ?? "")\t\(escaped(item.target.catalogValue))")
        }
      }
      return request(
        system: rowSystem, prefix: shared, rest: ["ROWS\n" + lines.joined(separator: "\n")],
        ids: positions(count: items.count))
    }

    /// A request as the router sends it. `ids` is what the validator matches the reply
    /// against: the items' POSITIONS in the batch, as strings — never keys.
    ///
    /// `prefix` is the stable head of the user message (L0, and a language batch's L1),
    /// and `cacheablePrefix` the system prompt plus that head, laid out exactly as sent:
    /// what a provider's prompt cache can hold, and what the telemetry counts.
    struct Request {
      var system: String = ""
      var user: String = ""
      var ids: [String] = []
      var cacheablePrefix: String = ""
      var prefix: String = ""
    }

    // MARK: - assembly

    static let blockSeparator = "\n\n"

    private static func request(system: String, prefix: [String], rest: [String], ids: [String]) -> Request {
      Request(
        system: system,
        user: (prefix + rest).joined(separator: blockSeparator),
        ids: ids,
        cacheablePrefix: ([system] + prefix).joined(separator: blockSeparator),
        prefix: prefix.joined(separator: blockSeparator))
    }

    private static func positions(count: Int) -> [String] {
      (0..<count).map { String($0) }
    }

    // MARK: - items

    /// The ITEMS lines of a language batch, in batch order.
    static func itemLines(_ items: [Run.Item], language: String) -> String {
      var lines: [String] = []
      var file = ""
      for (index, item) in items.enumerated() {
        if !item.file.isEmpty, item.file != file {
          lines.append("# \(item.file)")
        }
        file = item.file
        switch item.payloadSource {
        case .value(let text):
          lines.append("\(index)\t\(escaped(text))")
        case .plural(let forms):
          for form in forms.values where !form.value.isEmpty {
            lines.append("\(index).\(form.rule.rawValue)\t\(escaped(form.value))")
          }
        }
        lines += notes(of: item)
        if expectsPlural(item) {
          lines.append("  forms: " + Plurals(language: language).values.map(\.rule.rawValue).joined(separator: " "))
        }
        switch item.target {
        case .value(let text) where !text.isEmpty:
          lines.append("  now: \(escaped(text))")
        case .plural(let forms):
          for form in forms.values where !form.value.isEmpty {
            lines.append("  now.\(form.rule.rawValue): \(escaped(form.value))")
          }
        default:
          break
        }
        if !item.problem.isEmpty { lines.append("  problem: \(escaped(item.problem))") }
      }
      return lines.joined(separator: "\n")
    }

    /// The `note:` and `max:` lines an item or a row carries.
    private static func notes(of item: Run.Item) -> [String] {
      var lines: [String] = []
      let comment = item.comment.trimmingCharacters(in: .whitespacesAndNewlines)
      if !comment.isEmpty { lines.append("  note: " + escaped(clamp(comment, to: Limits.commentCharacters))) }
      if item.maxWidth > 0 { lines.append("  max: \(item.maxWidth)") }
      return lines
    }

    /// A string whose source or target is plural is answered form by form.
    static func expectsPlural(_ item: Run.Item) -> Bool {
      if case .plural = item.target { return true }
      if case .plural = item.source { return true }
      return false
    }

    // MARK: - escapes

    /// A text as one line: a real line break or tab becomes the two characters `\n` / `\t`.
    static func escaped(_ text: String) -> String {
      text.replacingOccurrences(of: "\r\n", with: "\\n")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// An answer's text with `\n` and `\t` turned back into a line break and a tab — only
    /// those the SOURCE had, so a source that spells a backslash and an n keeps them.
    static func unescaped(_ text: String, like source: String) -> String {
      var text = text
      if source.contains("\n") { text = text.replacingOccurrences(of: "\\n", with: "\n") }
      if source.contains("\t") { text = text.replacingOccurrences(of: "\\t", with: "\t") }
      return text
    }

    // MARK: - L0, L1 and the reference

    /// L0: identical for every target language, which is what makes it cacheable.
    private static func sharedBlocks(project: Project) -> [String] {
      var blocks: [String] = []
      appendContext(
        &blocks, title: "CONTEXT — GLOBAL", text: project.global.context.context, limit: Limits.globalContext)
      appendContext(
        &blocks, title: "CONTEXT — PROJECT", text: project.context.context, limit: Limits.projectContext)
      return blocks
    }

    /// The language's style rules: its document when the project has written one, else the
    /// built-in rules for the language (`StyleRules`).
    static func style(language: String, project: Project) -> String {
      let written = clampTail(
        deduplicated(project.language(language)?.context.context ?? ""), to: Limits.languageContext)
      return written.isEmpty ? StyleRules.rules(for: language) : written
    }

    /// The terms of this batch the project — or a human in any project — already
    /// translated, as `English = translation` lines: a short string elsewhere in the
    /// project (up to `glossaryWords` words) whose every word is in the batch, and the
    /// gold translation memory holds for the batch's short phrases. Settled values come
    /// first, the machine's own after; the batch's own rows are left out, since they are
    /// what is being asked. Recomputed per batch because a write-back changes the column.
    static func glossary(language: String, items: [Run.Item], project: Project) -> [String] {
      let keys = Set(items.map(\.key))
      let texts = items.map { everything($0.payloadSource) }
      let words = Set(texts.flatMap(Self.words))
      var settled: [(String, String)] = []
      var machine: [(String, String)] = []
      for row in project.data where row.isCatalogRow && !keys.contains(row.key) {
        guard case .value(let source) = row.content, (1...glossaryWords).contains(Self.words(source).count),
          source.count <= 40, Self.words(source).allSatisfy(words.contains),
          let slot = row.target(language), case .value(let value) = slot.target, !value.isEmpty, value != source
        else { continue }
        switch slot.status {
        case .verified: settled.append((source, value))
        case .translated: machine.append((source, value))
        // The imported database matches a string by its English alone, across every app it
        // was taken from: a one-word label there is often another app's sense of the word
        // ("Audio" as headphones), and as a glossary term it would carry that sense into
        // every sentence of the batch.
        case .imported, .stale, .needsTranslate, .ignore: break
        }
      }
      // Gold memory for the batch's short phrases, from any project.
      var remembered: [(String, String)] = []
      let memory = Memory(project: project)
      var asked = Set<String>()
      for phrase in texts.flatMap({ phrases(in: $0) }) where asked.count < 400 {
        guard asked.insert(phrase).inserted,
          let entry = try? memory.resolve(source: phrase, language: language), entry.grade == .gold,
          !entry.value.isEmpty, entry.value != phrase
        else { continue }
        remembered.append((phrase, entry.value))
      }
      var seen = Set<String>()
      var lines: [String] = []
      for (source, value) in settled + remembered + machine where seen.insert(source.lowercased()).inserted {
        lines.append(escaped("\(source) = \(value)"))
        if lines.count == Limits.glossary { break }
      }
      return lines
    }

    /// Up to this many words make a glossary term.
    static let glossaryWords = 3

    /// The lowercased words of a text, placeholders left out.
    static func words(_ text: String) -> [String] {
      text.split { !$0.isLetter && $0 != "'" }.map { $0.lowercased() }.filter { $0.count > 1 || $0 == "a" }
    }

    /// The phrases of one or two words in a text that read as a term (`Open Project`,
    /// `Settings`): a run of letters, each word starting uppercase or the whole text short.
    static func phrases(in text: String) -> [String] {
      let tokens = text.split { !$0.isLetter }.map(String.init)
      guard !tokens.isEmpty else { return [] }
      var found: [String] = []
      for (index, token) in tokens.enumerated() where token.first?.isUppercase == true {
        found.append(token)
        if index + 1 < tokens.count, tokens[index + 1].first?.isUppercase == true {
          found.append(token + " " + tokens[index + 1])
        }
      }
      return found
    }

    /// The names a batch carries that stay as written in every language: mixed-case words
    /// (`iCloud`, `GitHub`, `macOS`) and acronyms (`SSH`, `URLs`), from the batch's English.
    static func keep(_ items: [Run.Item]) -> [String] {
      var found = Set<String>()
      for item in items {
        let text = everything(item.payloadSource)
        for token in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
          let word = String(token)
          guard word.count >= 2, word.first?.isLetter == true else { continue }
          let letters = word.filter(\.isLetter)
          let upper = letters.filter(\.isUppercase).count
          let mixed = upper > 0 && upper < letters.count && word.dropFirst().contains(where: \.isUppercase)
          let acronym = letters.count >= 2 && (upper == letters.count || (upper == letters.count - 1 && word.hasSuffix("s")))
          guard mixed || acronym, !translatedAcronyms.contains(word) else { continue }
          found.insert(word)
        }
      }
      return found.sorted().prefix(Limits.keep).map { $0 }
    }

    /// Acronyms languages do translate (`KI`, `IA`), or that are words.
    static let translatedAcronyms: Set<String> = ["OK", "AI", "AM", "PM", "TV", "ID", "IDs"]

    /// Every text a body carries.
    static func everything(_ body: StringBody) -> String {
      switch body {
      case .value(let text): text
      case .plural(let plural): plural.values.map(\.value).joined(separator: " ")
      }
    }

    // MARK: - context blocks

    /// A document body deduplicated line by line, order preserved.
    private static func deduplicated(_ text: String) -> String {
      var seen = Set<String>()
      var kept: [String] = []
      for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, seen.insert(line).inserted else { continue }
        kept.append(line)
      }
      return kept.joined(separator: "\n")
    }

    /// Appends a titled document, keeping its TAIL when it outgrows its cap: documents are
    /// append-ordered, so the oldest lines are what must go. An empty one is omitted.
    private static func appendContext(_ blocks: inout [String], title: String, text: String, limit: Int) {
      let body = deduplicated(text)
      guard !body.isEmpty else { return }
      blocks.append("\(title)\n\(clampTail(body, to: limit))")
    }

    /// Character-prefix truncation on grapheme boundaries.
    static func clamp(_ text: String, to limit: Int) -> String {
      guard text.count > limit else { return text }
      return String(text.prefix(limit)) + "…"
    }

    /// Line-aware, tail-preserving truncation. A single line longer than the whole budget
    /// keeps its own tail, so the block is bounded and never empty.
    private static func clampTail(_ text: String, to limit: Int) -> String {
      guard text.count > limit else { return text }
      var kept: [String] = []
      var used = 0
      for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
        let line = String(rawLine)
        let cost = line.count + (kept.isEmpty ? 0 : 1)
        if kept.isEmpty, cost > limit {
          kept.append(String(line.suffix(limit)))
          break
        }
        guard used + cost <= limit else { break }
        kept.append(line)
        used += cost
      }
      return kept.reversed().joined(separator: "\n")
    }

    // MARK: - system prompts

    /// The translate system prompt. It names no language, so it is byte-identical for every
    /// batch of a run: the outermost cacheable prefix.
    static let translateSystem = """
      You translate the user-interface strings of a software project from English into the \
      language named in TARGET LANGUAGE.

      ITEMS has one string per line: `<id><TAB><English>`. A plural string has one line per \
      English form: `<id>.<form><TAB><English>`. A line `# <path>` names the source file the \
      strings after it come from: strings of one file are on one screen. Indented lines under \
      a string describe it:
        note: where it appears
        max: the most characters its translation should take
        forms: the plural forms to write in the target language
        now: its current translation, to keep if right or improve
        problem: why your earlier answer was rejected

      Answer with one line per string, `<id><TAB><translation>`, in the same order; for a \
      plural string, one line per form named in `forms`: `<id>.<form><TAB><translation>`. \
      Then a last line: END. Write nothing else: no notes, no code fences.

      Rules:
      - Keep every placeholder (%@, %lld, %1$@, {name}), URL, markup and code token exactly \
      as written; never add or drop one.
      - \\n stands for a line break and \\t for a tab: write them the same way, never as a \
      real line break.
      - In a plural form, keep the number's placeholder unless the form stands for exactly \
      one number (like English "one").
      - Follow CONTEXT and STYLE, use the GLOSSARY's translations for the terms it covers \
      (inflected, and capitalized as the sentence needs), and keep the KEEP terms as written.
      - Translate as user-interface text: natural, concise and consistent with the platform's \
      conventions in that language. Keep a string within its max when you can without \
      losing meaning.
      - When a string is ambiguous, choose the most natural reading. Never ask or refuse.

      Example, into German:
      ITEMS
      0\tOpen Project
      1\tDelete “%@”?
        note: confirmation title
      2.one\t%lld file
      2.other\t%lld files
        forms: one other
      Answer:
      0\tProjekt öffnen
      1\t„%@“ löschen?
      2.one\t%lld Datei
      2.other\t%lld Dateien
      END
      """

    /// The row pass: corrections only, across the languages of each row.
    static let rowSystem = """
      You review the translations of a software project's user-interface strings across \
      languages.

      ROWS lists strings. Each starts with `ROW<TAB><English>`, with indented `note:` and \
      `max:` lines describing it, and its translations follow, one per line:
        `<language><TAB><translation>`: settled by a person. Correct; use it as the reference.
        `<id><TAB><language><TAB><translation>`: machine-made. You may correct it.

      Correct a machine translation only when it is wrong: the wrong meaning for this \
      string, English left untranslated, a placeholder lost or changed, broken grammar, or \
      a term that contradicts the settled translations of its row. Never rephrase a correct \
      one.

      Answer with one line per correction, `<id><TAB><corrected translation>`, then a last \
      line: END. When nothing needs correcting, answer only END. Write nothing else.

      Rules:
      - Keep every placeholder (%@, %lld, %1$@, {name}), URL, markup and code token exactly \
      as written.
      - \\n stands for a line break and \\t for a tab: write them the same way.
      - Follow CONTEXT.
      """
  }
}
