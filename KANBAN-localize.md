# Dev — Servers: the pane's Translate run (kanban board `localize`)

Date: 2026-09-23   Board: `localize`   Workdir: /Users/v57/Projects/Dev
(The repo's other doc, KANBAN.md, belongs to the `dev-translation-redesign` board — this
file is the `localize` board's, so neither doc is overwritten.)

STATUS 2026-09-24: the pane's LINE TABLE, built here by the orchestrator exactly as the
2026-09-23 pair was (reader: "do it here"), not dispatched.
  - LANDED ae94f6a  the pane's lines: an editable, paged table
    (`ServerCorpus.swift` + `ServerCorpusTable.swift`, card t_c1fd88a3)
  - LANDED a5e75d7  on-demand worklist batches + value writes (LocalizeClient)
  - LANDED a537ee2  the run (ServerRun.swift) + the pane's bar (ServerRunBar.swift)
  - OPEN    t_0a8ad175 verify (the user's visual pass + the stale re-translation scenario)
  Both landed cards carry a LANDED comment and are archived; the board's open card is the
  verify one.
    hermes kanban --board localize list --json

## Why this is cards and not a button tweak

The ask was: add `Translate` and Skip Learning to the server pane, to match the pair the
Localization pane already has. The pair's meaning is decided by what a run DOES, and on a
server pane that is a new run path, not a new button:

- The Localization pane's pair is `Label("Translate", systemImage: "translate")`
  (`.borderedProminent`, `Localization toolbar.swift:96-100`) and, in the redesign bar, the
  icon-only `forward.fill` twin whose help is the shared sentence
  `Translation.Run.skipLearningHelp` = "Start without the learning steps: prepare,
  translate, then the row pass" (`Redesign/Runner.swift:115-116`). "Skip learning" only
  means something if the run it starts HAS learning steps.
- A server pane's corpus is not a project catalog: the run must fetch the work from the
  server (`localize/worklist`) and push the result back (`localize/values`).
- The node's OWN engine cannot do the translating on this machine: a `localize/translate`
  (dryRun) call to the local node timed out after 120 s, no hub service / ollama / local
  model is listening, and `curl 127.0.0.1:11434/api/tags` is empty. So the app's own router
  does the work — which is also what the existing buttons already mean.

Reader's answer (2026-09-23), which supersedes my first reading:

    Translate      = learn -> vertical translate -> horizontal translate
    Skip Learning  =            vertical translate -> horizontal translate
    All of it on the DEV APP side (the node is only spoken to over HTTP, its code untouched).
    Batches are LOADED ON DEMAND, not all at once.

So "learning" is the app's own `learn` stage (the same one the catalog run uses), fed by what
the server knows for that locale — its `gold` values are the human-verified material and its
`comments` the context. My earlier reading ("learning" = the node's `localize/resolve` pass)
was wrong and its card was replaced, not edited.

## Tasks (capture-only, triage, assigned to nobody)

    - [x] t_1b3f6e31  Translate/Skip Learning run the app's plan over a server's corpus   -> a537ee2
    - [x] t_54d992ad  the pane's run bar: Translate + Skip Learning, matching the pane     -> a537ee2
    - [x] t_c1fd88a3  the pane's lines: an editable, paged table (comment + value)        -> ae94f6a
    - [ ] t_0a8ad175  verify the pane's run end to end (user's visual pass + stale redo)    prio 30

    Superseded: t_69efde4d (archived; its body's learning definition was rescinded, replaced
    by t_1b3f6e31 — the child t_54d992ad was moved to the new parent, then the old unlinked).

Dependency graph (dispatcher-enforced):
    t_1b3f6e31 -> t_54d992ad -> t_0a8ad175

## Reuse points (so a worker does not invent a pipeline)

- `TranslationRouter.translateBatch(_ items: [ContextPromptBuilder.BatchItem], from:to:)`
  -> `BatchOutcome { values: [Int: String], failedIDs, model, provider, isPaid, notes,
  truncated }` — `Dev/Translation/Backends/TranslationRouter.swift:12-27, 172-186`.
- `ContextPromptBuilder.BatchItem { id: Int, sourceText: String, context: TranslationContext?,
  targetLanguage: String? }` — `ContextPromptBuilder.swift:87-97`.
- Batch budget: `TranslationRouter.translateSourceBudget` = 10 000 source characters.
- The server door: `Dev/Translation/Backends/LocalizeClient.swift` (Bearer key, `{data}` /
  `{error}`, plus the Worklist / Values-request shapes this work adds).
- The pane: `Dev/Servers/ServerDetailView.swift` (endpoint, key source, status, per-locale
  stats table, Check / Edit).

## Baseline numbers (dev DB, measured 2026-09-23)

    vijo locale-messages            144   (all commented)
    vijo locale-values, fr          140   (139 machine, 1 gold)
    -> fr "missing"                   4   the work a Translate run has today
    prod (vijo.gg)                 144 messages, 0 values in every locale

The acceptance counts in the cards use these numbers. Nothing in this phase writes to prod:
its key is the same secret as dev's, and a write there would rewrite the live corpus.

## Gates

- Build: `xcodebuild -project Dev.xcodeproj -scheme Dev -configuration Debug
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build` — capture RC to a
  file and grep the log (never pipe the build), must reach `** BUILD SUCCEEDED **`.
- Git: commit locally in ~/Projects/Dev, NEVER push.
- Mongo (127.0.0.1:27017) and the node (`bun index.ts` in ~/github/vijo/node) must be up for
  the verify card; the dot goes green on the local connection with an EMPTY key field
  (falls back to the shared `LOCALIZE_KEY`).

## What the run does (landed a537ee2)

    ServerRun.start(connection:locale:scope:plan:)   the pane's entry (SwiftData row)
    ServerRun.start(base:key:locale:scope:plan:)      the same start, without the row (probe-able)

- Plan (the app's own, unchanged): Translate = learn -> vertical -> horizontal; Skip Learning
  = vertical -> horizontal. `learn` folds the SERVER's verified (`gold`) values into the
  prompt as the language block, with per-namespace samples as neighbours and each sentence's
  `comment` travelling with it; machine values are NOT learned from (they are what the run
  replaces).
- Batches are read ON DEMAND (`worklistBatches`, one page per consumed batch, filters
  `empty` then `stale`), each batch re-cut by `TranslationRouter.translateSourceBudget`, and
  a batch's accepted values are pushed the moment it closes (origin `machine`, model
  stamped), so Stop keeps everything already accepted.
- The row pass re-checks the rows THIS RUN wrote against the source and against their own
  sibling languages, re-asks the invalid ones once with those siblings in the prompt, and
  reports what it could not fix.
- Placeholder-only sources (`$description`) are never sent to a model — the engine's own
  rule — and are counted as "not translatable" instead.

Evidence (the app's OWN files compiled into a probe, driven against the live local node):

    /tmp/lzrun de chat full    8 read / 8 written  model 'Ling 3.0 Flash Sante (free)'
    /tmp/lzrun it chat skip    8 read / 8 written  note: learning skipped
    mongosh: de = 8, it = 8 machine values with correct placeholders; fr untouched at 140

## Done already, so it is not re-implemented

- On-demand batching + the write path, commit a5e75d7: `LocalizeClient.worklist`,
  `LocalizeClient.worklistBatches` (pull-based `AsyncThrowingStream`, one page per consumed
  batch, filters in order, no sentence twice), `LocalizeClient.writeValues` ->
  `LocalizeWriteResult { written, skipped, stale, reason }`, plus the `LocalizeWorklist` /
  `LocalizeValueEntry` shapes. Proven by a probe compiled from the app's own
  `ProviderSecrets` + `LocalizeClient` against the live local node: fr empty+stale -> 1
  batch of 4 rows, `writeValues([])` -> written=0, wrong key -> the 401 surfaced.
- A finding that changes what "done" looks like for fr: those four rows are
  `$description` / `$user` / `$name` / `$giveawayName` — placeholder-only sources, which the
  engine's own rule never sends to a model. So the local fr corpus has NO translatable work
  left, and fr's "missing 4" is not a work signal. A real run needs a corpus with real work
  (prod has 144 sentences and zero values — read it, never write to it; or seed another
  local locale).


- `LocalizeClient` + `LocalizeServer` (commit c5770a6), the Servers sidebar section, form,
  store and pane (commit ecc72d4), the pane's "nothing translated yet" state (30d248d).
- The window toolbar's project-bound pair and the Localization pane's Translate button are
  untouched by this phase and must stay that way.

## The pane's line table (2026-09-24, card t_c1fd88a3)

The ask: an editable table in the server pane like the .xcstrings pane's one, paged on
scroll, no multiple/plural values and no Longest column, a search, and every line and
comment editable.

What the service actually offers (`~/github/vijo/node/api/localize.ts` — READ, never
changed; the node's code is still untouched by this app):

    POST localize/messages    namespace?, comment? ('any'|'missing'), locale?, limit<=1000, cursor?
                              -> { items: [{source, comment, namespace, revision,
                                            locales: { <loc>: {value, origin, stale} }}], cursor, more }
    POST localize/values      entries <=1000 {source, locale, value, origin, model?} — gold = a human's
    POST localize/comments    entries <=1000 {source, comment} — bumps the message's revision and
                              stamps that message's MACHINE values stale (a gold value is left alone)

    There is NO search route and NO route that rewrites a message's `source` (the sentence
    IS the message's identity — its sha1), so the search is a LOCAL filter that keeps
    paging, and the Line column is read-only. Both facts are deliberate, not gaps to fill
    by guessing: `localize/messages` is the only inventory door and it pages by hash.

- One page (200 lines) is read when the reader reaches the bottom of what is loaded; the
  cursor walks forward and no sentence is served twice (`LocalizeClient.inventory`).
- The search filters the lines in hand and, while the query is unanswered, keeps pulling
  pages (debounced 350 ms, bounded at 25 pages / 25 matches) — a hit further down the
  corpus is findable without scrolling to it. The footer says which of the two happened
  ("N matching lines in the 144 lines read so far" vs "…in the whole corpus"), so the field
  never reads as a server-side search.
- Both edits are per row: a value is written as `gold` (a person typed it — the run's own
  writes are `machine`, and the service refuses to let a machine value overwrite gold, which
  the row reports), a comment through `localize/comments`, with the stale stamp it causes
  reported on the same row.
- A run that finishes while the table is open does NOT reset it: the pane marks the rows
  ("a run wrote values while this table was open") and offers Read Again, so the reader's
  place in the corpus stays theirs.

Evidence:

    /tmp/dev-corpus-probe   GREEN 26/26 · RED (cursor dropped from the request) 8 FAIL
        the app's OWN files (LocalizeClient + ServerCorpus + `folded` extracted from
        Localization.swift) against the live local node — 144 lines, pageSize forced to 20
        so the cursor walk is real:
          start            -> 20 rows / 1 page (of 144), the server's own order
          bottom of table  -> 40 rows; the walk -> 144 / 144 over 8 pages, no duplicate
          rare token only a LATER page carries -> the sweep reads all 144 and finds the line
          a token nothing carries -> 144 read, "no match in this server's 144 lines"
          comment write -> read back from the server, then the original restored
          value write -> stored as gold; a machine value -> written=0 skipped=1
        The probe's writes were reverted afterwards: vijo has 0 values before and after,
        revisions back to 1, all 144 comments intact.
    App build: xcodebuild -project Dev.xcodeproj -scheme Dev -configuration Debug
        -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build -> BUILD SUCCEEDED

Not covered by the probe (the reader's own pass): the visual layout — the table now takes
the height the pane's header leaves, and the pane no longer scrolls as one piece.
