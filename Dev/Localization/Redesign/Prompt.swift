//
//  Prompt.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  Design only: signatures with placeholder bodies that compile and change no
//  behaviour. Semantics are in "Design notes.md", section 4.3.
//
//  Every prompt in the redesign is assembled here, because the block ORDER is a
//  cache contract: reordering L0/L1/L2 silently destroys the provider cache hit
//  rate, and the run reports a cached-token share that would then read zero.
//

import Foundation

extension Translation {
  enum Prompt {
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
      Request()
    }
    /// Prelearn: a machine version of a source whose human value has no machine
    /// record. Same shape as a language batch, and the reply is written to
    /// `machine` only.
    static func prelearnBatch(language: String, items: [Run.Item], project: Project) -> Request {
      Request()
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
      Request()
    }
    /// The learn fold: what the model produced vs what the human settled on, into
    /// one document line per (key, source). Change-gated at the write, not here:
    /// this only builds the request.
    static func learnFold(language: String, lessons: [Lesson], document: String) -> Request {
      Request()
    }
    /// The budget keeper — one call per over-budget document, never one per line.
    static func compress(language: String, document: String, limit: Int) -> Request {
      Request()
    }
    /// The single paid call: the candidates that were already in the prompt, plus
    /// `{id, valid, fix}` per rejected id.
    static func review(project: Project, items: [Run.Item], replies: [String: String]) -> Request {
      Request()
    }
    /// One rejected id, repaired in its OWN language — never batched with the
    /// others, whose languages differ.
    static func repair(item: Run.Item, language: String, project: Project) -> Request {
      Request()
    }

    /// A request as the router sends it. `ids` is what the validator matches the
    /// reply against; `cacheablePrefix` is the L0 block, which is what the
    /// telemetry counts when it reports the cached share.
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
  }
}
