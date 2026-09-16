# Dev — Translation redesign: design notes

Status: **design only**. Nothing in `Dev/Localization/Redesign/` is wired into the
app — the files are stubs that compile and do nothing. The current pipeline
(`plans/translation-flow.md`) still runs the app.

This document completes the redesign that `Design.swift`, the four stage files and
`Plurals.swift` started: it states the semantics of what is already there, fills
every hole the stubs left open, and lists the decisions that are still the
reader's to make.

## What the redesign is, in one pass

- One namespace, `Translation.*`, absorbing the spread of top-level types the
  current implementation uses (`LocalizationStore`, `TranslateRunController`,
  `Stage0Learner`, `TranslationRouter`, `Reconcile`, the SwiftData models).
- Rows and slots. `Project.data: [LocalizationKey]` is one entry per catalog key
  (source body, developer comment, width guideline, per-language slots).
  `LocalizationString` is one (key, language) slot whose text is a `StringBody`
  — either a flat value or a set of plural forms.
- Contexts are versioned text documents with a character budget, one per scope
  (global / project / language), grown by learning and compressed when over
  budget.
- Four stages scan the rows into character-budgeted batches. A runner — which
  the stubs did not have at all — sends, validates and applies them.
- The `.xcstrings` file is the artifact; app-side data is the working copy and
  `Save` remains the only writer of the file.

## The rules the new implementation runs under (reader, 2026-09-14)

Constraints on the whole redesign, not gaps in it. Everything below assumes them.

- **Muse does every model call.** No free tier, no chain, no fallback ladder: the
  paid Muse model is the only client. The free-first routing of the current
  implementation was an availability and quality experiment and is not carried
  over. What survives from that work is per-provider ADMISSION and COOLDOWN,
  because both are about not burning a batch on a provider that is known to be
  down — see 5.2.
- **The new logic runs separately from the old one.** Same app, same files on
  disk, two independent implementations: nothing under `Redesign/` calls
  `LocalizationStore`, `TranslationPipeline`, `TranslationRouter`, `Stage0Learner`
  or `Reconcile`, and nothing in the old pipeline calls into these types. They
  share exactly two surfaces, deliberately — the `.xcstrings` artifact (Save is
  still its only writer) and the SwiftData models the store maps onto — which they
  SHARE (10.16, settled). The old flow keeps working untouched while the new one is
  built, and it STAYS when the new one lands (10.9, reader 2026-09-14): there is no
  cut-over and no deletion, so the app carries both pipelines, each reachable from
  its own control, until the reader says otherwise.
- **One `Start` does the whole thing.** A single control runs the main flow's whole
  plan in order — prepare, prelearn, learn, translate (4.2) — instead of the user
  walking stages. The stage rail becomes PROGRESS, not a menu; a step with nothing
  to do reads as a step that did nothing. Whether `Start` also fires the row pass is
  10.17.
- **The UI is an overlay, not a page.** The stage pages appear as a closable
  overlay over the app. Closing it does NOT stop a run: the bottom status bar keeps
  the run's state and reopens the overlay, so a long sweep can be dismissed and
  watched from the bar. Reopening lands wherever the run is now — that is what
  `Run.operations`, the batch cursor and the per-item phases are for.

## 1. Identity and the row model

1.1 `LocalizationKey` has no catalog key.
    fill: `key: String` plus `Identifiable` (`id == key`), `translatable: Bool`
    (`shouldTranslate != false`), and accessors `target(_ language:)`,
    `setTarget(_:for:)`. The catalog key — not the array position — is the only
    stable identity in the system: it is what the file, the imported DB and the
    memory all address.

1.2 Stage operations carry `index` (a position in `project.data`).
    fill: pin `index` to a scan-time snapshot and add
    `Project.rowIndex: [String: Int]` so a result can be applied by key and
    re-checked against the snapshot. A data reload invalidates a running scan;
    rows that appear mid-run are picked up by the next scan, never patched into
    a batch that is already in flight.

1.3 `FullRow` was vestigial (an unused `[String: Language]`) and is DELETED
    (reader, 2026-09-14). If a row projection is ever wanted for the table it is a
    view model over `LocalizationKey`, not a second row type.

1.4 Per-form provenance had no home — and turns out not to need one. `Plurals`
    carries values only, `LocalizationString` carries one `machine` / `target` /
    `reviewed` / `status` per slot, and the current implementation sidesteps the
    question by making every (key, language, category) a full record.
    resolved (reader, 2026-09-13): a plural behaves like any other string. Xcode
    gives a plural ONE state per language, not one per form, so the slot's status
    covers ALL of its forms — a form is empty or filled, the slot is reviewed or
    not — and the slot bodies stay parallel: `target`, `machine` and `reviewed`
    are all `StringBody` and, for a plural slot, all three carry the same rule
    set. No per-form status map exists anywhere in the redesign.
    Consequence for the artifact (2.1): a write-back stamps the SAME state on
    every form of the slot.

1.5 `StringBody` is a text container, nothing else. It must grow three things:
    encode/decode to the artifact (`StringBody(catalogValue:)` and
    `var catalogValue: String`), a `value` accessor for the flat case, and
    `placeholders: [String]` for validation. `characters` stays a grapheme count
    — see 9.2.

## 2. Status lifecycle

2.1 `.xcstrings` mapping (read and write). The artifact's per-localization
    `state` is one of `new` / `needs_review` / `translated` / `stale`, and
    `shouldTranslate == false` is the ignore flag.

      file -> status
        shouldTranslate == false      -> ignore
        absent unit / value empty     -> needsTranslate
        "new"                         -> needsTranslate
        "needs_review"                -> translated
        "translated"                  -> verified
        "stale"                       -> stale
        (nothing in the file)         -> imported   [app-side only]

      status -> file (written on Save only)
        needsTranslate -> "new" (or no unit at all)
        translated     -> "needs_review"
        verified       -> "translated"
        ignore         -> shouldTranslate = false, the value is kept
        stale          -> never written: staleness is app-side knowledge
        imported       -> "needs_review" (reader, 2026-09-16): a value nobody
                          vouched for is not the file's `translated`, which means
                          HUMAN confirmed. It used to write nothing at all, so a
                          value the imported-database resolve put on screen never
                          reached the .xcstrings — and writing `"translated"` for
                          it (as the old pipeline's merge did) claimed a
                          confirmation no human gave. Both writers now agree: the
                          artifact learns the value and that it is unreviewed, and
                          the confirm click is what promotes it to `"translated"`.

    Note the two names that twist: Xcode's `"translated"` means *human
    confirmed*, which is the redesign's `.verified`, and the redesign's
    `.translated` (machine output) is Xcode's `"needs_review"`.

    The mapping above is the redesign's; the current implementation is coarser in
    one place worth knowing about: `Reconcile.seedState(fileState:)` promotes
    exactly one string (`"translated"`) and sends EVERYTHING else — `"new"`,
    `"stale"`, an unknown state, a nil state — to `.needs_review`. So today a
    stale or not-yet-translated unit reads as machine output awaiting review, and
    the app has no `.needsTranslate` equivalent at all; emptiness is expressed by
    the absence of a unit. The redesign makes the four file states explicit and
    keeps app-side staleness (2.3-2.4) separate from the file's own `"stale"`.

2.2 Who writes what.

      needsTranslate -> the translate stages (vertical and horizontal) and a
                        human clearing a slot
      translated     -> the translate stages, on write-back of a machine value
      verified       -> a human confirm, and nothing else. Never auto-promoted
      imported       -> the imported-DB resolve, before any model call
      ignore         -> a human toggling the key's translatable flag
      stale          -> the staleness computation (3.4), never a human

2.3 What re-enqueues. Keep the policy the current flow earned:

      global doc bump   -> auto-enqueues (nothing writes the global doc yet)
      project doc bump  -> does NOT auto-enqueue: it would sweep every record of
                           the project. Rules reach existing slots through the
                           explicit horizontal pass
      language doc bump -> auto-enqueues: this is how a lesson re-applies to the
                           rest of the column

    `needsMachineTranslate` as written accepts `.needsTranslate` only, which
    drops every `.stale` slot — the exact ones a language-doc bump creates.
    fill: `status == .needsTranslate || status == .stale`, plus a non-empty
    source and a non-`ignore` key.

2.4 Learning predicates (the pair that makes the prelearn stage necessary):

      needsPrelearn  = status == .verified && target non-empty && machine empty
                       — a human settled this slot with no machine output on
                       record, so there is nothing to diff. Prelearn asks the
                       model for a machine version of the SOURCE first.
      toLearn        = status == .verified
                       && machine non-empty && target non-empty
                       && machine != target        (the model already agreed with
                                                    the human: no lesson)
                       && reviewed != target       (nothing new since the last
                                                    confirmation)
                       -> the value is the human's `target`
      The two are disjoint by construction (machine empty vs non-empty), which
      is what makes "prelearn, then learn, then translate" a total order.

2.5 `reviewed` is the value at the moment a human confirmed the slot — a
    snapshot, not a second copy of the target. A human edit after confirmation
    makes `target != reviewed`, which re-arms learning for that slot.

2.6 `VerticalLearn.scan()` passes `machine: item.target`. That is the target,
    not the machine body: the learn stage would compare the human's value with
    itself and learn nothing. fill: `machine: item.machine`.

2.7 `Plurals` therefore grows `value(for:)` and `set(_:for:)` so a stage can read
    and write one form, while every predicate above stays SLOT-level: a plural
    slot is work when its own status says so, never because one form happens to be
    empty.

2.8 Comments. `comment` has no home on the app side: the format carries it and the
    store has no column for it (7.2), so a row's comment is read from the artifact and
    travels into a prompt from there (4.3). What the redesign never had is GENERATION
    — which Xcode 26 does with an on-device model, and which the reader wants too
    ("we are currently missing that"). The settled shape of it:
      - it runs AFTER the app's own Scan Strings operation, ON the scan's result, so
        the source FILE each key came from is already in memory and no path is ever
        stored in the store. `.stringsdata` carries the file per document
        (`ScanStringsDataDocument.source`) and today `parse()` folds it away; keeping
        it in the report is the whole reason this pass can exist without a schema.
      - the call site is located by REGEX inside that file — the scan has no line
        numbers — and the surrounding lines travel to the model as context, which is
        what makes the comment describe USE rather than restate the string.
      - ONLY keys whose artifact has no comment are touched. A human's comment is
        never rewritten, and a key that already has one costs nothing.
      - the model is the ON-DEVICE one (Foundation Models), the same capability
        Xcode's own comment generation is built on: verified available on this
        machine, ~2.3 s per comment, no key, no network, no rate budget. It is the
        one NAMED exception to 5.2's single model.
      - generated comments are app-side edits pending Save, like every other change
        (5.8: Save stays the only writer of the `.xcstrings`).
      - it is best-effort by construction: an unavailable model, a key with no call
        site in the scanned file, a regex that finds nothing, a timeout or a refusal
        SKIPS that key and reports it — never an error that fails the scan. The scan's
        report is where the counts belong (generated / skipped, with the reason).
    It is deliberately NOT part of a translate run: it belongs to the scan, because
    that is where the paths are.

## 3. Context documents

3.1 Scope identity. `Context.id` is built by a scope, never by string
   - interpolating an object:

      Context.Scope.global
      Context.Scope.project(<project id>)
      Context.Scope.language(project: <project id>, code: <BCP-47 code>)
      -> "global" / "project/<id>" / "project/<id>/language/<code>"

    `Language.init` currently writes `"project/\(project)/language/\(id)"`, which
    interpolates the *object* — the id would be garbage — and implies a
    per-project-per-language document. The current implementation instead keys
    language docs by language code alone and shares them across projects.
    resolved (reader, 2026-09-13): PER PROJECT. The stub's intent was right and
    only the interpolation was wrong: `Context.Scope.language` takes the project id
    and the code, the id is `"project/<id>/language/<code>"`, and the document is
    keyed by that pair in the store — `ContextDoc.identifier` holds the FULL scope id
    (`"project/<id>/language/<code>"`) and a language document does NOT set its
    `project` relationship (reader, 2026-09-14). That relationship is the to-one
    inverse of `Project.contextDoc`, so a project document and its language documents
    cannot share it — and it is exactly the property the old browser reads for project
    rules. The full scope id keeps the documents apart instead. A lesson never leaks
    between projects, and each project's 1 000 characters are spent on its own
    vocabulary.

3.2 Caps. `Context.limit` is the PROMPT budget, not a storage budget:

      global    10 000   (the current builder sends 5 000)
      project   10 000
      language   1 000
      batch     20 000   source characters per request, on top of the context
      row pass   5 000   a QUARTER of it (reader, 2026-09-14, applied in
                         `Horizontal translate.swift` as `Limits.batch / 4`): the row
                         payload carries EVERY language of each row, so it is the
                         expensive shape by construction (4.6) and its requests are cut
                         smaller on purpose. It is a per-shape budget, which is why it
                         belongs in this table rather than inline.

3.3 Versioning. `version` starts at 1 and is bumped once per autonomous change;
    a user editing the project doc bumps it once per real change and writes
    nothing when the text is unchanged. A slot stores the version stamp of every
    scope it was produced against, so "stale" is a comparison and never a
    guess.`contextVersion: Int` cannot express that (three scopes bump
    independently) — fill: `LocalizationString.versions: Context.Version`, a
    three-field stamp, with 0 meaning "no document existed then".
    A document that was never written is version 1 like any other, so `Context`
    carries `hasDocument` and everything that compares versions reads
    `publishedVersion` (0 while nothing has been written) instead of the raw
    number.

3.4 Staleness. A slot is stale when any scope that owns it is newer than the
    slot's stamp, the scope being: the record's language doc, plus the project
    doc, plus the global doc. A stamp of 0 is stale as soon as the document
    exists — but only once it EXISTS: a scope with no stored document publishes
    0, and 0 < 0 is false, so a project where nobody has written a rule yet marks
    nothing stale. (Expressing this as a flag rather than as a magic version
    number is what stops "no rule" from reading as "a rule newer than
    everything" when a column's staleness is computed.)

3.5 Writers per scope:
      global   — no writer exists today, and that is deliberate: it is the
                 widest blast radius in the system. A writer is decision 10.2.
      project  — a human: a row note with scope *project rule*, or the
                 "Context rules" editor. Prose, no model call, an exact-line
                 membership test.
      language — the learn stage, one line per (key, source) lesson, deduped,
                 canonicalized; compressed when over the cap. One document per
                 project AND language, so a lesson never leaks between projects.

3.6 Compression is the budget keeper, not truncation. After every learn fold,
    any document over its cap is rewritten by the model in one call, change-
    gated (a language-doc bump makes every other slot of that language stale, so
    a no-op rewrite must write nothing). Tail-preserving truncation
    (oldest lines dropped) remains the fallback, and the reason a document's
    order is append-only.

3.7 Line formats. Language docs are `KEY<TAB>SOURCE<TAB>VALUE`, three fields,
    escaped, canonicalized on write. Project docs are plain prose rules. The
    two formats are not interchangeable and each scope validates its own.

3.8 Canonicalization on append: dedupe to one line per (key, source) keeping the
    newest value; a cleared value retracts its line; re-appending an identical
    line is a no-op and must not bump the version.

## 4. The operations of a run

4.1 Every operation is a scan of `project.data` into per-language (or per-row)
    batches, plus a cursor. What differs is the predicate and what the result
    writes:

      Prepare              no model call, always first. Scans the catalog, merges
                           it into the open in-memory catalog, loads the session
                           rows and resolves the imported database, so every later
                           operation sees ONE settled set of rows.
      VerticalPrelearn     needsPrelearn slots, batched per language.
                           Writes `machine` ONLY. Never `target`, never `status`
                           — the slot stays `.verified` (the human owns the
                           value) and the operation exists purely so that learn
                           has something to compare.
      VerticalLearn        toLearn slots, batched per language. Writes the
                           project's language document (a lesson line) and memory.
                           Never touches a slot's value or status.
      VerticalTranslate    needsMachineTranslate slots, batched per language
                           (one request per language, items in payload order).
                           Writes `target`, `machine` and status -> `.translated`.
      HorizontalTranslate  whole rows: EVERY language of the row travels in one
                           request and there is NO selection on the shape — every
                           translatable row is sent whole, settled columns included
                           (4.6). Same writes as vertical, with the per-item
                           language named inside the item; what gets written is
                           decided per slot when the reply is applied, so a
                           verified value is not editable here.

4.2 Order. TRANSLATE is one button and one run:
    `prepare -> prelearn -> learn -> vertical`. Preparation settles the rows;
    prelearn supplies the machine record a human-verified slot is missing; learn
    folds what the human changed into the project's language document before the
    column it governs is translated. Prelearn and learn are operations of that
    run, not passes the user triggers — prelearn is the run's SECOND operation,
    right after preparation. That sequence also makes the predicates disjoint by
    construction (2.4), so nothing can be learned twice or translated before its
    lesson lands.
    The plan does NOT stop at the columns: the row pass is its LAST step and is always
    enabled (reader, 2026-09-14). It answers a different question — cross-language
    adaptation to what a human has verified, and the rows where the model's own output
    is invalid (4.6) — and it sweeps the project row by row. That order is also the
    workflow: run once, verify what matters, run again. The columns then have nothing
    left to redo (verified slots are not work), so the same button is what carries the
    corrections into the rest of the languages.

4.3 Prompt shapes, and what a request actually carries. A language batch is L0
    (system + global + project), L1 (target language + language doc + register),
    L2 (items), payload last. A row batch is L0 then ITEMS; neighbours are omitted
    by construction. Reordering these blocks silently destroys the provider cache
    hit rate, which is why they are one function each in `Prompt.swift` and not
    assembled ad hoc at the call site.

    The item fields are a CLOSED SET, and the key is not in it:

      vertical (per language)   comment, maxWidth, source, target
      row (per language, in one request)  comment, maxWidth, source, target,
                                plus the target language named per item

    - **The KEY is never sent.** It never matters to a translation, so nothing on
      the wire is a key. The ids the model echoes are the items' positions in the
      batch, and the key stays app-side: it is what applies a reply, what addresses
      memory, and what the journal records. (The language DOCUMENT's lesson lines
      do carry a key — that is app-side text, not a request.)
    - **`source` means the row's content**, not the authored source field: a row
      whose source unit is missing sends its KEY as the content, because that is
      what the artifact itself shows. So "no source" is not a reason to skip a row
      anywhere in the pipeline (the current implementation skips those rows).
    - **`target` is the current value when there is one** — a stale slot carries its
      old value — or the EMPTY PLURAL SKELETON of the target language when there is
      not, so the model is told which forms it is filling rather than being left to
      guess which ones a language has.
    - **`maxWidth` IS sent on a vertical request** (reader, 2026-09-14). This
      reverses a rule the current pipeline documents — see 9.3.

4.4 Splitting. Batches are sized by CHARACTERS, never by count: 20 000 source
    characters per language batch, plus each item's target/plural overlays. A
    row batch counts its source once per language of the ROW (settled columns
    included, 4.6) and is capped at a QUARTER of the language cap (5 000, 3.2):
    a row request pays for every language of every row it carries, so its batches
    are cut smaller on purpose (reader, 2026-09-14). A batch always takes at least one item, so one oversized
    source gets its own request instead of being skipped. The `split()`
    implementations in the four stage files already encode this; the caps move to
    `Translation.Limits` so the runner, the progress model and the prompt builder
    cannot drift apart.

4.5 Concurrency. Different languages may run in parallel; within a language the
    batches are strictly sequential, because a write-back changes the column the
    next batch's register samples come from. Preparation is one pass on the main
    actor before any batch goes out, and learn is a single writer of language
    documents — per project, so two projects may learn at once but one project may
    not.

4.6 WHY the row pass exists (reader, 2026-09-14). The two passes answer different
    questions, and neither is a subset of the other:

      column pass (vertical)   a better translation PER LANGUAGE: one language's
                               lesson document, its register sample and its plural
                               forms, batched and cached together
      row pass (horizontal)    adaptation ACROSS languages: the model sees the row
                               whole — including the columns a human has already
                               VERIFIED — so it can adjust machine output it produced
                               earlier to fit what was settled, and spot the rows
                               where its own output would be an INVALID translation
                               (a key whose meaning differs by language: the failure
                               a per-language batch structurally cannot see, because
                               it never has two languages of the same key in view)

    So this is NOT "apply the project rules to values that predate them" — that was
    the current implementation's Update Translations pass, and it is what an earlier
    draft of this section said. It is a cross-language consistency pass, and it runs at
    the END OF EVERY RUN (4.2) rather than when the user thinks to ask: the rows with
    something settled in them are exactly where it has work to do, and on a first run,
    with nothing settled anywhere, it is a second opinion in a row-shaped request at
    row prices.

    The mechanics, unchanged: no selection on the shape, and the write-back is the
    only guard. A row request asks for EVERY language of the row: the settled
    (verified / imported) columns are in the payload because a value this project has
    already committed to is the strongest evidence of the register and terminology it
    uses, and asking for it as well keeps the row's answer consistent across
    languages. So:

      - the scan is `translatable`, nothing else. No version test, no per-language
        filter, no forced variant — and no "row has no source" test either: a row
        with nothing authored sends its KEY as the content (4.3). A row with a
        settled column and columns that need work is sent the same way as any other;
      - what may be WRITTEN is decided when the reply is applied, per slot, from the
        slot's own status: `.verified` and `.imported` are never overwritten. Verified
        values are context, not targets. Doing the check at write-back rather than at
        scan time is what makes it correct — a slot the human confirms while the batch
        is in flight still survives it;
      - therefore an answer for a settled slot is DISCARDED, never rejected. A missing
        or different answer for one is not a validation failure (5.3); spending a
        call on a value nobody is allowed to write is paying twice. The ids
        that must be answered are the writable ones, resolved by the same status
        check at validation time;
      - the batch budget counts the source once per language of the row, settled ones
        included (`RowOperation.characters`). The extra output tokens are the price of
        row-wide consistency and of the reference, and they buy the only context a row
        request has: it has no L1 block and no EXISTING TRANSLATIONS sample of its own.
        The reference rides per item INSIDE the ITEMS block, so the L0 prefix stays
        byte-identical and the row request is still cacheable (4.3);
      - a reply that CONTRADICTS a verified sibling is the interesting failure here,
        not a malformed one. The validator already knows which columns were settled
        (5.3), so the row request itself carries them and the model is asked to be
        consistent GIVEN them —
        "this reads correctly, but not for this key, because the language next to it
        says something else" — rather than merely whether it is a well-formed
        translation. No column pass can make that check, and it is the reason the
        settled values are asked for rather than merely shown.

    This is a deliberate deviation from the current implementation, and in BOTH
    directions: the old Update Translations pass existed to apply project rules to
    values that predate them, which is not this pass's question at all; and it
    refuses human-owned records AND has no EXISTING TRANSLATIONS section in a row
    request (`ContextPromptBuilder.assembleRowBatch` says so outright), so a row
    request today gets neither the writes nor the reference it needs to adapt to
    them. The redesign keeps the refusal — where it belongs, at the write — and adds
    the reference.

## 5. The runner (missing from the redesign entirely)

The operation classes know what to send, nothing knows how to send it.
`Runner.swift` fills that: a `Run` (observable, one per run, carrying its
`plan`) plus a router that executes it.

4.7 Eligibility: a value with NO English characters is never translated (reader,
    2026-09-14). A string whose content holds no Latin letter has no prose to
    translate — a leaked `%d - %d`, a bare number, a bullet, an em dash — so it is
    out of scope for every translate stage and is SKIPPED rather than sent: no
    model call, no batch, nothing to write. The test is on the CONTENT that would
    be translated (the row's source, which falls back to its key, 4.3) and not on
    the status: the question is "is there anything here a translator could
    translate". A row skipped this way keeps whatever it carries, exactly like an
    ignored key, and the row pass skips it too — it is not a row whose columns need
    adapting. It belongs in ONE place so every translate scan inherits it. The reply
    side is deliberately NOT in scope: a model answering prose with "—" is a
    validation matter (5.3), not eligibility.

4.8 The row UNIVERSE is the open catalog, not the store (reader, 2026-09-14 — reported
    from a live run: "prelearn uses rows from db that doesn't exist in the loaded
    .xcstrings file"). `project.data` is one row per CATALOG key; the store supplies
    the STATE of those keys and never the set of them:
      - a key the store holds but the file does not → NO row. Its state waits in the
        store for the key to come back.
      - a key the file holds but the store has no record for → a ROW, whose slots
        start from the artifact (source, value, and the catalog's own state) with
        `machine`/`reviewed` empty. It is work like any other row.
      - where both hold the key, the STORE wins for the value: a run writes app-side
        and the file only catches up on Save (5.8), so the artifact's value is the
        base state, not the latest one.
    Row order is sorted by key: the catalog model holds `strings` as a Dictionary, so
    real file order is not available to the redesign — an earlier draft promised
    "catalog order" and that claim is withdrawn rather than faked. One consequence for
    the shell: no workspace has to wait for the app's own reconcile to produce records
    before its rows exist.

    The rule is stated TWICE on purpose (reader, 2026-09-14): once where the rows are
    built (`loadData`, which fixes every stage at once) and once at the scans, so a
    row that is not part of the open catalog is not work even if it arrives in
    `project.data` by another path — a hand-built data set, a preview, a future
    caller. The flag that answers it belongs to the ROW and has one definition; no
    stage may work it out for itself by reaching into the store or the file.

5.1 Execution order per batch: admission (per-provider rate budget) -> prompt
    assembly -> send through Muse as a STREAM -> deterministic validation -> write-back
    (per row, as each row closes — 5.12) -> checkpoint -> telemetry.

5.2 Model routing. ONE model: Muse, for every call (see the rules above) — with ONE
    named exception, the on-device model that writes comments after a scan (2.8). It
    answers one call per comment-less key, it never leaves the device, and it never
    answers a translation; nothing else may be added to the routing table. There is
    no chain to walk and nothing free to try first, so the runner never asks for
    "the next candidate" — it asks whether Muse is usable and whether it is cooling
    down. What survives from the current implementation's routing work is the two
    things that were never about model choice:

      admission   a per-provider requests-per-minute budget; a run WAITS rather than
                  failing the batch
      cooldown    a quota answer parks Muse until its `Retry-After`, anything else
                  for a fixed window, so a provider that is down costs one call per
                  window instead of one per record

    The tally keeps its per-model line anyway: a single-entry table is the cheapest
    way to see that nothing else ever answered.

5.3 Validation, in this order and none of it paid: echoed ids must match the
    request exactly, the placeholder multiset of each FORM must survive, an
    empty reply is rejected,
    a truncated reply is reported as truncation and re-asked in halves.
    A row is decided the moment it CLOSES, on the stream (5.12): the per-row pass asks
    this same list of questions, and the batch's own pass then reads the whole reply once
    more and skips what was already decided, so the two can never disagree.

    THE PLACEHOLDER CHECK IS PER FORM (reader, 2026-09-15 — a real `ars` batch failed 11 of
    11 rows that were all correct). The languages pluralize differently: a two-form English
    source and a six-form Arabic answer are not the same list of texts, so comparing their
    tokens as ONE multiset can only agree when the two languages happen to have the same
    number of forms — measured: that rejected every plural key into ar (6 forms), ru/pl/cs/lt
    (4) and even zh/ja/ko (1), and accepted only the two-form languages (de/es/fr/…), while
    printing a wall of tokens as the reason. What the check is FOR is a placeholder that went
    missing or changed, and that question is asked of each form of the answer, against the
    source text that form answers:
      · the source's OWN form of the same category (`one` against `one`, `other` against
        `other`);
      · otherwise the source's `other` — the form that carries the number in every language
        that has one, and the form a category the source language lacks is a variation of;
      · otherwise (a source with no `other`) everything the source says.
    A form the reply left empty where its source says something is its OWN defect ("form `x`
    is empty") — the placeholder check would have called it "changed", which is not what
    happened — and a form whose source text is empty requires nothing.

    A SPECIFIER ENDS AT ITS CONVERSION (reader, 2026-09-15: "`%lldd` translated as `%lld d`"
    was rejected). The tokenizer ended a specifier with a greedy `[a-zA-Z0-9]*`, so a letter
    written AGAINST the specifier in the source came back glued to it: `%lldd`, `%lldh`,
    `%lldm` — a number with its unit, which is how a catalog spells "5d"/"5h"/"5m" — read as
    ONE token, while the same specifier with a space in the answer read as `%lld`. Two
    different lists over a placeholder that was never lost, and the row rejected. The
    pattern now parses a real printf specifier (`%`, optional positional index, flags, width,
    precision, length modifier, conversion) and stops at the conversion, so everything after
    it is LITERAL TEXT on both sides — which is what printf says it is. Two consequences,
    both intended: a specifier with a precision or a width (`%.2f`, `%5.2f`, `%*d`) is now
    VISIBLE to the check — the old pattern required a letter straight after the `%`, so such
    a specifier was no token at all and a translation that dropped one was accepted (measured:
    the greedy pattern reads `%.2f` as nothing) — and a letter stuck after a specifier in the
    ANSWER is literal too, so `%@s` no longer reads as a changed placeholder. The SPACE flag
    is deliberately NOT honoured: prose beats it ("50% off" would read as `% o`). Both copies
    of the pattern — this one and `TranslationValidator`'s, which the old pipeline and the
    browser's own verify use — carry the same text, byte for byte.

    NO ECHO GUARD (reader, 2026-09-14: "Remove that guard. Start is start in danish,
    symbol is symbol"). An answer IDENTICAL to its source is not a defect and is no
    longer rejected: a target language reuses a source word far more often than any
    check can tell — `Start` and `Symbol` are what Danish, Czech and German call them —
    and the two attempts to police it both threw away correct work (case-insensitively,
    then only for phrases over four characters). What is left of the free checks is what
    is mechanically knowable: an EMPTY answer, and a PLACEHOLDER multiset that did not
    survive. An identical answer is written as `.translated`, which puts it in the
    review flow where a human decides; nothing else reviews it (5.4). The cost, accepted knowingly: a model that returns a whole sentence unchanged
    for the wrong language now looks like an ordinary unreviewed translation instead of
    an error.

    NO REPAIR (reader, 2026-09-14). A rejected id is marked FAILED, carrying the defect
    that rejected it, and the run's own RETRY of the failed batches is the recovery path
    (5.11). What it replaces was a per-item second chance: one model call carrying the
    full L0 + L1 blocks and the payload for a SINGLE value, run invisibly in the middle
    of a batch — also the window in which a pause froze an unsettled batch. The retry
    re-asks the whole batch with that context shared, and the reader can see it and
    trigger it. Only ids that survive are written. The ids that MUST be
    answered are the writable slots —
    resolved from the slot's status, the same check the write-back makes; a settled
    value that travelled as context (4.6) may come back empty or different, and that
    is not a defect.

5.4 NO REVIEW CALL (reader, 2026-09-14: "maxWidth should go to the vertical translator
    and horizontal translator, reviewer is not needed on those stages as we have a
    single model now"). The paid gate is GONE: there is no second call over the
    candidates, no `{id, valid, fix}` review, and nothing shortens a too-wide value
    after the fact. The reason is the reader's and it is sound — with ONE model, a
    review is that model reading its own output back, which is not an independent
    check, and it doubled the cost of every batch. What replaces it:
      - the WIDTH guideline travels in the item payload of BOTH translate shapes (4.3,
        9.3), so a translation is asked to fit instead of being shortened later;
      - the free checks stay the only filter (5.3): an empty answer and a placeholder
        multiset that did not survive. An answer identical to its source is written as
        `.translated` for a human to judge;
      - everything else is the human's review flow, which is where this pipeline has
        been putting its judgement calls all along.

5.5 Write-back. A batch applies its own results: `target`, `machine`, status, the
    version stamp, the producing model name and the edit journal row, then
    checkpoints. The write set is decided here, per slot, from the slot's own
    status — `.verified` and `.imported` are never overwritten, whatever the request
    asked for (4.6). A failed batch leaves nothing half-written: the batch's results
    are applied as one unit. A PARTIALLY failed batch is not a failed batch (reader,
    2026-09-14): a batch that wrote some of its rows is applied, and the rows that went
    wrong say so themselves — only a batch that wrote NOTHING and failed is marked
    failed. The batch is a request; the row is the unit a human reads.
    ONE ROW IS ITS OWN UNIT OF WRITE (reader, 2026-09-15 — see 5.12): a row that
    closes mid-stream is written there and then — its record, its journal row and its
    memory hint all land the moment its text is complete — and the batch's end-of-batch
    pass then writes only what the per-row pass did not (nothing, in the ordinary case).
    The rule that a failed batch leaves nothing half-written still holds for the pass at
    the end of a batch — that write is still gathered and applied as one unit — but a row
    already written is not un-written by a later failure, because it was never part of a
    batch-sized transaction.
    The TRANSACTION, though, is the batch's, not the row's (reader, 2026-09-15, from the
    profile of §8.1's first finding): the streamed path writes each row with `saving:
    false` and the batch's own end pays ONE `context.save()` (`Runner.commit`). A save is
    not the row. Measured on the reader's own store — 168 822 records, 38 671 edits,
    32 059 memory entries, and this is the number the earlier "0.2 ms per row" reading
    missed, because it was taken on a FRESH context with nothing in it — one
    `context.save()` costs 178 ms cold and 228 ms warm. Per row, a 30-row request burned
    ~6 s of the main thread for nothing; the profiler put 91,5 % of a working core inside
    `writeBack`, and the probe counts 4 saves for a 3-row batch before this and 2 after.
    What it costs is crash durability inside one batch: a crash loses the rows that batch
    had already shown as landed, where one save per row lost at most one row. A write that
    throws mid-batch does NOT roll the context back — the rows already landed are saved
    best-effort instead, because a rollback would take them away while the page still
    shows them — and a save that throws leaves the rows pending for the NEXT batch's
    commit, reporting the error.

5.6 Control. Start / pause / cancel, with the batch cursor persisted as a `RunCursor`
    row (7.2) so a paused or interrupted run resumes at the next unstarted batch instead
    of re-billing the finished ones. Cancel keeps everything already applied.

5.7 Progress and cost. The UI needs, per stage: batches done / total, items done
    / total, characters translated, requests sent, and the cached-token share
    (a flat zero means the provider cache is not being used). A run's clock and
    its per-model tally belong on the run, not on the store.

5.8 The run never writes the artifact. Results reach the file only through the open
    in-memory catalog and a user Save — which means the run has to PUBLISH its results
    into that catalog object, and nothing does yet (reader, 2026-09-14, asking "when
    will I be able to save the translation to .xcstrings?"; measured: no
    `CatalogFileIO`, no `StringCatalog` write and no mirror anywhere under
    `Redesign/`). Three things are missing and they are one concern:
      - the PUBLISH step. `Project` is handed the catalog as a VALUE
        (`loadData(catalog:)`; `StringCatalog` is a struct), so it keeps its own copy
        and the app's instance — the one the browser displays and the one Save writes —
        never hears about a run's results. The pane's catalog stays the single instance
        Save writes, and the redesign hands its results INTO it, the way the old
        pipeline's `mirrorOpenCatalog` does. The redesign never touches the file.
      - ONE dirty flag. The redesign's `isDirty` is its own and the app's
        (`LocalizationStore.isDirty`, which drives ⌘S and the unsaved-changes prompt) is
        another: a run's results currently make the redesign dirty while the app still
        believes it has nothing to save, so its edits can be lost with no prompt at all.
        The app's flag is the one that must know.
      - the AFFORDANCE. Save has to be reachable from the new pane (the app's existing
        ⌘S/toolbar path is enough once the two above hold) and a run's unsaved state has
        to read where the user looks — the status bar is that place (8.1).

    THE SESSION IS A SNAPSHOT, and the store's other writers do not go through it
    (reader, 2026-09-16, after losing a hand edit). `Project.loadData` builds the rows
    once and refuses to build them again, and both halves of a save write that snapshot
    out — `publish()` into the app's catalog (which a Save then puts in the file) and
    `saveData` onto the records. The browser's cell edit writes a RECORD directly and
    merges the artifact itself, so a session opened before that edit was a reversion
    machine: pressing Save on this side put the SHIPPED text back, in the store
    (re-stamping `autoReviewed`, so the "auto" badge came back) and in the `.xcstrings`.
    The rule that closes it: the RECORD wins for any slot whose records moved after the
    session loaded. `Project.adoptForeignWrites()` re-projects those slots from the store
    and is called by `save()` before it publishes, and by a NEW `run()` before its rows are
    built (a run reads the session's slots, so the same stale reading would be published
    when it ends). A slot the session edited
    itself has no record behind the edit yet, so its stamp has not moved and the adoption
    leaves it alone; `.ignore` and `.stale` stay the session's, being the two statuses a
    record cannot express. A RESUME is deliberately not this path — it keeps the batches
    it already cut. What is still open is the other direction: a key the file gains (a
    scan merge) after the session loaded is not a row of it at all, so the session cannot
    translate it until the project is reopened.

5.9 Retries (reader, 2026-09-14). A model response is re-asked before a batch is given
    up on: THREE RETRIES after the first attempt — at most four sends for one batch —
    and only for a failure the run already calls `retryable`. That flag is computed at
    every failure site (`Runner.retryable(_:)`) and until now nothing acted on it; the
    retry loop is the thing it was computed for. Concretely:
      - the retry re-sends the SAME request. The ids are batch positions, so a second
        answer is another attempt at the same unit of work, never a second unit.
      - a retry goes through admission and the cooldown again, so a parked or
        rate-limited Muse WAITS instead of burning an attempt (5.2).
      - a NON-retryable failure fails the batch immediately and is not retried into the
        ground. The flags at the failure sites decide; a flag that looks wrong is a
        question, not a silent edit.
      - every attempt is COUNTED: attempts are cost, so the tally keeps the sends
        (5.7), and the batch reports which attempt it is on while it retries — a slow
        batch must read as slow rather than as a hang.
      - the batch keeps the LAST attempt's raw reply, which is what the split page
        shows (8.1); the failures list keeps one entry per attempt, so the history
        survives the retry.
      - the BATCH is still the unit that fails, and a failed batch still leaves nothing
        half-applied (5.5).
      - a retry is a WHOLE-REQUEST re-ask, which is only right while the attempt wrote
        nothing. An attempt whose stream broke AFTER delivering rows is not retried this
        way: the rows it delivered stay, and the rows it lost are re-asked in halves — the
        same recovery a cut reply gets (5.3, 5.12).
    Retries are a floor, not a chain: they exist so one flaky answer does not cost a
    batch, and they end — after them the batch fails exactly as it does today.

5.10 Where Save appears (reader, 2026-09-14). 5.8 decides WHAT reaches the file;
    these two decide WHEN the user can ask for it:
      - PAUSED: the overlay's page carries a SAVE button. A paused run is a stopping
        point by definition — the results that have landed are app-side, the user is
        looking straight at them, and the natural action is to write them without
        hunting for ⌘S. Saving while paused does NOT end the run: it clears the dirty
        state for what was published and the run carries on from where it was.
      - COMPLETED: the run SAVES. A finished run's results are written to the
        `.xcstrings` with no second action — that is what pressing Start is for, and the
        publish step (5.8) has already put them in the open catalog. The consequence:
        the unsaved-changes prompt is then about HUMAN edits and about a run that did not
        finish, never about a run that did.
      - A CANCELLED run is the one ending that does NOT write on its own (reader,
        2026-09-14): the user stopped it deliberately, so nothing reaches the file until
        they ask for it — the ordinary Save is the way, and what it applied (5.6) stays
        app-side until then. A run that ENDED WITH FAILED BATCHES is NOT that case: it
        COMPLETED, so it saves like any other completion, and the failed batches are
        simply SKIPPED on the way out — a failed batch left nothing half-applied (5.5),
        so there is nothing of it to write, and that is not an error to raise at save
        time (10.20).

5.11 Retrying the FAILED batches (reader, 2026-09-14: "On completion add retry button that
    will run both translation jobs on failed batches (no need to regenerate the list)").
    When a run has ended, the batches that failed are already known: they are the run's
    own batch objects, holding their items, their positions and their languages. What the
    reader wants is the obvious next action instead of a second Start:
      - the button appears on a FINISHED run that carries failed ROWS, and it covers BOTH
        translate jobs — the column pass and the row pass. Prelearn and learn are not
        translations and are not re-run by it; a run with no failures offers nothing.
      - it re-runs exactly those batches. NO scan, no re-cut, no regeneration of the list:
        the batches and their items are reused as they stand, so every id stays the
        position it always was (4.3) and the request is built exactly as before.
      - a retried batch that succeeds applies its results like any other batch (5.5) and
        stops reporting a failure; one that fails again stays failed and stays reported.
        The button re-asks, it does not promise.
      - every attempt is cost, so each send counts in the tally (5.7): this is a NEW
        attempt AFTER the automatic retries were exhausted (5.9), never instead of them.
      - the retry's own completion saves, by 5.10's rule (a run that finished writes, a
        cancelled one does not). The original completion has already saved, so without
        this the retried results would sit app-side with only the dirty flag to show for
        them.

5.12 THE REPLY IS READ AS IT IS WRITTEN (reader, 2026-09-15: "Can we implement some
    partial result and json parsing from llm response on translations?"). The request
    goes out with `stream: true` and the reply is consumed as it arrives, so a row is
    written the moment its object CLOSES rather than when the batch ends. Landed in
    three pieces:

      the transport (`Stream.swift`, `Translation.ChatStream`)   one SSE request:
                  `stream: true`, `stream_options.include_usage` so the last frame still
                  carries the token counts 5.7 needs (`prompt_tokens`,
                  `completion_tokens`, and the cache hit either at the top level or under
                  `prompt_tokens_details`). A provider that IGNORES `stream` answers one
                  whole JSON body instead — detected from the response's content type and
                  read as a single delta, so an unstreaming provider behaves exactly as it
                  did before. A provider that rejects `stream_options` answers 400 before
                  writing a byte, so the attempt is repeated once without the flag: the
                  run loses the token numbers, not the batch. A call that produces no
                  text throws `emptyResult`, the same reading the non-streamed client made.

      the reading (`ReplyScanner.swift`, `Validator.Scanner`)   an INCREMENTAL scan: feed
                  it what has been written since the last call, take the rows that just
                  closed, in order. A row is found whatever shape the model wrapped it in —
                  a plain array, a markdown fence (the MARKER is skipped, not the line, so
                  an array that starts on the fence's own line is still read), prose around
                  the JSON, an id-keyed object, a wrapper (`{"translations": [...]}`), one
                  object per line, a plural answer (an object of categories under `text`,
                  carried as its own JSON so `decode` reads it back), an id echoed as a
                  number or a string, a trailing comma before a closing brace — and a reply
                  that was CUT keeps every row that completed. `Validator.answers(in:)` and
                  `Validator.isTruncated` are this same read over a whole reply, which is
                  what the batch's own validation asks.

      the writing (`Runner.applyRow`)   each closed row is decided ON ITS OWN, with the
                  batch's own rules: `Run.writable` for the slot, the same decoder, the
                  same defect check. A row the run may not write is discarded (4.6); a row
                  with a defect is marked failed with that defect and reported ONCE (the
                  batch's own pass skips what this already decided — the defect used to
                  arrive twice); a row that lands is written immediately, one transaction.
                  Only the stages that answer ROWS do this (`vertical`, `horizontal`,
                  `prelearn`): a learn fold answers document text, and its reply must move
                  no slot, so its text is only collected.

    What this changes in the failure paths:
      - a call that BREAKS before any text arrived is thrown, and 5.9's retry re-asks the
        same request — nothing was written, so nothing is wasted by trying again.
      - a call that breaks AFTER rows arrived is a cut reply in every way that matters:
        the rows it delivered stay written, and the rows the cut lost are re-asked in
        halves (5.3). No whole-batch re-ask, which would pay a second time for rows that
        are already on the page.
      - a broken call does NOT park Muse. A park is evidence about the PROVIDER, and a
        stream that died mid-answer after delivering text is not: parking it would make
        the run wait out the cooldown before it may re-ask for the rows it just lost. A
        call that delivered NOTHING still parks, exactly as before.
      - the reply's text is kept on the batch as it grows (`retain` per closed row), so a
        stage page (8.1) shows the answer ARRIVING instead of a box that fills at the end,
        and a reply that broke keeps what it had.

    What it does not change: the ids are still batch positions, one request is still one
    batch and one attempt is still one send (5.7/5.9), and the batch's own validation and
    write-back still run at the end of it — over the rows the per-row pass left, which in
    the ordinary case is nothing.

## 6. Memory and the imported database

6.1 The language doc is 1 000 characters on purpose: per-key knowledge belongs in
    translation memory, which answers an exact (source, key, value) hit with no
    prompt at all. The document holds cross-key conventions only. The redesign
    dropped memory entirely and that is why the cap looks impossible. Memory is per
    project for the same reason the language document is (10.1, resolved): a gold
    entry is a lesson about THIS project's vocabulary, not about Russian.

6.2 Memory entries carry gold (a human confirmed value — written by learn) and
    hints (a machine value). A gold hit resolves a slot with no model call; a
    hint may be shown but never overrides an existing human value.
    Resolution is by (source text, source language, target language) and it is
    GLOBAL, not per project (reader, 2026-09-14). `TranslationMemoryEntry`'s own
    contract says so: "one remembered translation per (sourceText, sourceLanguage,
    targetLanguage), shared across projects. Gold is gold — a reviewed entry
    auto-resolves as `reviewed` in ANY future catalog", its `#Unique` constraint
    covers the triple alone, and `projectTag` is documented as informational
    ("Project the entry was created from (informational; entries are global)").
    The old lookup agrees — `TranslationMemory.entry`'s predicate matches the
    triple and nothing else. So one confirmed source -> target pair is reused in
    EVERY project that asks for the same source text in that target language. An
    earlier draft of this section narrowed resolution to the project ("with the
    project tag narrowing it") and a `Store.memory` that filtered on the tag was
    implemented that way. That was wrong against the app's own model, and the read
    has since been REMOVED: the live path is `Memory.entry(source:language:)`, which
    is global, and the tag travels for provenance only, never as a filter. One wart
    is left for a future reader rather than fixed here: `Memory.clearHints` /
    `Store.clearHints` still narrow the hint rows by the project tag, which means
    nothing now that hint rows are shared (the tag follows the last writer). It has
    no caller today; when it gets one, decide whether it means "this language's
    hints" or "this project's". The status a resolved slot carries, and whether a
    memory answer may replace machine text, were 10.19 — answered: the slot reads
    reviewed, and yes, a memory answer replaces machine text (a machine-only entry
    fills emptiness only).

6.3 The imported database (the shipped human translations in SQLite) resolves
    slots to `.imported` before any model call, marks them auto-confirmed, and
    writes NO memory entry: it is the source of truth it is, not a lesson about
    our model. It is the one source that stays GLOBAL — shipped translations are
    not this project's lessons, and every project should be able to read them.
    The artifact DOES get the value: `.imported` writes as `"needs_review"` (2.1,
    reader 2026-09-16) — the status itself stays app-side, the value and its
    unreviewed state do not. A run still never overwrites the slot (`.imported`
    is out of every write-back's write set), and the confirm click is the only
    thing that promotes it to `"translated"`.

6.4 The horizontal pass must not resolve through the imported database: with the
    freshness gate lifted it would replace existing machine values with shipped
    ones, which is not what "apply my rule" means.

## 7. Persistence: SwiftData, and what that makes synchronous

7.1 Translation state STAYS IN SWIFTDATA (reader, 2026-09-13). That is a design
    decision with a visible consequence: reading a context document, a slot, a
    journal row or a memory entry is a FETCH on the main actor, so the redesign's
    loads are synchronous (`throws`, not `async throws`). The rule the redesign
    follows:

      SwiftData                        -> synchronous, `throws`
      a model call                     -> `async throws`
      the .xcstrings (open, parse, write) -> `async` (file I/O, no model)

    Broken down per call: `Context.init`/`loadContext`/`save`,
    `Global.init`/`loadProject`/`save`, `Project.init`/`loadLanguages`/`loadData`/
    `saveData`/`addLanguage`, `Language.init`, every stage factory, `Memory.resolve`/
    `upsert`/`clearHints`, the `Imported` lookup and the whole `Store` are
    synchronous. What stays async is exactly three things: `compressIfNeeded`
    (a model call), the catalog layer's file work (opening and parsing the
    .xcstrings when a project opens, and writing it on Save), and everything the
    runner does per batch.

7.2 The store (`Store.swift`) is the app's SwiftData container seen from the
    redesign: one container for the app, the main context for translation state.
    It uses the models the app already has, additively:

      ContextDoc              context documents. `identifier` is the project id for
                              a project document and the FULL scope id,
                              `"project/<id>/language/<code>"`, for a language document
                              — which is what keeps per-project language documents
                              apart (10.1). A language document does NOT set its
                              `project` relationship: that is the to-one inverse of
                              `Project.contextDoc`, the property the old browser reads
                              for project rules, so only the project document owns it.
                              Uniqueness is (scope, identifier, project). A to-many
                              `documents` on `Project` was the alternative and was
                              rejected: it means re-reading a model the old pipeline
                              depends on, and the full id costs nothing.
      RunCursor               the redesign's only addition to the schema (10.16): one row
                              per (project, scope) holding the batch cursor a paused or
                              relaunched run resumes at. Durability and size are why it
                              is not three keys in UserDefaults (5.6). The tally stays
                              on the Run.
      TranslationRecord       one slot per (key, language). The redesign needs three
                              bodies where the model has one value: `value` IS
                              `target`; `machine` and `reviewed` are additive
                              columns with inline defaults (`var machine: String? =
                              nil`) — the additive-migration style the app already
                              uses for `autoReviewed`, `note`, `maxWidth`.
      TranslationEdit         the journal: append-only before -> after, and the
                              learning corpus. `isUserConfirmed` is what marks an
                              edit as a lesson.
      TranslationMemoryEntry  per-key memory. The model declares the table global
                              and `projectTag` informational; the redesign leans on
                              that column, because memory is per project for the
                              same reason language documents are.
      Project                 the project row.

7.3 Two rules survive unchanged from the current implementation, both because we
    stay on SwiftData:

      - the SENTINEL rule: SwiftData on this SDK decomposes `ContextVersions` into
        nullable columns and crashes re-faulting an all-nil row, so every write of
        a version stamp goes through the fixup — an all-zero `Context.Version` is
        stored as the sentinel (global 0), never as three nils. `Context.Version`
        (three non-optional ints, 0 = "no document existed") maps onto
        `ContextVersions` through that one function.
      - the ADDITIVE rule: a new column is added with an inline default, so the
        existing store migrates without a custom migration stage. That is how
        `machine` and `reviewed` arrive too.

    There is no separate importer to write, and nothing to migrate for state:
    the values already in the store stay where they are, and the redesign reads
    them with a different projection.

7.4 The Save rule survives: `Save` is the only writer of the `.xcstrings`, and it
    keeps writing through the catalog model (`StringCatalog`) the app already has,
    so the file-format work is not re-done in the redesign. The store is written
    after it.

7.5 Clearing the store (reader, 2026-09-14: "Add button that clears all SwiftData
    cache"). One button, app-level, that empties the translation store and leaves the
    artifact alone. The scope is the whole point, so it is written down:
      DELETED   `TranslationRecord` (every slot's value, status, `machine`, `reviewed`),
                `TranslationEdit` (the journal — the learning corpus), `ContextDoc` and
                `ContextEdit` (the global, project and language documents — the
                accumulated lessons), `TranslationMemoryEntry` (gold AND hints),
                `RunCursor` (every resume position).
      KEPT      `Project` — the registry of names, catalog URLs and roots. It is
                configuration, not cache: clearing it would empty the sidebar and
                nobody asked for that. Every `.xcstrings` file is untouched, which is
                what makes this survivable.
    What that costs, stated because the button must say it too: the context documents
    and the memory are NOT re-derivable from the catalogs. They are what the app learned
    from the reader's own corrections, and this throws the learning away with the cache.
    What the clear COSTS to run (measured 2026-09-14, through the real
    `TranslationStore.clear()` compiled against the whole tree, on a copy of the reader's
    own store — /tmp/dev-clearstore-cost-probe). The first version deleted the rows one
    OBJECT at a time, and that price is quadratic in the two big tables: SwiftData
    maintains the to-many inverse on every removal, and `Project.records` /
    `TranslationRecord.edits` are to-many ARRAYS, so each removal is linear in the
    children already there. 2 000 slot records took 2.80 s, 5 000 took 13.46 s, 10 000
    took 49.68 s (N^1.9), which puts the reader's store — 167 174 slot records and 10 569
    journal rows when this was measured — in the HOURS. Chunked saves, fresh contexts and
    background contexts change nothing (measured on the parent card). The cheap form was
    not available because CoreData refuses a store-level delete when a child's to-one is
    MANDATORY ("Constraint trigger violation: Batch delete failed due to mandatory OTO
    nullify inverse on TranslationRecord/project") — and that mandatory flag is not what
    the to-one declares, `TranslationRecord.project` has always been `Project?`: SwiftData
    derives it from the OPTIONALITY OF THE INVERSE ARRAY.
    THE FIX, which is the decision this section now carries: the three inverses are
    declared OPTIONAL (`Project.records`, `TranslationRecord.edits`, `ContextDoc.edits`),
    which makes the store-level form legal, and `clear()` uses it for every table —
    falling back to the row-by-row form only for a store that refuses it. Nothing else
    about the button moves: the same six tables, the same `Project` registry kept, the
    same in-memory drop first, the same confirmation, except that its last line now says
    what the delete does instead of warning about a row-by-row cost.
    MEASURED AFTER THE FIX, same probe and the same store copies: 0.12 s at 5 000 slot
    records, and 0.82 s at the reader's full size (167 174 slot records, 10 569 journal
    rows, 8 684 memory entries, 2 run cursors — every table read back at 0 with sqlite3,
    `Project` still 3 and still named). The model change is a LIGHTWEIGHT migration, and
    it was run as one: the reader's store opened with every row intact and every record
    still reachable through its to-one (`Reconcile.records(of:in:)` read 26 156 + 141 018
    rows, the numbers sqlite3 counts), and a pre-fix build opens the migrated store too.
    Two engineering requirements come with it:
      - a cleared store with a live in-memory cache is worse than no button. The app
        mirrors the store in `LocalizationStore`, and the redesign holds `Shell`/`Store`
        caches (slot records, workspaces, per-stage runs and their batches, cursors).
        After a clear those must be reloaded or dropped, and a run in flight must either
        block the clear or be stopped by it — decided and stated, not left to chance;
      - a confirmation first, naming what goes and what stays. This is the one button in
        the app whose loss cannot be rebuilt by re-scanning.

7.6 A session write is ONE transaction (reader, 2026-09-14: "saveData() takes too long.
    Is it because context.save called on each row?"). It was, exactly: `saveData` walks
    every row, every slot and every form, and `Store.upsert` and `Store.append` each ended
    with their own `context.save()` — one transaction per record, on the main actor, plus a
    second save for every journal row. That is why a real project's session save takes
    minutes. The write path now takes `saving:` (false inside a batch) and the session pays
    ONE `Store.save()` at the end; a throw rolls the batch back (`Store.rollback`), so a
    failed session write leaves nothing half-applied for a later, unrelated save to flush.
    The change gate stays, for a different reason than it was written for: skipping a record
    that already matches keeps `updatedAt` meaning when the slot last MOVED, not when a
    save last ran.
    The same shape now holds in the RUNNER's write-back, which is where this note said it
    should land (2026-09-15): the streamed path writes its rows with `saving: false` and
    the batch's own end pays the one `Store.save()` (`Runner.commit`, and 5.5 for the
    measurement that forced it — 178-228 ms per save, so one per row was the whole of a
    working core).

7.7 A READ SCALES WITH ITS ANSWER, NOT WITH THE TABLE (reader, 2026-09-15: a profiler trace of
    the LAUNCH — `Shell.focus` -> `Global.loadProject` -> `Project.init` -> `loadLanguages` ->
    `Store.records` -> `Sequence.sorted(by:)`). Two things were wrong on that path and both
    were the store's doing:

      - `records(project:)` SORTED what it fetched, by the tuple `(key, language, category)`,
        that being a tuple of `String`s and therefore a Unicode comparison per field per
        comparison. Measured on the reader's own store (26 156 records in one project): 1.4 s
        of the call's 1.9 s. Nothing wanted the order — all five callers (`Project.loadData`,
        `Project.saveData`, `Runner.slotRecord`, `Workspace.records(of:)`, `loadLanguages`)
        index the result by (key, language, category) — so the sort is GONE and the method is
        documented as unordered. A caller that wants an order sorts the few rows it is about.
      - `loadLanguages` wanted the COLUMN SET and asked for the rows: it fetched every record
        of the project, materialised it, and threw all but one column away. It now asks
        `Store.languages(project:)`, which is one `LIMIT 1` fetch PER LANGUAGE (excluding the
        codes already found) — the work scales with the answer. Measured: 33 languages in
        0.05 s, against 2.0 s for the fetch-and-sort it replaces, and the list is identical.
        A one-column fetch of every row is NOT the answer: `propertiesToFetch` still builds a
        row object per record (0.50 s here).

    The whole launch path went from 2.0 s to 0.09 s for that project and from 10.5 s to 0.82 s
    for the largest one in the store (97 languages) — where what is left is one
    `Context(scope: .language)` per language, i.e. 97 small document fetches, not the store's
    rows. That is the next thing to price, not this one.

## 8. The workspace (UI gaps)

8.1 The redesign has stages and no surface. The surfaces it needs, each bound to
    state that already exists in the stubs:

      entry          a project opens into its translation workspace; the global
                     object owns the project registry, so the workspace is a
                     projection of `Project`
      run control    `Start` is the one button, and the overlay is where it lives:
                     it runs the main flow's whole plan — prepare -> prelearn ->
                     learn -> translate -> the row pass — and the rail shows each
                     step's PROGRESS rather than offering a button per stage (a step
                     with nothing to do reads as a step that did nothing). Prelearn,
                     learn and the row pass are not controls of their own, and the row
                     pass is ALWAYS enabled (10.17): nothing gates it behind a
                     confirmation, and nothing needs enqueueing for a newly confirmed
                     value. Because a run ends with the row pass, "verify, then Start
                     again" is the whole correction workflow.
      presentation   the stage pages are a CLOSABLE OVERLAY, not a page of the app.
                     Closing it must not stop a run: the bottom status bar carries
                     the run's state (running, step, done/total, failure) and reopens
                     the overlay wherever the run is now.
                     WHERE the controls sit once the shell is wired (reader,
                     2026-09-14): `Start` is a button in the TOOLBAR, and the reopen
                     button belongs to the bottom STATUS BAR at the foot of the
                     translation pane. The old pipeline's own Translate button is not
                     removed and not rerouted (10.9): both runs are reachable.
      stage pages    every stage page is SPLIT IN HALF (reader, 2026-09-14): the
                     request's own items on the left, and on the right BOTH SIDES of
                     the exchange — the model INPUT that was sent (system + user, as the
                     wire carried them) and the model's RAW reply for that batch
                     ("Add model input to that model reply view", reader, same day).
                     Raw, not parsed, on purpose — what the validator accepted, what it
                     rejected and how the batch was written is then visible
                     instead of inferred. It is also written as it ARRIVES (5.12, reader
                     2026-09-15): a batch in flight shows the text the model has produced so
                     far, rather than an empty box until the reply is complete.
                     The MARK belongs to the ROW (reader, 2026-09-15: "Mark rows as
                     translated/failed in realtime in UI and automatically scroll to
                     last translated row (center anchor)"): a row is marked the moment
                     it LANDS, not when its batch ends, and the list FOLLOWS it. Both
                     halves are the same rule read twice — the row's phase is published
                     on the RUN's own copy of the batch the moment it is decided
                     (`Runner.publish`; without it a page would keep showing a row that
                     is already written and saved as one still waiting, because
                     `performOne` works on a value and writes it back only when the
                     batch returns), and the page's list keeps the LAST ANSWERED row
                     CENTRED (`Translation.lastLanded` + the list's own
                     `scrollPosition`, the same binding the batch pager above uses).
                     No pacing here, unlike the batch pager: a row that has landed is
                     already written, so there is nothing to wait for — a page opened
                     mid-batch lands on the newest one at once.
                     THE MARKS CARRY NO ANIMATION (reader, 2026-09-15: "I have
                     disabled animations"). It took three passes to get there and the
                     history is the reason the design is what it is:
                       · first the mark animated on ANY change to the row's value, with a
                         stagger of `index / 10` and NO ceiling — a row 300 rows down
                         scheduled its animation thirty seconds out, and with rows landing
                         continuously (5.12) transactions never stopped arriving. A Time
                         Profiler sample put 87,6 % of a working core inside SwiftUI's own
                         view graph updates, which is that backlog and nothing else;
                       · then the animation hung on the MARK's own colour with the stagger
                         clamped (`Translation.stagger`, twelve rows) — the wave a batch's
                         marks used to land in, bounded;
                       · then the delay was dropped (reader: "Disable that delay as we are
                         already updating in realtime"): a wave paces marks that arrive
                         together, and rows arrive one at a time, so each landing settled on
                         its own;
                       · and now there is no animation at all, because every one of those
                         changes was still a SwiftUI transaction and a run moves this row on
                         every landing.
                     A mark is a STATE. It reads as one the moment it lands.
                     What is still animated on these pages is deliberate and small: the
                     pager's own pacing scroll (`withAnimation(.smooth)`, one per index
                     change, 8.1's pacing budget), the overlay's presentation
                     (`WorkspaceView`, one per open/close), and — on the learn, prelearn and
                     row-pass pages — `contentTransition(.symbolEffect)` on the rows, so a
                     mark's SF Symbol still swaps with its effect. That last one is a
                     per-CHANGE transition on the mark itself, not a standing wave; the
                     column page (DesignUI) no longer carries it, which is an INCONSISTENCY
                     the reader has been told about rather than quietly evened out.
                     WHAT A PAGE PAYS for that mark is measured by what it reads: a
                     page re-derives its WHOLE page set from `run.batches` on every
                     change of it, so publishing once per row cost one full page
                     mapping per row. The publish is therefore COALESCED to at most
                     one change per 150 ms — `Runner.publishWindow` — which is below
                     what a reader notices, while a FAILURE is never delayed because
                     it is the row a reader is looking for. The batch's own end writes
                     the whole value back regardless, so nothing can lose a phase.
                     THE SAME READING APPLIES TO THE COUNTS the shell shows: the
                     sidebar's badge/status line counted distinct review keys by
                     WALKING `project.records` — the SwiftData to-many RELATIONSHIP,
                     faulting one object at a time — from a VIEW BODY, so every
                     re-render of that line re-paid the walk. Measured on the reader's
                     own store before the fix: 2.87 s for the `Dev` project's 26 156
                     records, i.e. seconds of CPU per frame while a run was working.
                     It is now a STORED `LocalizationStore.needsReviewKeyCount`,
                     rebuilt only where records change (`markDirty` — which a run's
                     publish and finish funnel through — and the load path) from ONE
                     fetch of three fields and no object graph.
                     A failed row carries its own xmark and its siblings keep their ticks, and the
                     batch's own mark appears only when the batch wrote nothing. One request is one batch, so a
                     page shows exactly one exchange: a batch still in flight says so
                     (there is no input to show until it is sent), and a batch that
                     failed shows both sides anyway. The INPUT marks where the provider's
                     cacheable prefix ends, because that byte-prefix is what the cached
                     share in the tally is about (5.7) and a flat zero means it moved.
                     The run has to retain the input PER BATCH for this, the way it now
                     retains the reply. A step whose page has no batch keeps its
                     single-pane notice: there is no exchange to show.
                     PACING (reader, 2026-09-14): a page does not jump the instant a
                     batch finishes. A change of index scrolls after a short pause —
                     two seconds — so a finished batch is READ before the next takes the
                     screen. The delay is PRESENTATION ONLY: it never holds the run back
                     (the run advances at its own pace and the page catches up), a newer
                     index recomputes it rather than queueing behind the old one, and
                     the first appearance is not delayed at all (a page opened mid-run
                     goes straight to the batch the run is on).
                     The pause is a BUDGET measured from the LAST SCROLL, not a fresh
                     timer per change (reader, 2026-09-14): a batch arriving 0.5 s after
                     the previous one waits the remaining 1.5 s, so a run that produces
                     batches quickly keeps advancing the page instead of postponing it
                     forever. `.task(id:)` CANCELS the old task on every change — that is
                     the framework's contract, not something the closure controls — so a
                     plain `Task.sleep(pacing)` there would restart the two seconds each
                     time; the wait is computed from the shared deadline instead.
      language bar   the selected languages as columns (the Add Language overlay
                     and the toggle list already exist in the current UI and are
                     worth carrying over), each with a progress reading
      table          rows of `LocalizationKey` x language slots, the existing
                     browser's affordances: state badge, provenance tooltip,
                     width badge, inline editor, plural forms editor
      review         the human actions that move a slot to `.verified`: confirm,
                     confirm row, mark needs review, ignore, and the note editor
                     (memo vs project rule)
      inspector      what the model actually saw (the current row inspector's
                     trace summary), plus the batch it went out in
      run            progress, per-model tally, cached share, pause/cancel, and
                     the untouched-artifact reminder

8.2 State colours must read the same everywhere (badge, tooltip, filter):
    `.needsTranslate` and `.stale` are work to do, `.translated` is unreviewed
    machine output, `.imported` is unreviewed shipped output, `.verified` is
    done, `.ignore` is out of scope. Two "unreviewed" states exist on purpose
    and must not share a colour: the human has to know whether the value came
    from our model or from the shipped database.

8.3 A run's edits are in memory until Save. The workspace owes the user the same
    three-way contract the app has today: save, discard, or stay, with the
    prompt shown on close.

## 9. Validation, width and plurals

9.1 Placeholders, ids and empty are validated deterministically and for
    free; only survivors are written (5.3).

9.2 Characters, not tokens: the models routed here have very large context
    windows, so a grapheme count is accurate enough and costs nothing. This is
    why batches are measured with `StringBody.characters` and why there is no
    tokenizer in the design.

9.3 The width guideline travels with BOTH translate requests (reader, 2026-09-14: it
    goes to "the vertical translator and horizontal translator"): it is part of the
    item's field set (4.3), emitted whenever it is non-zero, and the translate system
    text tells the model to keep within it. This REVERSES a rule the current pipeline
    documents and defends — `plans/translation-flow.md` states it is never sent, on the
    grounds that "a width constraint in a translation prompt degrades the
    translation" — and it is now the ONLY channel: the reviewer that used to receive
    `maxChars` for an over-wide candidate is gone (5.4), so nothing shortens a value
    after the fact. The browser's width badge stays advisory (it changes no state and
    never blocks "Verified"). If translations start reading terse-but-awkward, the
    first thing to try is dropping the field again — it is one line of the payload.

9.4 Plural rules: the stub's table is COMPLETE relative to what the app uses, and
    the real gap is that there are two copies of it. Measured 2026-09-13: the
    switch in `Plurals.swift` and `PluralRules.nonDefault` (Xcode's own table plus
    three CLDR fills for `ars` / `sa` / `sat`) are the same 58 entries, entry for
    entry. So nothing is missing relative to the current app, and nothing else
    falls back wrongly: every language ABSENT from the table is one/other in CLDR,
    which is exactly what `default: [.one, .other]` returns. (An earlier note here
    claimed the default wrongly grants a dual to `hi`, `fa`, `tr`, `sw`, `af`. It
    does not — those are one/other. The mistake was reading "absent from the table"
    as "absent from CLDR".)
    What IS wrong is relative to CURRENT CLDR (`cldr-json` `plurals.json`: 224
    locales, 86 with a non-default set), and it is inherited from Xcode's snapshot
    rather than invented here:
      - 27 locales the table lacks, which therefore get the default one/other:
        other-only jv, su, wo, tpi, jbo, nqo, osa, hnj (a bogus `one` is offered
        for these); one+many+other es, fr, it, pt, pt-PT, ca, vec, scn, lld (the
        CLDR 42+ `many` for 1e6-class values is missing); one+few+other sh, mo;
        one+two+other sma, sms, smj, smi; zero+one+other cv, prg, blo; and
        one+two+few+many+other sgs;
      - 3 entries whose set DIFFERS: kw (table has one/two/other, CLDR has
        zero/one/two/few/many/other), mt (table has no `two`), he (table has a
        `many` that CLDR does not).
    So "can it be completed" is yes — but the target has to be chosen first, which
    is 10.13. Completing it by hand is the wrong shape either way: one table, one
    place, read or generated.

9.5 `Plural.rules` must normalize the base code (`pt-BR`, `zh-Hans`, `es-419` →
    pt, zh, es) as `PluralRules.categories(for:)` already does. Switching on the raw
    string sends every region-tagged code to the default and silently drops the
    forms of the language it names.

9.6 Plural generation as a row action ("generate the missing forms from the
    source's forms") is a separate operation and does not belong to a run.

## 10. Decisions left open

- [x] 10.1 Language document scope: PER PROJECT (reader, 2026-09-13), as
      `Language.init`'s id string intended. `Context.Scope.language` carries the
      project id and the code, the document lives in the project's directory, and a
      lesson never leaks between projects.
- [ ] 10.2 (unchanged) A writer for the global document. Nothing writes it today,
      which is what makes its auto-enqueue harmless. Options: a global glossary
      editor, or the project list's "shared vocabulary" note. Recommendation: none
      until a project's language document demonstrably runs out of its 1 000
      characters.
- [x] 10.3 Where the app keeps its own notes about translations: SWIFTDATA
      (reader, 2026-09-13), and the redesign's load calls become SYNCHRONOUS
      because of it (7.1). The models stay the app's own — `ContextDoc`,
      `TranslationRecord`, `TranslationEdit`, `TranslationMemoryEntry`, `Project` —
      extended additively where the redesign needs a column the model lacks
      (`machine`, `reviewed`), so there is nothing to migrate and no importer to
      write. The price is the sentinel rule: an all-nil version row still has to be
      lifted on write, or the store crashes re-faulting it.
- [x] 10.4 `FullRow` DELETED (reader, 2026-09-14). It was never used and
      `LocalizationKey` already is the row.
- [x] 10.5 Per-form status: NONE (reader, 2026-09-13). In Xcode a plural behaves
      like any other string — reviewed / needs-translation applies to the whole
      language row — so the slot's status covers all of its forms. There is no
      `forms` map; `Plurals` keeps only `value(for:)` / `set(_:for:)` so a stage can
      address one form, and a write-back stamps the same state on every form of the
      slot.
- [x] 10.6 MOOT (reader, 2026-09-14): there is no gate any more (5.4), so a row pass
      cannot have one of its own. The per-item language naming stands.
- [x] 10.7 Prelearn is an OPERATION OF THE TRANSLATE RUN (reader, 2026-09-13), not
      a pass of its own: preparation first (scan the catalog, merge it into the
      in-memory catalog, load the data), prelearn second, then learn, then
      translate. Every slot matching its predicate is prelearned inside that same
      run, so nothing has to be enqueued and nothing waits for a later explicit
      pass. `Run.plan(for:)` encodes the sequence.
- [ ] 10.8 The redesign's `Context.append(value:)` bumps the version per call.
      Canonicalization (3.8) makes most calls no-ops; the version must bump per
      *real* change, or the whole column goes stale on a repeated lesson.
- [x] 10.9 Where the redesign's operation classes live, and whether the old pipeline is
      deleted: they stay beside `Localization/Redesign/`, and the OLD PIPELINE STAYS
      (reader, 2026-09-14). No cut-over commit, nothing deleted. The redesign is an
      addition, not a replacement: both pipelines are reachable, the old one from its
      existing controls and the new one from its own `Start`, until the reader says
      otherwise. This also removes the reason the recommendation existed — a second
      pipeline was the price, and it is now the intent.
- [ ] 10.10 Global cap 10 000 (the redesign's `Global.init`) versus the current
      builder's 5 000: one number, in `Translation.Limits`.
- [ ] 10.11 How a CHANGED project rule reaches machine-translated slots. Now that
      the row pass carries no selection (4.6), it writes only slots whose status
      allows it, and a value that an earlier rule produced is `.translated` — not
      `.stale`, because a project-document bump deliberately enqueues nothing (3.4).
      So editing a rule reaches those values through neither pass. Two answers, each
      a status decision rather than a selection filter: either a project-document
      bump marks the project's machine-translated slots `.stale` (an explicit sweep
      the user asks for), or a rule stays advisory for existing values and only new
      work follows it.
- [ ] 10.12 The row pass's cost: it re-sends every language of every row, so it is
      the expensive shape by construction (4.6). If it is meant to be used on whole
      projects, the confirmation should quote the rows and the settled columns it
      will pay for; if it is meant for spot work, run it from a selection instead.
- [ ] 10.13 Which table is the authority for plural categories: Xcode's own (what
      runs today, and what the .xcstrings editor agrees with) or current CLDR
      (27 more locales, 3 corrected sets — 9.4). They cannot both win. A `many`
      form for Spanish that Xcode's editor does not offer is a category the IDE may
      not display; a missing `one` for Javanese is a form the user can fill and
      `xcstringstool` accepts (probed). Recommendation: Xcode's table decides what a
      catalog may CONTAIN, and the CLDR delta is a verified add-on list re-checked
      on each Xcode update — but one table, one place, whichever wins.
- [x] 10.19 The memory resolve (reader, 2026-09-14):
      (a) a remembered human value REPLACES machine text already in the slot —
          `.stale` and `.translated` alike. A human's choice beats a machine's
          output; the only value that is never overwritten is another human's
          (`.verified`, `.imported`).
      (b) a memory-resolved slot reads `reviewed` — the model's own contract ("a
          reviewed entry auto-resolves as `reviewed` in ANY future catalog"), so it
          is frozen for writing — and it STILL travels in the row pass, as context.
          The row payload already carries every language including the settled ones
          (4.6), which is exactly the readonly-for-context role the reader asked
          for: resolving through memory removes the slot from the row's WRITE SET,
          not from the row's view.
      (c) a MACHINE-only entry fills every EMPTY slot it matches — "machine fills
          all empty values as they shouldn't be empty" — as `.translated`, the old
          pipeline's needs_review role, and it still never overrides a human value.
          Together with (a): gold replaces machine text, a hint only fills
          emptiness.
      Resolution is global (6.2), so all three apply across projects.
- [x] 10.20 Does a run that does NOT finish still write? ANSWERED (reader, 2026-09-14):
      a CANCELLED run skips saving — the user stopped it, so the write waits for an
      explicit Save, and what it applied stays app-side until then (5.6). A run whose
      batches FAILED is not that case: it completed, so it saves, and the failed batches
      are skipped on the way out — they left nothing half-applied (5.5), so there is
      nothing to write for them and nothing to report as an error.
- [x] 10.14 `maxWidth` TRAVELS with a vertical request (reader, 2026-09-14), which
      departs from the current pipeline: it keeps the width guideline out of every
      prompt on the grounds that a width constraint degrades a translation, and
      sends `maxChars` only through the gate — which is itself gone now, so the width
      field is the only channel there is (9.3). Recorded as a decision
      rather than a fill because it reverses an earned rule — the thing to watch is
      a translation that reads as if it were written to a budget instead of to the
      UI. Dropping it again is one field of the item payload.
- [x] 10.15 The item payload is a closed set: `comment`, `maxWidth`, `source`,
      `target` — and never the key (4.3). Two consequences already folded into the
      design: the echo ids are batch positions rather than keys, and "row has no
      source" is no longer a reason to skip a row anywhere (a row with nothing
      authored sends its key as the content).
- [x] 10.16 The new stages write to the SAME SwiftData records the old pipeline reads
      (reader, 2026-09-14): one store with two writers, so the old browser shows what a
      new run wrote and a new run sees what the old one left. New logic writes only
      through `Store`, and the old pipeline stays exactly as it is (10.9, settled: it
      is NOT deleted).
      The price is the two mappings settled with it: the `RunCursor` row above (the one
      schema addition) and the full-scope-id rule for language documents (§3.1, §7.2).
- [x] 10.17 The row pass runs AFTER the vertical translation pass and is ALWAYS
      enabled (reader, 2026-09-14): it is the last step of the main flow's plan, not a
      setting and not a separate control. The consequence is on purpose — the
      correction workflow is just "verify, then Start again": the vertical step finds
      nothing to redo, prelearn and learn fold the new lessons, and the row pass
      carries them into the other languages of every row.
- [x] 10.18 Moot. A pass that always runs has nothing to prefer, and the rows with
      something settled are where it has work anyway. The rows without one are the
      price of having no selection and no staleness question anywhere in the shape.
- [x] 10.21 Which writer wins when the browser and the redesign are open on the same
      project (reader, 2026-09-16): the STORE. The redesign's rows are a snapshot taken
      at its open, and its Save wrote that snapshot over both halves of the world — the
      records (`saveData`) and the artifact (through `publish`) — which silently reverted
      a hand edit made in the browser: the record came back `reviewed` + `autoReviewed`
      with the shipped value (so the "auto" badge returned) and the file got the same
      shipped text back as `needs_review`. Now the session ADOPTS every slot whose records
      moved after it loaded, before it publishes or saves (`Project.adoptForeignWrites`,
      called from `save()` and from a new `run()`). Rejected for now: refusing the save
      while the world moved under the session (no data rule to reason about, worst UX at
      the moment the user wants the write) and a human-only guard (it would not cover a
      newer MACHINE value written by a second writer, which is the same class).

## 11. What this pass changed in the redesign folder

      Design.swift        + Limits, Context.Scope/Version/Storage and the
                          load-save-compress signatures, Project row index and
                          accessors, LocalizationKey.key/translatable/Identifiable,
                          slot predicates and status semantics, StringBody
                          catalog encode/decode and placeholders, unified
                          Operation protocol, Stage enum
      Vertical *.swift    + key and stage on every operation, the shared batch
                          splitting through Limits, scan and apply contracts, the
                          learn/prelearn predicate and comparison fixes
      Horizontal *.swift  + the whole-row payload (settled columns included), no
                          selection on the shape, the write-back guard, the
                          per-item language, the L0/ITEMS note
      Plurals.swift       + form accessors, the rule-table provenance note
      Runner.swift        new — run state, batches, routing, validation,
                          checkpointing, telemetry
      Prompt.swift        new — L0/L1/L2 and L0/ITEMS assembly, learn fold,
                          compression prompts
      Store.swift         new — the SwiftData store: the model map (context docs,
                          slots, journal, memory, cursor) and the sentinel /
                          additive-migration rules
      Memory.swift        new — translation memory (gold/hint) and the imported
                          database resolve
      Workspace.swift     new — the run's UI state and the write-back contract

Every declaration added here is a signature with an empty or placeholder body:
the folder compiles and changes no behaviour.

Resolved by the reader in this pass: 10.1 (language documents are per project),
10.3 (state stays in SwiftData, so the loads are synchronous), 10.5 (no per-form
status — a plural is one slot, as in Xcode), 10.7 (prelearn is the second operation
of the translate run, after preparation), 10.14/10.15 (the item payload is comment,
maxWidth, source and target — never the key, and the key stands in when no source was
authored), 10.17/10.18 (the row pass is the LAST and ALWAYS-ON step of a run), and the
row pass's shape: no selection, the whole row travels, the write-back refuses settled
slots. Also settled since the first draft: Muse is the only model, the new logic runs
beside the old one (10.9: it stays there), and the UI is a closable overlay with a bottom
status bar — `Start` in the toolbar, the reopen button on the bar. `FullRow`
is deleted (10.4), the records are shared with the old browser (10.16) and the cursor
lives in a `RunCursor` row. Still open: 10.2, 10.6, 10.8, 10.10, 10.11, 10.12, 10.13,
10.19 (the memory resolve: replace machine text? which status? may a machine hint fill an
empty slot?).
