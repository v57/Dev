//
//  Prompt.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  Every prompt in the redesign is assembled here, because the block ORDER is a
//  cache contract: reordering L0/L1/L2 silently destroys the provider cache hit
//  rate, and the run reports a cached-token share that would then read zero.
//  Semantics are in "Design notes.md", section 4.3; the WORDING follows
//  Dev/Translation/Backends/ContextPromptBuilder.swift, which is read as the
//  reference and never called.
//
//  THE WIRE CONTRACT
//
//    A language batch : L0 (system + CONTEXT — GLOBAL + CONTEXT — PROJECT)
//                       L1 (TARGET LANGUAGE + its lesson document + the register
//                       sample) then L2 (ITEMS), the payload last.
//    A row batch      : L0 then ITEMS, each item naming its own language. There is
//                       no L1 block and no register sample of its own — the row's
//                       settled columns ARE its reference (4.6).
//
//  An item's fields are the CLOSED SET `comment`, `maxWidth`, `source`, `target`,
//  plus `language` on a row batch. The KEY is never sent: the ids the model echoes
//  are the items' POSITIONS in the batch, and the key stays app-side, where it
//  applies a reply, addresses memory and journals the edit.
//
//  A BODY on the wire is either a string (a flat value) or a JSON object of plural
//  category -> text. A plural slot that has no value yet travels as the EMPTY
//  SKELETON of the target language (every category the language has, empty), so the
//  model is told which forms it is filling instead of guessing which ones exist. A
//  reply's "text" mirrors the body it answers.
//
//  Reply shapes, per request: `translate`/`row`/`repair` answer a JSON array of
//  `{"id": <position>, "text": <body>}`, `review` answers
//  `{"id": <position>, "valid": <bool>, "fix": <body>}`, and `learnFold`/`compress`
//  answer document TEXT rather than a per-id map — their `ids` is therefore empty.

import Foundation

extension Translation {
  enum Prompt {
    // MARK: - language batches

    /// A language batch: L0 (system + global + project), L1 (target language +
    /// that language's lesson document + the register sample), L2 (items),
    /// payload last.
    ///
    /// Each item sends `comment`, `maxWidth`, `source` and `target` — and nothing
    /// else. The KEY is never sent: it does not matter to the translation, and the id
    /// the model echoes back is the item's position in the batch. `source` is the
    /// row's content (its key stands in when nothing was authored); `target` is the
    /// current value when there is one, or the empty plural skeleton of the target
    /// language, so the model knows which forms it is filling.
    static func languageBatch(language: String, items: [Run.Item], project: Project) -> Request {
      let l0 = sharedBlocks(project: project)
      let l1 = languageBlocks(language: language, project: project)
      let payload = json(rows(items, batchLanguage: language, namedLanguage: false))
      return request(
        system: systemPrompt(.translate),
        l0: l0,
        rest: l1 + ["ITEMS\n" + payload],
        ids: positions(count: items.count))
    }

    /// Prelearn: a machine version of a source whose human value has no machine
    /// record. Same shape as a language batch, and the reply is written to
    /// `machine` only.
    ///
    /// "Same shape" is taken literally — the same system text, the same blocks and
    /// the same payload — so the L0 prefix is byte-identical to the translate
    /// batch's and the provider cache covers both. Prelearn differs in what it
    /// WRITES, which is not the prompt's business.
    static func prelearnBatch(language: String, items: [Run.Item], project: Project) -> Request {
      languageBatch(language: language, items: items, project: project)
    }

    /// A row batch: L0 then ITEMS. The comment, the width guideline, the plural data
    /// and the target language travel per item — never the key, same as everywhere
    /// else — no L1 block exists, and neighbours are omitted by construction. Cost:
    /// the L0 block is paid once per row instead of once per language batch.
    ///
    /// EVERY language of the row is an item, settled columns included — that is what
    /// gives the request its register reference, and it is the one way a row request
    /// can learn what this project already calls things in its finished columns.
    /// The payload makes no distinction between an item that will be written and one
    /// that will not: that is decided from the slot's status when the reply is
    /// applied, so a verified slot's answer is simply discarded.
    ///
    /// Note the deviation from the current implementation: today's
    /// `ContextPromptBuilder.assembleRowBatch` has no EXISTING TRANSLATIONS section
    /// at all (its system prompt says so outright), so a row request currently gets
    /// no reference values. The redesign carries them per item INSIDE the ITEMS
    /// block, which keeps the L0 prefix byte-identical and therefore still cacheable.
    static func rowBatch(items: [Run.Item], project: Project) -> Request {
      let l0 = sharedBlocks(project: project)
      let payload = json(rows(items, batchLanguage: nil, namedLanguage: true))
      return request(
        system: systemPrompt(.row),
        l0: l0,
        rest: ["ITEMS\n" + payload],
        ids: positions(count: items.count))
    }

    // MARK: - learn

    /// The learn fold: what the model produced vs what the human settled on, into
    /// one document line per (key, source). Change-gated at the write, not here:
    /// this only builds the request.
    ///
    /// The reply is DOCUMENT TEXT, not a per-id map and not the whole document: the
    /// canonical line to append per lesson folded (one line per (key, source),
    /// `KEY<TAB>SOURCE<TAB>VALUE`, escaped), the single word `NO_CHANGE` when the
    /// document already covers every lesson it was given, and nothing else. The
    /// canonicalization in `Context.append` is what dedupes to one line per
    /// (key, source) and drops a no-op, which is why the model never has to rewrite
    /// the lines it does not touch. `ids` is empty: there is nothing to match.
    static func learnFold(language: String, lessons: [Lesson], document: String) -> Request {
      let lines: [[String: Any]] = lessons.map { lesson in
        [
          "key": lesson.key,
          "source": lesson.source,
          "comment": clamp(lesson.comment, to: Limits.commentCharacters),
          "machine": lesson.machine,
          "value": lesson.value,
        ]
      }
      let user = """
      LESSONS — what the machine produced vs what the human settled on
      \(json(lines))

      CURRENT \(language.uppercased()) DOCUMENT — \(document.count) characters, \
      budget \(Limits.languageContext)
      \(document.isEmpty ? "(the document is empty)" : document)
      """
      return Request(system: systemPrompt(.learn(language: language)), user: user)
    }

    /// The budget keeper — one call per over-budget document, never one per line.
    ///
    /// The reply is the COMPLETE rewritten document body, or the single word
    /// `NO_CHANGE` when it cannot be usefully shortened. `ids` is empty for the same
    /// reason as `learnFold`: the reply is a document, not a per-id map.
    static func compress(language: String, document: String, limit: Int) -> Request {
      let user = """
      CURRENT \(language.uppercased()) DOCUMENT — \(document.count) characters, \
      budget at most \(limit)

      \(document)
      """
      return Request(
        system: systemPrompt(.compress(language: language, limit: limit)), user: user)
    }

    // MARK: - the paid gate

    /// The single paid call: the candidates that were already in the prompt, plus
    /// `{id, valid, fix}` per rejected id.
    ///
    /// The context is the one the candidate was produced under — L0 always, and L1
    /// when the batch names exactly one language — because the gate's whole value is
    /// judging a concrete translation, not re-translating blind. A row batch is
    /// mixed-language, so no L1 block exists there and its items name their own
    /// language instead, which is also what lets the gate ask whether a candidate
    /// contradicts a SETTLED sibling (4.6): a settled column travels as an item whose
    /// candidate is the value already committed to.
    ///
    /// The candidate per id is the reply verbatim; a slot the model did not answer
    /// falls back to the value the slot already carries. `maxWidth` is carried ONLY
    /// for an item whose candidate is already over it — the one place a width
    /// guideline reaches a model through this pass is here and in the item payload.
    ///
    /// The L1 block needs a language, and a batch has one exactly when its items name
    /// one: a ROW batch names several (so its items carry their language instead, and
    /// a settled column travels as an item whose candidate is the value already
    /// committed to), and a per-language batch's items carry none by default. The
    /// caller therefore has to name the language on the items it hands the gate —
    /// `Run.Item.language` is nil on a vertical batch — or the gate is assembled
    /// without the language it is judging against.
    static func review(project: Project, items: [Run.Item], replies: [String: String]) -> Request {
      let languages = Set(items.compactMap(\.language))
      let uniform = languages.count == 1 ? languages.first : nil
      let l0 = sharedBlocks(project: project)
      let l1 = uniform.map { languageBlocks(language: $0, project: project) } ?? []

      let payload: [[String: Any]] = items.enumerated().map { index, item in
        var candidate: Any = body(item.target)
        if let reply = replies[String(index)], !reply.isEmpty {
          candidate = reply
        }
        var row: [String: Any] = [
          "id": index,
          "source": body(payloadSource(item)),
          "candidate": candidate,
        ]
        if !item.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          row["comment"] = clamp(item.comment, to: Limits.commentCharacters)
        }
        if item.maxWidth > 0, isOver(candidate, limit: item.maxWidth) {
          row["maxWidth"] = item.maxWidth
        }
        if languages.count > 1, let language = item.language {
          row["language"] = language
        }
        return row
      }

      return request(
        system: systemPrompt(.review),
        l0: l0,
        rest: l1 + ["CANDIDATES\n" + json(payload)],
        ids: positions(count: items.count))
    }

    /// One rejected id, repaired in its OWN language — never batched with the
    /// others, whose languages differ.
    ///
    /// The shape is a one-item language batch, so the repair costs the L0 and L1
    /// blocks it cannot share with anything: that is the price of one language per
    /// request. The item does not carry the validator's reason — the request has no
    /// field for it — so the system text names the defects the validator can produce
    /// (a dropped placeholder, an untranslated echo, an empty reply) and asks for a
    /// complete, correct answer.
    static func repair(item: Run.Item, language: String, project: Project) -> Request {
      let l0 = sharedBlocks(project: project)
      let l1 = languageBlocks(language: language, project: project)
      let payload = json(rows([item], batchLanguage: language, namedLanguage: false))
      return request(
        system: systemPrompt(.repair),
        l0: l0,
        rest: l1 + ["ITEMS\n" + payload],
        ids: positions(count: 1))
    }

    /// A request as the router sends it. `ids` is what the validator matches the
    /// reply against; `cacheablePrefix` is the L0 block, which is what the
    /// telemetry counts when it reports the cached share.
    ///
    /// `ids` are the items' POSITIONS in the batch, as strings — never keys. It is
    /// empty exactly when the reply is not a per-id map: `learnFold` and `compress`
    /// answer document text.
    ///
    /// `cacheablePrefix` is the leading run the provider can cache: the system
    /// prompt plus the L0 blocks, laid out exactly as the two messages are laid out,
    /// so it is a byte-prefix of what is sent. It is identical for every target
    /// language of a run, which is what makes a non-zero cached share possible; a
    /// flat zero means the prefix moved.
    struct Request {
      var system: String = ""
      var user: String = ""
      var ids: [String] = []
      var cacheablePrefix: String = ""
    }

    /// One lesson: the machine's attempt, the human's value, and the row's own
    /// context. A lesson with `machine == value` is not built — the model already
    /// agreed with the human, so there is nothing to teach.
    struct Lesson {
      let key: String
      let source: String
      let comment: String
      let machine: String
      let value: String
    }

    // MARK: - request assembly

    /// The one place the block order is expressed: L0, then the language blocks,
    /// then the payload last. `cacheablePrefix` is built from the same pieces in the
    /// same order, so what the telemetry counts is a real prefix of what is sent.
    private static func request(
      system: String,
      l0: [String],
      rest: [String],
      ids: [String]
    ) -> Request {
      Request(
        system: system,
        user: (l0 + rest).joined(separator: "\n\n"),
        ids: ids,
        cacheablePrefix: ([system] + l0).joined(separator: "\n\n"))
    }

    private static func positions(count: Int) -> [String] {
      (0..<count).map { String($0) }
    }

    // MARK: - item payload

    /// The ITEMS rows, in batch order. `batchLanguage` builds a plural skeleton when
    /// an item has no value yet and does not name its own language; `namedLanguage`
    /// emits the per-item language of a row batch.
    private static func rows(
      _ items: [Run.Item],
      batchLanguage: String?,
      namedLanguage: Bool
    ) -> [[String: Any]] {
      items.enumerated().map { index, item in
        let language = item.language ?? batchLanguage ?? ""
        var row: [String: Any] = [
          "id": index,
          "source": body(payloadSource(item)),
          "target": body(payloadTarget(item, language: language)),
        ]
        if !item.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          row["comment"] = clamp(item.comment, to: Limits.commentCharacters)
        }
        if item.maxWidth > 0 {
          row["maxWidth"] = item.maxWidth
        }
        if namedLanguage, let code = item.language {
          row["language"] = code
        }
        return row
      }
    }

    /// `source` is the row's CONTENT, not the authored source field: a row whose
    /// source unit is missing sends its KEY, because that is what the artifact itself
    /// shows (4.3). "No source" is therefore never a reason to skip a row.
    private static func payloadSource(_ item: Run.Item) -> StringBody {
      item.source.isEmpty ? .value(item.key) : item.source
    }

    /// The current value when there is one — a stale slot carries its old value — or
    /// the EMPTY PLURAL SKELETON of the target language when there is not, so the
    /// model is told which forms it is filling. The categories come from
    /// `Plurals(language:)`, which is the single table the app reads for them.
    private static func payloadTarget(_ item: Run.Item, language: String) -> StringBody {
      guard item.target.isEmpty else { return item.target }
      if case .plural = item.target { return .plural(Plurals(language: language)) }
      if case .plural = item.source { return .plural(Plurals(language: language)) }
      return item.target
    }

    /// One body as JSON: a string for a flat value, an object of category -> text for
    /// a plural one. An empty skeleton therefore travels as the same categories with
    /// empty strings, which is exactly the "fill these" signal.
    private static func body(_ body: StringBody) -> Any {
      switch body {
      case .value(let text):
        return text
      case .plural(let plural):
        var forms: [String: String] = [:]
        for form in plural.values {
          forms[form.rule.rawValue] = form.value
        }
        return forms
      }
    }

    /// True when a candidate is already over its width guideline. A candidate that
    /// is not a string (a plural object) is measured by its text.
    private static func isOver(_ candidate: Any, limit: Int) -> Bool {
      switch candidate {
      case let text as String:
        return text.count > limit
      case let forms as [String: String]:
        return forms.values.contains { $0.count > limit }
      default:
        return false
      }
    }

    // MARK: - L0 and L1 blocks

    /// L0: identical for every target language, which is what makes it cacheable.
    /// The system prompt's own text is part of this level — see `systemPrompt`.
    private static func sharedBlocks(project: Project) -> [String] {
      var blocks: [String] = []
      appendContext(
        &blocks,
        title: "CONTEXT — GLOBAL",
        text: project.global.context.context,
        limit: Limits.globalContext)
      appendContext(
        &blocks,
        title: "CONTEXT — PROJECT",
        text: project.context.context,
        limit: Limits.projectContext)
      return blocks
    }

    /// L1: identical for every record of one target language.
    private static func languageBlocks(language: String, project: Project) -> [String] {
      var blocks = ["TARGET LANGUAGE\n\(language)"]
      appendContext(
        &blocks,
        title: "CONTEXT — LANGUAGE (\(language))",
        text: project.language(language)?.context.context ?? "",
        limit: Limits.languageContext)
      let sample = registerSample(language: language, project: project)
      if !sample.isEmpty {
        blocks.append("EXISTING TRANSLATIONS (\(language))\n" + sample.joined(separator: "\n"))
      }
      return blocks
    }

    /// The register sample: what this project already ships in one language, as
    /// `source = value` pairs — the register AND the terminology the project has
    /// committed to, which is what a new string has to sound like.
    ///
    /// Values a human settled (`.verified`, `.imported`) come first: they are the
    /// strongest evidence the project has. Then the machine's own output, which is
    /// only a sample of how the column reads. It is recomputed on every assembly
    /// because a write-back changes the column the next batch samples from (4.5).
    /// The caps are the neighbours budget: `Limits.neighbors` pairs of at most
    /// `Limits.neighborCharacters` characters each.
    private static func registerSample(language: String, project: Project) -> [String] {
      var settled: [String] = []
      var machine: [String] = []
      for row in project.data {
        guard let slot = row.target(language), !slot.target.isEmpty else { continue }
        let source = row.content.catalogValue
        let value = slot.target.catalogValue
        guard !value.isEmpty, value != source else { continue }
        let line = clamp("\(source) = \(value)", to: Limits.neighborCharacters)
        switch slot.status {
        case .verified, .imported:
          settled.append(line)
        case .stale, .translated, .needsTranslate, .ignore:
          machine.append(line)
        }
      }
      var seen = Set<String>()
      var kept: [String] = []
      for line in settled + machine {
        guard !seen.contains(line) else { continue }
        seen.insert(line)
        kept.append(line)
        if kept.count == Limits.neighbors { break }
      }
      return kept
    }

    // MARK: - JSON

    /// Deterministic JSON: sorted keys and no escaped slashes, so the same batch
    /// assembles byte-for-byte and a cached prefix stays cached.
    private static func json(_ rows: [[String: Any]]) -> String {
      guard !rows.isEmpty,
        let data = try? JSONSerialization.data(
          withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes]),
        let text = String(data: data, encoding: .utf8)
      else { return "[]" }
      return text
    }

    // MARK: - context blocks

    /// Deduplicates a document body line by line (order preserved), then keeps the
    /// TAIL: documents are append-ordered, so when one outgrows its cap the OLDEST
    /// lines are what must go — a head-keeping cut would hide everything learned
    /// since. An empty block is omitted entirely.
    private static func appendContext(
      _ blocks: inout [String],
      title: String,
      text: String,
      limit: Int
    ) {
      var seen = Set<String>()
      var kept: [String] = []
      for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !seen.contains(line) else { continue }
        seen.insert(line)
        kept.append(line)
      }
      let deduped = kept.joined(separator: "\n")
      guard !deduped.isEmpty else { return }
      blocks.append("\(title)\n\(clampTail(deduped, to: limit))")
    }

    /// Character-prefix truncation on grapheme boundaries, with a marker so the model
    /// knows a section was cut. Used where the head carries the meaning.
    private static func clamp(_ text: String, to limit: Int) -> String {
      guard text.count > limit else { return text }
      return String(text.prefix(limit)) + "\n[section truncated]"
    }

    /// Line-aware, tail-preserving truncation, with a marker naming what was dropped.
    /// A single line longer than the whole budget keeps its own tail, so the block is
    /// still bounded and never empty.
    private static func clampTail(_ text: String, to limit: Int) -> String {
      guard text.count > limit else { return text }
      let marker = "[section truncated — oldest lines dropped]"
      let budget = max(0, limit - marker.count - 1)
      var kept: [String] = []
      var used = 0
      for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
        let line = String(rawLine)
        let cost = line.count + (kept.isEmpty ? 0 : 1)
        if kept.isEmpty, cost > budget {
          kept.append(String(line.suffix(budget)))
          break
        }
        guard used + cost <= budget else { break }
        kept.append(line)
        used += cost
      }
      return marker + "\n" + kept.reversed().joined(separator: "\n")
    }

    // MARK: - system prompts

    /// Which prompt a request is: the translate shapes (a uniform language batch, the
    /// mixed-language row batch, a one-item repair) are three different system texts
    /// because the DIRECTION has to be described differently, and the L0 prefix is
    /// per-shape for exactly that reason. It stays stable within a shape, which is
    /// what the cache needs.
    private enum Shape {
      case translate
      case row
      case repair
      case review
      /// The learn fold and the compression pass name their own language and cap.
      case learn(language: String)
      case compress(language: String, limit: Int)
    }

    private static func systemPrompt(_ shape: Shape) -> String {
      switch shape {
      case .translate:
        return translateSystem(direction: .targetLanguageSection)
      case .row:
        return translateSystem(direction: .perItemLanguage)
      case .repair:
        return repairSystem
      case .review:
        return reviewSystem
      case .learn(let language):
        return learnSystem(language: language)
      case .compress(let language, let limit):
        return compressSystem(language: language, limit: limit)
      }
    }

    /// Where the target language comes from: one L1 block for the whole batch, or the
    /// item's own `language` field when the request spans several.
    private enum Direction {
      case targetLanguageSection
      case perItemLanguage
      var isPerItem: Bool {
        if case .perItemLanguage = self { return true }
        return false
      }
    }

    /// Fixed role text: job, direction and output rules. The TARGET language is
    /// deliberately absent so this block is byte-identical for every target language
    /// in a run — it is the outermost cacheable prefix. The SOURCE language is absent
    /// too: it belongs to the catalog, and no signature here carries it.
    private static func translateSystem(direction: Direction) -> String {
      let opening = direction.isPerItem
        ? """
        You are a careful software-localization translator. The items in the \
        "ITEMS" section of the user message are the SAME string in EVERY target \
        language of the project: one item per language, each naming its own \
        "language". Translate each item into the language it names.
        """
        : """
        You are a careful software-localization translator. The items to translate \
        are in the "ITEMS" section of the user message; the target language is named \
        in the "TARGET LANGUAGE" section.
        """
      let itemOrder = direction.isPerItem
        ? "one element per input item, in the same order, each translated into the language that item names."
        : "one element per input item, in the same order."
      let register = direction.isPerItem
        ? """
        6. There is no "EXISTING TRANSLATIONS" section: this request spans several \
        languages at once, and each item's already-filled "target" is what this \
        project has settled for that language — the strongest evidence of the \
        register and terminology it uses. Stay consistent with those values and keep \
        the row's answers consistent with each other; a value that is already filled \
        is context, and answering it again must not contradict it.
        """
        : """
        6. "EXISTING TRANSLATIONS" shows the register and terminology this project \
        already uses in the target language; stay consistent with it.
        """
      return """
      \(opening)

      Rules:
      1. Output ONLY a JSON array — no prose, no markdown fences. Each element is \
      {"id": <the item's id>, "text": <the translation>}, \(itemOrder)
      2. An item's "id" is its position in this batch: echo it back unchanged, never \
      renumber, never drop an item.
      3. Preserve placeholders (%@, %1$@, %lld, {name}), format specifiers, URLs, \
      markup and code tokens exactly as written. Never add or drop a placeholder.
      4. Context sections in the user message are authoritative: follow glossary, \
      rules and terminology there over your defaults.
      5. "COMMENT" states where the string appears — keep the translation idiomatic \
      for that spot.
      \(register)
      7. When an item's "source" and "target" are OBJECTS of plural categories, the \
      string is a localized plural: translate EVERY category the item lists and \
      answer with the same object shape, one entry per category. Translate each \
      category with the number agreement it calls for (the "one" form reads \
      naturally for exactly one item), keep the placeholders intact, and leave no \
      category out. Empty category values are the forms you are being asked to fill.
      8. A filled "target" is the current value of that slot: produce the better \
      translation for the same slot, in the same shape, or answer with the same \
      value when it is already right.
      9. When an item carries "maxWidth", keep the translation within that many \
      characters if you can do it without losing meaning: a UI element that cannot \
      fit is a defect. Never drop or shorten a placeholder to fit.
      When a translation is ambiguous, pick the most natural option and translate \
      it — never ask back, never refuse.
      """
    }

    /// The repair text: ONE item, in the language its L1 block names. It names the
    /// defects the validator can produce but not which one fired — the request
    /// carries no reason field — so it asks for a complete, correct answer rather
    /// than a specific correction.
    private static var repairSystem: String {
      """
      You are a careful software-localization translator. ONE item is being re-asked \
      on its own: the answer given for it was rejected before it could be used. A \
      rejection is one of three things — a placeholder that was dropped, duplicated \
      or altered; an answer left in the source language; or an empty answer.

      Rules:
      1. The item is in the "ITEMS" section of the user message; the target language \
      is named in the "TARGET LANGUAGE" section.
      2. Output ONLY a JSON array with ONE element: {"id": <the item's id>, "text": \
      <the translation>}. No prose, no markdown fences.
      3. Every placeholder and format specifier of the item's "source" must appear \
      exactly as many times and in the same form in your answer.
      4. Translate: an answer that echoes the source is not an answer.
      5. When the item's "source" and "target" are objects of plural categories, \
      answer with the same object, filling EVERY category the item lists.
      6. Follow the context sections, the "COMMENT" and any "maxWidth" guideline.
      """
    }

    /// The paid gate: judge the candidates, correct only real defects.
    private static var reviewSystem: String {
      """
      You are a strict software-localization reviewer. For each item you get the \
      source string and a CANDIDATE translation. Judge the candidate against its \
      "COMMENT", against its target language — named in the "TARGET LANGUAGE" \
      section, or per item — and against the project context.

      Rules:
      1. Reply with ONLY a JSON array — no prose, no markdown fences. Each element \
      is {"id": <the item's id>, "valid": <true|false>, "fix": "<corrected \
      translation>"}, one element per input item, in the same order.
      2. Mark valid=false ONLY for a real defect: wrong meaning, a broken or altered \
      placeholder, the wrong language, wrong grammatical agreement, a value that \
      contradicts a settled value of the same row, or clearly non-idiomatic \
      register. Do not rewrite a correct translation to your own preference — when \
      in doubt, mark it valid and leave "fix" empty.
      3. Leave "fix" empty when valid=true.
      4. When the items of one request name different languages, judge each item on \
      its own AND check that the row reads consistently across the languages it \
      names; a value that contradicts a settled one is a defect of the candidate, \
      never of the settled value.
      5. When an item's "source" and "candidate" are objects of plural categories, \
      judge and fix every category, and answer with "fix" as the same kind of \
      object.
      6. An item may carry "maxWidth": its candidate is longer than the guideline \
      the UI gives that string. Then rephrase or abbreviate it so it fits, keeping \
      the meaning, the placeholders and the register. If it cannot be shortened \
      without losing meaning, mark it valid and leave "fix" empty.
      7. An item whose candidate is empty has nothing to judge: mark it valid and \
      leave "fix" empty.
      """
    }

    /// The learn fold: the machine's attempt vs the human's value, folded into one
    /// document line per (key, source). The language is named here because no L0
    /// block exists on this request — it carries no project context.
    private static func learnSystem(language: String) -> String {
      """
      You are the learning engine of a software-localization pipeline. You maintain \
      ONE plain-text document of accumulated lessons for the target language \
      "\(language)". You receive the document as it stands and the LESSONS of this \
      fold: for each one, what the machine produced for a source and what the human \
      settled on for it, with the catalog key and the developer comment.

      Your job is the line (or lines) this fold APPENDS to the document — not the \
      document, not a summary of the lessons.

      Line format — every lesson occupies exactly ONE line, its three fields \
      separated by a real tab character (U+0009), exactly like this one:
      cancel\tCancel\tОтмена
      The fields are KEY, SOURCE and VALUE in that order. The separators are REAL \
      tab characters, never the two-character text \\t. A literal tab, newline or \
      backslash INSIDE a field is escaped as \\t, \\n, \\\\ — reproduce those escapes \
      exactly.

      Rules:
      1. Reply ONLY with the line(s): one line per lesson you fold, in the given \
      order, and nothing else — no prose, no markdown fences, no commentary, and no \
      copy of the lines you did not change.
      2. The VALUE field is the settled value itself, written the way this document \
      already words things: terminology, capitalisation and register consistent with \
      the lines around it. Never a description of the lesson, never the machine \
      wording the human rejected.
      3. One line per (key, source): never emit two lines for the same pair, and \
      never emit a line for a pair the document already covers in its own words.
      4. Never invent a lesson the input does not imply, and never restate a lesson \
      that is already in the document.
      5. If the document already covers EVERY lesson you were given, reply with \
      exactly the single line NO_CHANGE.
      """
    }

    /// The compression instruction: dedupe, merge, keep every term and convention,
    /// fit the cap. The line format is restated exactly, because the reply is stored
    /// as the document's new body.
    private static func compressSystem(language: String, limit: Int) -> String {
      """
      You are the budget keeper of a software-localization document: ONE plain-text \
      document of accumulated lessons for the target language "\(language)". You \
      receive the document as it stands, and it is over its character budget. Return \
      it COMPRESSED and DEDUPLICATED.

      Line format is unchanged — every lesson occupies exactly ONE line, its three \
      fields separated by a real tab character (U+0009), exactly like this one:
      cancel\tCancel\tОтмена
      The fields are KEY, SOURCE and VALUE in that order. Separators are REAL tab \
      characters, never the two-character text \\t. A tab, newline or backslash \
      INSIDE a field is escaped as \\t, \\n, \\\\ — reproduce those escapes exactly.

      Rules:
      1. Reply ONLY with the complete rewritten document — no explanations, no \
      markdown fences, no commentary.
      2. Keep exactly ONE line per (key, source) pair. When two lines contradict \
      each other for the same pair, keep the LAST one: lines are appended over time, \
      so the last is the newest.
      3. Merge duplicates and redundant wording. Never drop a term, a proper noun, a \
      transliteration rule or a register convention.
      4. Never invent a lesson the input does not imply, and never change a value \
      that carries no duplicate.
      5. The result MUST be at most \(limit) characters. Drop the most generic and \
      the oldest lines first; keep the newest and the most specific ones.
      6. If the document cannot be usefully shortened, reply with exactly the single \
      line NO_CHANGE.
      """
    }
  }
}
