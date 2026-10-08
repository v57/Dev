//
//  ServerRun.swift
//  Dev
//

import Foundation
import Observation

/// One run of the translate plan over a SERVER's corpus.
///
/// The plan is the app's own, unchanged (`Translation.Run.Mode`,
/// `Localization/Redesign/Runner.swift`): Translate runs learn -> vertical ->
/// horizontal, Skip Learning runs vertical -> horizontal. What differs from a
/// catalog run is only where the ROWS come from and where the result goes: this
/// knows nothing about a project, a catalog or SwiftData — its rows are the
/// server's own worklist, read a page at a time, and every accepted value is
/// pushed the moment its batch closes, so cancelling keeps what landed.
///
/// The node is only ever spoken to over HTTP (`LocalizeClient`); no node code is
/// involved, and the node's own translate engine is not used.
///
/// Learning, in this pane, means what it means in the catalog run: fold what is
/// already VERIFIED into the run before it translates. On a server the verified
/// material is its `gold` values — a human decided those — so they become the
/// language block the prompt carries, per-namespace samples ride along as
/// neighbours, and each sentence's own `comment` travels with it.
@MainActor
@Observable
final class ServerRun {
  /// Which way in was used — the two buttons differ by exactly this.
  enum Plan: String, Hashable {
    /// learn -> vertical -> horizontal.
    case full
    /// vertical -> horizontal: the same run without the learning step.
    case skipLearning

    var title: String {
      switch self {
      case .full: return "Translate"
      case .skipLearning: return "Skip learning"
      }
    }

    var hasLearning: Bool { self == .full }
  }

  enum Phase: Equatable {
    case idle
    /// Asked for, not yet through the first guard. It is an ACTIVE phase: the
    /// moment a run is requested the pane must offer Stop and must not start a
    /// second one, whatever the task has managed to do yet.
    case starting
    case learning
    case vertical
    case horizontal
    case finished
    case cancelled
    case failed(String)

    var isActive: Bool {
      switch self {
      case .starting, .learning, .vertical, .horizontal: return true
      default: return false
      }
    }

    var title: String {
      switch self {
      case .idle: return "idle"
      case .starting: return "starting…"
      case .learning: return "learning from verified values"
      case .vertical: return "translating"
      case .horizontal: return "the row pass"
      case .finished: return "finished"
      case .cancelled: return "cancelled"
      case .failed: return "failed"
      }
    }
  }

  // MARK: - what the pane reads

  private(set) var phase: Phase = .idle
  private(set) var plan: Plan = .full
  private(set) var locale: String?
  private(set) var scope: String?

  /// Lines the reader can act on: the model answering, what learning found, the
  /// sentences the model refused, the rows the row pass could not fix.
  private(set) var notes: [String] = []

  private(set) var batches = 0
  private(set) var rowsRead = 0
  private(set) var rowsWritten = 0
  private(set) var rowsSkipped = 0
  private(set) var rowsUntranslatable = 0
  private(set) var rowsRepaired = 0
  private(set) var rowsStillInvalid = 0
  private(set) var sourceCharacters = 0
  private(set) var model = ""
  private(set) var learnedSamples = 0

  var isRunning: Bool { phase.isActive }

  /// One line for the pane's status area.
  var summaryLine: String {
    guard isRunning || phase == .finished || phase == .cancelled || isFailed else { return "" }
    var parts: [String] = [phase.title]
    if rowsRead > 0 { parts.append("\(rowsRead) read") }
    if rowsWritten > 0 { parts.append("\(rowsWritten) written") }
    if rowsSkipped > 0 { parts.append("\(rowsSkipped) refused by the server") }
    if rowsUntranslatable > 0 { parts.append("\(rowsUntranslatable) not translatable") }
    if phase == .horizontal || phase == .finished || phase == .cancelled {
      if rowsRepaired > 0 { parts.append("\(rowsRepaired) repaired") }
      if rowsStillInvalid > 0 { parts.append("\(rowsStillInvalid) still invalid") }
    }
    if !model.isEmpty { parts.append(model) }
    if sourceCharacters > 0 { parts.append("\(sourceCharacters) chars") }
    if let locale { parts.append("-> \(locale)") }
    return parts.joined(separator: " · ")
  }

  private var isFailed: Bool {
    if case .failed = phase { return true }
    return false
  }

  private var task: Task<Void, Never>?

  // MARK: - start / cancel

  /// Starts a run. The server's own connection supplies endpoint and key; a
  /// missing key, an unusable endpoint or an unconfigured provider is reported
  /// as a failure of the run, never as a spinner.
  func start(connection: ServerConnection, locale: String, scope: String?, plan: Plan) {
    guard let base = connection.base else {
      reset()
      phase = .failed("the endpoint is not a usable http(s) URL")
      return
    }
    guard let key = connection.resolvedKey else {
      reset()
      phase = .failed("no key: add one to this server, or set \(ServerKeychain.sharedKeyName)")
      return
    }
    start(base: base, key: key, locale: locale, scope: scope, plan: plan)
  }

  /// The same start without the SwiftData row behind it: the run only ever needs
  /// an endpoint and a key, which is also what a probe can hand it.
  func start(base: URL, key: String, locale: String, scope: String?, plan: Plan) {
    guard !isRunning else { return }
    reset()
    self.plan = plan
    self.locale = locale
    self.scope = scope
    phase = .starting
    let client = LocalizeClient(base: base, key: key)
    let router = TranslationRouter.shared
    task = Task { [weak self] in
      await self?.run(client: client, router: router)
    }
  }

  /// Stops between requests: the batch in flight is awaited (a request cannot be
  /// un-sent), everything it produced is pushed, and then the run ends.
  func cancel() {
    task?.cancel()
  }

  private func reset() {
    phase = .idle
    notes = []
    batches = 0
    rowsRead = 0
    rowsWritten = 0
    rowsSkipped = 0
    rowsUntranslatable = 0
    rowsRepaired = 0
    rowsStillInvalid = 0
    sourceCharacters = 0
    model = ""
    learnedSamples = 0
  }

  // MARK: - the run

  private func run(client: LocalizeClient, router: TranslationRouter) async {
    guard let locale, !locale.isEmpty else {
      phase = .failed("pick a target locale")
      return
    }
    if let scope, scope.isEmpty == false {
      notes.append("scope: \(scope)")
    }
    guard await router.isEligible(from: Self.sourceLanguage, to: locale) else {
      phase = .failed("no model key configured for the router (provider chain is empty)")
      return
    }

    // learn (the step Skip Learning leaves out)
    var learned = Learned()
    if plan.hasLearning {
      phase = .learning
      learned = await learn(client: client, locale: locale)
      if Task.isCancelled {
        phase = .cancelled
        return
      }
    } else {
      notes.append("learning skipped: no verified values were folded into this run")
    }

    // vertical
    phase = .vertical
    var writtenSources: [String] = []
    do {
      for try await batch in client.worklistBatches(
        locale: locale, filters: ["empty", "stale"], limit: Self.pageSize) {
        if Task.isCancelled { break }
        batches += 1
        let scoped = batch.filter { scope == nil || $0.namespace == scope }
        let translatable = scoped.filter { Self.isTranslatable($0.source) }
        rowsUntranslatable += scoped.count - translatable.count
        rowsRead += scoped.count
        guard !translatable.isEmpty else { continue }

        for chunk in Self.chunks(of: translatable, budget: TranslationRouter.translateSourceBudget) {
          if Task.isCancelled { break }
          let items = chunk.enumerated().map { index, item in
            ContextPromptBuilder.BatchItem(
              id: index,
              sourceText: item.source,
              context: learned.context(comment: item.comment, namespace: item.namespace))
          }
          sourceCharacters += chunk.reduce(0) { $0 + $1.source.count }

          let outcome = await router.translateBatch(items, from: Self.sourceLanguage, to: locale)
          if !outcome.model.isEmpty { model = outcome.model }
          if outcome.truncated {
            notes.append("a batch was cut off — \(outcome.failedIDs.count) sentence(s) will be re-asked by the row pass")
          }
          for note in outcome.notes.prefix(3) { notes.append("model: \(note)") }

          var entries: [LocalizeValueEntry] = []
          for (id, value) in outcome.values {
            guard let item = chunk[safe: id] else { continue }
            entries.append(
              LocalizeValueEntry(
                source: item.source, locale: locale, value: value, origin: "machine",
                model: outcome.model.isEmpty ? nil : outcome.model))
          }
          if !entries.isEmpty {
            let result = try await client.writeValues(entries)
            rowsWritten += result.written
            rowsSkipped += result.skipped
            writtenSources.append(contentsOf: entries.map(\.source))
            if let reason = result.reason, result.skipped > 0 {
              notes.append("the server refused \(result.skipped) value(s): \(reason)")
            }
          }
          for id in outcome.failedIDs {
            guard let item = chunk[safe: id] else { continue }
            notes.append("no accepted value for: \(item.source.prefix(60))")
          }
        }
      }
    } catch is CancellationError {
      phase = .cancelled
      return
    } catch {
      phase = .failed(describe(error))
      return
    }

    if Task.isCancelled {
      phase = .cancelled
      return
    }

    // horizontal (the row pass)
    phase = .horizontal
    await rowPass(client: client, router: router, locale: locale, sources: writtenSources)

    phase = Task.isCancelled ? .cancelled : .finished
  }

  // MARK: - learn

  /// One run's worth of verified material, folded into every prompt it sends.
  private struct Learned {
    /// The language block: what a human has already approved for this locale.
    var languageContext: String?
    /// Verified values by namespace, for the per-item neighbours.
    var byNamespace: [String: [(source: String, value: String)]] = [:]
    var count = 0

    /// The context one sentence travels with: its own developer comment, the
    /// learned language block, and up to three verified neighbours from its
    /// namespace.
    func context(comment: String?, namespace: String) -> TranslationContext {
      var context = TranslationContext()
      context.comment = comment
      context.languageContext = languageContext
      context.neighbors = (byNamespace[namespace] ?? []).prefix(3).map { "\($0.source) -> \($0.value)" }
      return context
    }
  }

  /// Reads the server's own verified (`gold`) values for the locale: the only
  /// material that counts as learned, because a human decided it. Machine values
  /// are NOT folded in — they are what this run is replacing.
  private func learn(client: LocalizeClient, locale: String) async -> Learned {
    var learned = Learned()
    var cursor: String?
    var samples: [(source: String, value: String, namespace: String)] = []
    do {
      repeat {
        var body: [String: Any] = ["locale": locale, "limit": Self.pageSize]
        if let cursor { body["cursor"] = cursor }
        let page = try await client.post("localize/messages", body, as: LocalizeInventory.self)
        for item in page.items {
          guard let state = item.locales[locale], state.origin == "gold", !state.value.isEmpty else { continue }
          samples.append((item.source, state.value, item.namespace))
        }
        cursor = page.more ? page.cursor : nil
      } while cursor != nil && samples.count < Self.learnSampleCap
    } catch {
      // Learning is an improvement, not a precondition: a locale with nothing
      // verified yet (or an inventory the server refuses) runs without it, and
      // says so rather than failing.
      notes.append("learning could not read the inventory: \(describe(error))")
      return learned
    }

    learned.count = samples.count
    learnedSamples = samples.count
    guard !samples.isEmpty else {
      notes.append("nothing verified for \(locale) yet — the run carries comments only")
      return learned
    }

    let listed = samples.prefix(Self.learnSampleCap)
      .map { "- \($0.source.prefix(120)) => \($0.value.prefix(120))" }
      .joined(separator: "\n")
    learned.languageContext =
      "Values a human already verified in \(locale) for this app. Follow their terminology and register:\n\(listed)"
    for sample in samples {
      learned.byNamespace[sample.namespace, default: []].append((sample.source, sample.value))
    }
    notes.append("learned \(samples.count) verified value(s) for \(locale)")
    return learned
  }

  // MARK: - the row pass

  /// The horizontal step, on a server: rows this run wrote are checked against
  /// the source and against their OWN other languages, and the ones whose output
  /// is invalid — or that disagree with a sibling language — are re-asked once
  /// with those siblings in the prompt. What still fails is reported, never
  /// silently accepted.
  private func rowPass(
    client: LocalizeClient, router: TranslationRouter, locale: String, sources: [String]
  ) async {
    let wanted = Set(sources)
    guard !wanted.isEmpty else {
      notes.append("the row pass had no new rows to check")
      return
    }

    // The affected rows' other languages, on demand: pages are walked until
    // every affected source is seen (or the inventory ends).
    var rows: [String: LocalizeInventory.Item] = [:]
    var cursor: String?
    do {
      repeat {
        var body: [String: Any] = ["limit": Self.pageSize]
        if let cursor { body["cursor"] = cursor }
        let page = try await client.post("localize/messages", body, as: LocalizeInventory.self)
        for item in page.items where wanted.contains(item.source) { rows[item.source] = item }
        if rows.count >= wanted.count { break }
        cursor = page.more ? page.cursor : nil
      } while cursor != nil
    } catch {
      notes.append("the row pass could not read the inventory: \(describe(error))")
      return
    }

    for source in sources {
      if Task.isCancelled { return }
      guard let row = rows[source], let mine = row.locales[locale]?.value else { continue }
      let issues = TranslationValidator.validate(source: source, target: mine)
      let siblings = row.locales
        .filter { $0.key != locale }
        .mapValues(\.value)
      let disagrees = siblings.values.contains {
        TranslationValidator.placeholders($0).sorted() != TranslationValidator.placeholders(mine).sorted()
      }
      guard !issues.isEmpty || disagrees else { continue }

      var context = TranslationContext()
      context.comment = row.comment
      context.neighbors = siblings.prefix(4).map { "\($0.key): \($0.value)" }
      let repaired = try? await router.translate(source, from: Self.sourceLanguage, to: locale, context: context)
      guard let repaired, !repaired.isEmpty,
            TranslationValidator.validate(source: source, target: repaired).isEmpty else {
        rowsStillInvalid += 1
        notes.append("row pass could not fix: \(source.prefix(60))")
        continue
      }
      do {
        let result = try await client.writeValues([
          LocalizeValueEntry(
            source: source, locale: locale, value: repaired, origin: "machine",
            model: model.isEmpty ? nil : model)
        ])
        if result.written > 0 {
          rowsRepaired += 1
          rowsWritten += result.written
        } else {
          rowsStillInvalid += 1
        }
      } catch {
        rowsStillInvalid += 1
        notes.append("row pass could not write: \(describe(error))")
      }
    }
    if rowsStillInvalid == 0 && rowsRepaired == 0 {
      notes.append("the row pass found nothing to adapt")
    }
  }

  // MARK: - helpers

  private static let sourceLanguage = "en"
  /// One page of the worklist/inventory per request. A batch that reaches the
  /// model is cut further by source characters, so this is only the read size.
  private static let pageSize = 200
  /// How many verified values may ride in the prompt's language block.
  private static let learnSampleCap = 120

  /// The engine's own rule (node `mods/localize/lib/identity.ts`): a source with
  /// no letter or digit outside its placeholders is never sent to a model. It is
  /// still "missing" on the server, so a run must skip it rather than spend a
  /// call on `$description`.
  static func isTranslatable(_ source: String) -> Bool {
    guard !source.isEmpty else { return false }
    var text = source
    for token in TranslationValidator.placeholders(source) {
      text = text.replacingOccurrences(of: token, with: " ")
    }
    // `$name` / `${name}` are the node's own placeholder spelling and the
    // validator above does not know them, so they are removed here too.
    text = text.replacingOccurrences(
      of: #"\$\{?[A-Za-z_][A-Za-z0-9_.]*\}?"#, with: " ", options: .regularExpression)
    return text.contains { $0.isLetter || $0.isNumber }
  }

  /// Cuts a page into batches of at most `budget` source characters (a single
  /// oversized source is a batch of one rather than a split string).
  static func chunks(
    of items: [LocalizeWorklist.Item], budget: Int
  ) -> [[LocalizeWorklist.Item]] {
    var out: [[LocalizeWorklist.Item]] = []
    var current: [LocalizeWorklist.Item] = []
    var size = 0
    for item in items {
      let length = item.source.count
      if !current.isEmpty && size + length > budget {
        out.append(current)
        current = []
        size = 0
      }
      current.append(item)
      size += length
    }
    if !current.isEmpty { out.append(current) }
    return out
  }

  private func describe(_ error: Error) -> String {
    (error as? LocalizeClient.Error)?.description ?? "\(error)"
  }
}

extension Array {
  /// Bounds-checked lookup: a model reply can name an id the batch did not have.
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
