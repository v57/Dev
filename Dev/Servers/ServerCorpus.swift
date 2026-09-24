//
//  ServerCorpus.swift
//  Dev
//

import Foundation

/// The server pane's line table: ONE locale of a server's corpus, one page at a
/// time.
///
/// The localize service caps every list at 1000 rows and hands back a cursor, so
/// this never holds the corpus: the next page is read when the reader reaches
/// the bottom of the table. The search pulls pages too — while a query is
/// unanswered the model keeps reading (a bounded sweep) instead of offering a
/// filter that quietly only sees the lines somebody happened to scroll past:
/// the service has no search route of its own.
///
/// Both edits are per row and both are the service's own doors: a value is
/// written as `gold` (a person typed it — a run's own values are `machine`), and
/// a comment through `localize/comments`, which bumps the message's revision and
/// stamps that message's machine values `stale`. Every outcome — written or
/// refused — lands on the line it belongs to instead of in a console.
@MainActor @Observable
final class ServerCorpus {
  /// One line of the corpus: a message and this locale's value for it.
  struct Row: Identifiable {
    let source: String
    var comment: String
    let namespace: String
    /// This locale's value; "" means the message has none here.
    var value: String
    /// `gold` / `machine` / `imported`; "" when there is no value at all.
    var origin: String
    var stale: Bool
    /// Typed in this session — the cell is tinted until the page is read again.
    var valueEditedLocally = false
    var commentEditedLocally = false
    /// Folded haystack for the search, built once when the line materializes
    /// (and rebuilt when its comment is written).
    var searchBlob: String

    var id: String { source }

    /// A human's own decision, as the server names it.
    var isGold: Bool { origin == "gold" }
    var hasValue: Bool { !value.isEmpty }

    init(source: String, comment: String, namespace: String) {
      self.source = source
      self.comment = comment
      self.namespace = namespace
      self.value = ""
      self.origin = ""
      self.stale = false
      self.searchBlob = Self.blob(source: source, comment: comment, namespace: namespace)
    }

    static func blob(source: String, comment: String, namespace: String) -> String {
      folded("\(source)\n\(comment)\n\(namespace)")
    }
  }

  /// Which half of a row is being written, or last reported on.
  enum Field: String {
    case comment
    case value

    var title: String { self == .value ? "value" : "comment" }
  }

  // MARK: - what the table holds

  /// The lines read so far, in the server's own order (by message hash).
  private(set) var rows: [Row] = []
  /// The server says more pages exist behind the cursor it handed back.
  private(set) var more = false
  /// A page is out right now.
  private(set) var isLoading = false
  /// The last page's failure. Held rather than thrown so the pages that landed
  /// stay on screen and the cursor waits where it was.
  private(set) var error: String?
  /// How many pages have been read (the footer says so, so a reader can tell a
  /// short corpus from a partly-read one).
  private(set) var pagesRead = 0
  /// Per row: what the last write answered ("written", why it was refused).
  private(set) var notes: [String: String] = [:]
  /// Writes in flight, keyed the same way as `notes`.
  private(set) var writing: Set<String> = []
  /// A run finished while this table was open, so the values these rows hold are
  /// not what the server has now. Only the reader can decide to drop their place
  /// in the corpus, so the table says so and offers the read again.
  private(set) var valuesMayHaveMoved = false
  /// Pages this query has pulled, and whether it is still pulling.
  private(set) var searchPages = 0
  private(set) var isSearching = false
  /// The first page has been asked for (so an empty table can say which empty
  /// it is: not read yet, or genuinely empty).
  private(set) var hasRead = false

  // MARK: - knobs

  /// One page's worth of lines. The service caps a page at 1000; 200 keeps a
  /// page small enough to read while the next one is already coming. A `var`
  /// because a probe forces a small page to exercise the cursor walk.
  static var pageSize = 200
  /// How many pages ONE query may pull before it reports what it has. Without a
  /// cap, a query nothing matches would read the whole corpus on a keystroke.
  static let sweepPageBudget = 25
  /// How many matches a query wants before it stops sweeping.
  static let sweepMatchTarget = 25
  /// The pause between the last keystroke and the sweep it starts.
  static let sweepDebounce = Duration.milliseconds(350)

  // MARK: - state

  private var client: LocalizeClient?
  private var cursor: String?
  private var sweep: Task<Void, Never>?

  private var _locale: String
  /// The locale the table shows. Changing it is a different slice of the
  /// corpus, not a filter over the one on screen, so it reads from the start.
  var locale: String {
    get { _locale }
    set {
      guard newValue != _locale else { return }
      _locale = newValue
      reset()
      Task { await readPage() }
    }
  }

  private var _searchText = ""
  /// The search field. The service has no search route: this filters the lines
  /// already read, and `sweep()` keeps reading while the query is unanswered.
  var searchText: String {
    get { _searchText }
    set {
      guard newValue != _searchText else { return }
      _searchText = newValue
      searchChanged()
    }
  }

  init(locale: String = "") {
    self._locale = locale
  }

  // MARK: - reading

  /// Points the table at a server and reads the first page. The pane calls this
  /// after a check, so the table only ever reads a server that answered.
  func start(client: LocalizeClient, locale wanted: String) async {
    let isSameServer = self.client?.base == client.base
    self.client = client
    if !isSameServer || wanted != _locale {
      _locale = wanted
      reset()
    }
    guard rows.isEmpty, error == nil else { return }
    await readPage()
  }

  /// Reads the first page again, dropping what is held (the reader asked for it:
  /// a locale change, a run that moved values, the Reload button).
  func reload() async {
    reset()
    await readPage()
  }

  /// The next page, if the server says there is one and none is out yet. The
  /// table's bottom sentinel calls this.
  func loadNextPage() async {
    guard more, !isLoading else { return }
    await readPage()
  }

  /// Retries the page that failed. `more` was left alone by the failure, so only
  /// an explicit retry (or a reload) starts reading again.
  func retry() async {
    guard error != nil else { return }
    error = nil
    more = true
    await readPage()
  }

  /// A run finished: what these rows hold is not what the server has now.
  func noteRunFinished() {
    valuesMayHaveMoved = true
  }

  private func reset() {
    sweep?.cancel()
    sweep = nil
    rows = []
    notes = [:]
    writing = []
    cursor = nil
    more = true
    pagesRead = 0
    searchPages = 0
    isSearching = false
    error = nil
    valuesMayHaveMoved = false
    hasRead = false
  }

  private func readPage() async {
    guard !isLoading, let client else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let page = try await client.inventory(locale: _locale, limit: Self.pageSize, cursor: cursor)
      var held = Set(rows.map(\.source))
      for item in page.items where held.insert(item.source).inserted {
        rows.append(row(from: item))
      }
      // A page that promises more but hands back no cursor would spin; the
      // cursor is also what makes the next call a page rather than a repeat.
      cursor = page.cursor
      more = page.more && page.cursor != nil
      pagesRead += 1
      hasRead = true
      error = nil
    } catch let thrown {
      // Held rather than thrown: the pages that landed stay on screen, and the
      // cursor waits where it was so the next attempt reads the same page.
      error = message(for: thrown)
    }
  }

  private func row(from item: LocalizeInventory.Item) -> Row {
    let state = item.locales[_locale]
    var row = Row(source: item.source, comment: item.comment ?? "", namespace: item.namespace)
    row.value = state?.value ?? ""
    row.origin = state?.origin ?? ""
    row.stale = state?.stale ?? false
    return row
  }

  // MARK: - the search

  private func searchChanged() {
    sweep?.cancel()
    sweep = nil
    searchPages = 0
    isSearching = false
    guard !query.isEmpty, more else { return }
    sweep = Task { [weak self] in
      // One sweep per pause in typing, not one per keystroke.
      try? await Task.sleep(for: ServerCorpus.sweepDebounce)
      guard !Task.isCancelled else { return }
      await self?.runSweep()
    }
  }

  private func runSweep() async {
    let wanted = query
    guard !wanted.isEmpty else { return }
    isSearching = true
    defer { isSearching = false }
    while !Task.isCancelled, more, searchPages < Self.sweepPageBudget,
          visibleRows.count < Self.sweepMatchTarget, query == wanted, error == nil {
      await readPage()
      searchPages += 1
    }
  }

  private var query: String { folded(_searchText) }

  /// The lines the table shows: all of them, or the ones the query matches.
  var visibleRows: [Row] {
    let wanted = query
    guard !wanted.isEmpty else { return rows }
    return rows.filter { $0.searchBlob.contains(wanted) }
  }

  var isEmptyQuery: Bool { query.isEmpty }

  /// What the search field's own line says. It is a LOCAL filter over the pages
  /// that landed, so it must never read as a server-side search.
  var searchNote: String? {
    guard !isEmptyQuery else { return nil }
    if let error { return "search stopped: \(error)" }
    if isSearching { return "reading page after page — \(rows.count) lines in hand so far" }
    if !more {
      return visibleRows.isEmpty
        ? "no match in this server's \(rows.count) lines"
        : "\(visibleRows.count) matching line\(visibleRows.count == 1 ? "" : "s") in the whole corpus (\(rows.count) lines)"
    }
    if visibleRows.isEmpty {
      return "no match in the \(rows.count) lines read so far, and the server has more"
    }
    return "\(visibleRows.count) matching line\(visibleRows.count == 1 ? "" : "s") in the \(rows.count) lines read so far — the server has more, keep typing to read on"
  }

  /// The footer's own line: how much of the corpus is in hand.
  var footerLine: String {
    let lines = "\(rows.count) line\(rows.count == 1 ? "" : "s")"
    var parts = [isEmptyQuery ? lines : "\(visibleRows.count) of \(lines) shown"]
    if pagesRead > 0 { parts.append("\(pagesRead) page\(pagesRead == 1 ? "" : "s")") }
    parts.append(more ? "more on the server" : "the whole corpus is read")
    return parts.joined(separator: " · ")
  }

  // MARK: - writing

  /// Writes one line's value for the locale the table shows. A person typed it,
  /// so it goes in as `gold` — and the server's refusal (a machine value never
  /// overwrites a gold one) is reported on the row rather than swallowed.
  func setValue(_ text: String, for row: Row) async {
    let key = noteKey(row.source, .value)
    guard !writing.contains(key) else { return }
    writing.insert(key)
    defer { writing.remove(key) }
    guard let client else {
      notes[key] = "no server connection"
      return
    }
    do {
      let result = try await client.writeValues([
        LocalizeValueEntry(source: row.source, locale: _locale, value: text, origin: "gold")
      ])
      guard result.written > 0 else {
        notes[key] = "the server refused it: \(result.reason ?? "wrote nothing")"
        return
      }
      rewrite(row.source) { held in
        held.value = text
        held.origin = "gold"
        held.stale = false
        held.valueEditedLocally = true
      }
      // `stale` in the reply counts the values that WERE stale and are now
      // fresh (the store's own `stale` is the count it cleared), so it is worth
      // saying: the reader's edit is what cleared the marker.
      notes[key] = result.stale.map { $0 > 0 ? "written as gold — the stale marker is cleared" : "written as gold" }
        ?? "written as gold"
    } catch {
      notes[key] = message(for: error)
    }
  }

  /// Writes one line's comment. A changed comment bumps the message's revision
  /// and stamps that message's MACHINE values `stale` (the reply says how many),
  /// so the row shows the marker at once instead of lying until the page is read
  /// again. A gold value is never stamped.
  func setComment(_ text: String, for row: Row) async {
    let key = noteKey(row.source, .comment)
    guard !writing.contains(key) else { return }
    writing.insert(key)
    defer { writing.remove(key) }
    guard let client else {
      notes[key] = "no server connection"
      return
    }
    do {
      let result = try await client.writeComments([(source: row.source, comment: text)])
      rewrite(row.source) { held in
        held.comment = text
        held.commentEditedLocally = true
        held.searchBlob = Row.blob(source: held.source, comment: text, namespace: held.namespace)
        if result.stale > 0 && held.origin == "machine" { held.stale = true }
      }
      notes[key] = result.stale > 0
        ? "comment written — \(result.stale) machine value\(result.stale == 1 ? "" : "s") marked stale"
        : "comment written"
    } catch {
      notes[key] = message(for: error)
    }
  }

  /// The commit the table's editable cell makes: the right door per field.
  func write(_ text: String, for row: Row, field: Field) async {
    switch field {
    case .value: await setValue(text, for: row)
    case .comment: await setComment(text, for: row)
    }
  }

  // MARK: - row lookups

  func isWriting(_ source: String, _ field: Field) -> Bool {
    writing.contains(noteKey(source, field))
  }

  func note(for source: String, _ field: Field) -> String? {
    notes[noteKey(source, field)]
  }

  func clearNote(for source: String, _ field: Field) {
    notes[noteKey(source, field)] = nil
  }

  private func noteKey(_ source: String, _ field: Field) -> String {
    "\(source)|\(field.rawValue)"
  }

  /// Replaces one row in place (the array is `private(set)`, so writes go
  /// through here and the views see one mutation).
  private func rewrite(_ source: String, _ change: (inout Row) -> Void) {
    guard let index = rows.firstIndex(where: { $0.source == source }) else { return }
    change(&rows[index])
  }

  private func message(for error: Swift.Error) -> String {
    (error as? LocalizeClient.Error)?.description ?? "\(error)"
  }
}
