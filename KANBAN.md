Dev — Translation redesign: kanban board
Date: 2026-09-14   Board: dev-translation-redesign   Workdir: /Users/v57/Projects/Dev

STATUS   (updated 2026-09-14 01:52 — this doc is a narrative; the BOARD is the state:
          `hermes kanban --board dev-translation-redesign list --json`)
  NEARLY DONE. 15 done, 2 blocked on the reader, 0 todo, 0 running, +1 card filed by the
  reader's last answers (the shell wiring below). The deletion half of the cut-over is
  CANCELLED: the old pipeline STAYS (10.9, reader 2026-09-14), so the app carries both
  pipelines, each reachable from its own control. What is left:
    · t_21a14f2f memory — the gold resolve needs two answers (10.11's sub-case and the
      status a gold-resolved slot carries); its hints half has landed (003f1a8) along
      with a measured fix to prelearn's write-back (ef13479)
    · the new card: wire the overlay into the shell — `Start` in the toolbar, the reopen
      button on the bottom status bar, the old pipeline's controls untouched
  DONE across the board: store (incl. `RunCursor` + the full-scope-id mapping), contexts,
  prompt, Muse router, runner, memory + imported DB, all four stages, review/edit + Save,
  the workspace shell, the row page.
  HEAD builds BUILD SUCCEEDED with zero warnings — verified by the orchestrator on a clean
  tree, not quoted from the cards' summaries.

  DONE     t_db2260b2 prompt assembly (66fa010)   t_931a3ec5 Muse client (d457ec7)
           t_9caad4dc Router.values deletion (9d60f3d)   t_7baea299 run executor (a14a0fc)
           t_34b75066 workspace: Start, overlay, status bar (cf4ad6a)
  RESUME   t_4e5d3608 Store — committed f958f75, passes the gate; verdict in its comments
                              (share · RunCursor row · full-scope-id mapping)
  TODO     t_e5686522 contexts · t_517bbe62 memory (a worker filed this one itself) ·
           the four stage cards · review/edit · row page · cutover
  HEAD is the committed tree and builds BUILD SUCCEEDED with zero warnings — verified on a
  clean tree, not quoted from the cards' own summaries.

LANDED COMMITS (local — not pushed)
  ce6ce1b  Redesign: Initial layout
  f956a59  Redesign: filled the design gaps in contexts, store, prompt, runner and the run plan
  81d5226  Redesign: added designed pages for every stage
  The working tree is clean and the committed tree is the tree that built green
  (BUILD SUCCEEDED, zero warnings) before these commits.

BOARD COMMANDS (always pass --board — the switch pointer does not persist)
  hermes kanban --board dev-translation-redesign list --json
  hermes kanban --board dev-translation-redesign show <id>
  hermes kanban --board dev-translation-redesign log <id>       # worker session, NOT comments
  hermes kanban --board dev-translation-redesign stats
  hermes gateway status                                          # dispatcher health, 60s tick

GATEWAY NOTE
  `hermes gateway status` reports the service definition as stale relative to the current
  install, and the CLI warns a previous update did not restart the running gateway. The
  dispatcher IS working (a worker is running), so leave it alone. Do NOT run
  `hermes gateway restart` while cards are active: it kills running agents.

WORKING CONTRACT (what every card body tells its worker)
  - new logic lives in Dev/Localization/Redesign/ and must NOT call LocalizationStore,
    TranslationPipeline, TranslationRouter, Stage0Learner or Reconcile; the old pipeline
    keeps working untouched
  - Muse is the only model: no free tier, no chain, no fallback
  - the spec is Dev/Localization/Redesign/Design notes.md — each card cites its section
  - an open decision (notes section 10) is NOT to be guessed; the worker asks
  - gate: xcodebuild -project Dev.xcodeproj -scheme Dev -configuration Debug
    -derivedDataPath build build  ->  BUILD SUCCEEDED with ZERO warnings
  - commit only the files you own, locally, never push, "<Scope>: <past-tense>"
  - cards are file-disjoint by design, and the graph below keeps conflicting cards apart

BASELINE (what is in the tree today)
  Design.swift        Translation.* models — Limits, Context (scope, versions, limits),
                      Global, Project, Language, LocalizationKey.content (the key-as-source
                      fallback), LocalizationString (machine/target/reviewed + status),
                      StringBody, Stage, Operation/VerticalOperation/RowOperation. Stubs.
  Store.swift         the SwiftData mapping, the sentinel rule and the additive-column rule. Stubs.
  Prompt.swift        the closed item payload, L0/L1/L2 and L0/ITEMS shapes. Stubs.
  Runner.swift        Run/Batch/Item/Phase/Tally/Failure/Validator and plan(for:). Stubs.
  Router              Muse-only client (admission + cooldown), currently inside Runner.swift. Stub.
  Memory.swift        gold/hint resolution and the imported-database lookup. Stubs.
  Workspace.swift     Start, overlay presentation, status, review and edit actions. Stubs.
  Vertical *.swift    the four stage scans and their operation shapes. Partial — scan exists,
  Horizontal *.swift  execution and write-back do not.
  *UI.swift           the four designed pages, now BOUND TO THE LIVE RUN (the row page
                      also reads its project's journal); the ten-item sample fixtures stay
                      for the previews. Done.
  Design notes.md     the spec: rules, the gap analysis, and the open decisions in section 10.

TASK LIST (id, priority, parents) — statuses below are from DISPATCH time; the DONE/BLOCKED
list at the top of this file is the current state.

  Phase 1 — foundation
    t_4e5d3608  10  Store: SwiftData mapping                       RUNNING
    t_e5686522  11  Context documents: load/save/append/compress   todo    <- t_4e5d3608
    t_db2260b2  12  Prompt assembly: the closed item payload       ready   (parentless)
    t_931a3ec5  13  Muse client: the only model                    ready   (parentless)
    t_7baea299  14  Run executor: batches, validation, write-back  todo    <- t_db2260b2, t_931a3ec5
  Phase 2 — the operations (file-disjoint, so they can run in parallel)
    t_1885916d  20  Prelearn operation                             todo    <- t_4e5d3608, t_e5686522
    t_a370bdb8  21  Learn operation: lesson lines                  todo    <- t_4e5d3608, t_e5686522
    t_c6c447ab  22  Column translate operation                     todo    <- t_7baea299 + phase 1
    t_1198da31  23  Row pass operation                             todo    <- t_7baea299 + phase 1
  Phase 3 — the surface
    t_34b75066  30  Workspace: Start, overlay, status bar          todo    <- t_7baea299
    t_ba38e52d  31  Review/edit actions and the Save path          todo    <- t_4e5d3608, t_e5686522
    t_feeed7ca  32  Row page: adjusted vs newly written            todo    <- t_1198da31, t_34b75066
  Phase 4 — cutover
    t_65bdfcdd  40  Cut over and delete the old pipeline           todo    <- phases 2 and 3 (7 parents)

ACCEPTANCE
  Per card: build SUCCEEDED with zero warnings, only its own files committed, the gate
  command and its result in the completion summary.
  Behavioural checks worth naming, because a passing build proves none of them:
    - the row pass must leave every verified and imported column untouched after a run
      (the write-back is the only guard), and a reply that contradicts a verified sibling
      goes to the paid gate rather than being repaired blindly
    - learn must not move any slot's value or status: its output is the document line and a
      memory gold entry
    - prelearn writes `machine` only, never target, never status
    - a document version bumps only on a REAL change, or a repeated lesson re-marks a column
    - the app keeps running the OLD pipeline until the cutover card lands
  Before cutover there is no automated coverage for the new pipeline, so card 13 owes ONE
  manual end-to-end run on the fixture catalog: Start -> review a slot -> Start again ->
  the columns have nothing to redo and the row pass carries the correction into the other
  languages. The user confirms that visually (no pixel checks).

OPEN DECISIONS (notes section 10) — a worker who meets one asks instead of choosing
  10.2  who may write the global document (recommendation: nobody yet)
  10.6  does the row pass need its own paid gate
  10.8  version bump gating (must bump only on a real change)
  10.10 global document cap: 10 000 as designed, or the builder's 5 000
  10.11 how a CHANGED project rule reaches already machine-translated slots
  10.12 the row pass's cost, and what the run control should say about it
  10.13 Xcode's plural table or current CLDR as the authority (27 locales differ)
  Unanswered by the user, and therefore also askable: does prelearn's request carry
  maxWidth (today only the column translate does)? Does the row pass's per-item field set
  differ from the column pass's?
