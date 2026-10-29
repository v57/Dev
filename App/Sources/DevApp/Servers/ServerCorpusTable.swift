//
//  ServerCorpusTable.swift
//  Dev
//

import SwiftUI

/// The server pane's line table: one line of a server's corpus per row, with its
/// comment and this locale's value, both editable in place.
///
/// It is deliberately the SAME table the Localization pane offers over a
/// catalog — read-only text until clicked, then a focused editor whose commit
/// happens on focus loss and whose Escape cancels — minus the parts a server
/// corpus does not have: a message carries no plural variations and no max-width
/// guideline, so there is no plural editor and no Longest column.
///
/// What it has instead is READING ON DEMAND. The service caps a page at 1000
/// rows and pages it with a cursor, so the table reads one page when the reader
/// reaches the bottom of what is loaded — and the model keeps reading while a
/// search query is unanswered, because the service has no search route of its
/// own.
struct ServerCorpusTable: View {
  let corpus: ServerCorpus
  /// Locales the server already holds, for the picker; the common set follows,
  /// so a deployment with no values at all can still be read.
  let serverLocales: [LocalizeStats.Row]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      controls
      Divider()
      GeometryReader { proxy in
        let widths = ColumnWidths(total: proxy.size.width)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            headerRow(widths)
            Divider()
            ForEach(corpus.visibleRows) { row in
              rowView(row, widths: widths)
              Divider()
            }
            trailing
          }
          .padding(.bottom, 6)
        }
      }
      Divider()
      footer
    }
    .searchable(
      text: Binding(get: { corpus.searchText }, set: { corpus.searchText = $0 }),
      prompt: "Search lines and comments")
  }

  // MARK: - controls

  private var controls: some View {
    HStack(spacing: 10) {
      Picker("Locale", selection: Binding(get: { corpus.locale }, set: { corpus.locale = $0 })) {
        ForEach(localeChoices, id: \.self) { code in
          Text(label(for: code)).tag(code)
        }
      }
      .frame(maxWidth: 240)
      .help("The locale this table shows a value for")

      if corpus.isLoading {
        ProgressView().controlSize(.small)
      }

      Spacer(minLength: 8)

      if corpus.valuesMayHaveMoved {
        Label("a run wrote values while this table was open", systemImage: "arrow.triangle.2.circlepath")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      Button {
        Task { await corpus.reload() }
      } label: {
        Label(corpus.valuesMayHaveMoved ? "Read Again" : "Reload", systemImage: "arrow.clockwise")
      }
      .controlSize(.small)
      .disabled(corpus.isLoading)
      .help("Reads this locale from the first page again — the service has no way to patch a single row back in")
    }
  }

  private var localeChoices: [String] {
    var codes = serverLocales.map(\.locale)
    if !corpus.locale.isEmpty && !codes.contains(corpus.locale) { codes.insert(corpus.locale, at: 0) }
    for code in ServerRunBar.commonLocales where !codes.contains(code) { codes.append(code) }
    return codes
  }

  private func label(for code: String) -> String {
    guard let row = serverLocales.first(where: { $0.locale == code }) else { return code }
    return "\(code) — \(row.total - row.missing)/\(row.total)"
  }

  // MARK: - the table itself

  private func headerRow(_ widths: ColumnWidths) -> some View {
    HStack(spacing: ColumnWidths.spacing) {
      Text("Line").frame(width: widths.line, alignment: .leading)
      Text("Comment").frame(width: widths.comment, alignment: .leading)
      Text(corpus.locale.isEmpty ? "Value" : "Value (\(corpus.locale))")
        .frame(width: widths.value, alignment: .leading)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  private func rowView(_ row: ServerCorpus.Row, widths: ColumnWidths) -> some View {
    HStack(alignment: .top, spacing: ColumnWidths.spacing) {
      LineCell(row: row)
        .frame(width: widths.line, alignment: .leading)
      ServerEditCell(corpus: corpus, row: row, field: .comment)
        .frame(width: widths.comment, alignment: .leading)
      ValueCell(corpus: corpus, row: row)
        .frame(width: widths.value, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
  }

  // MARK: - what the bottom of the table says

  /// The row after the last line: the next page's sentinel, a failure with its
  /// own retry, or the empty state — which is three different empties (not read
  /// yet, nothing on the server, nothing matching).
  @ViewBuilder private var trailing: some View {
    if let error = corpus.error {
      HStack(spacing: 8) {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
        Button("Try Again") { Task { await corpus.retry() } }
          .controlSize(.small)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    } else if corpus.visibleRows.isEmpty {
      emptyState
    } else if corpus.more {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("reading the next page…")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .onAppear { Task { await corpus.loadNextPage() } }
    }
  }

  @ViewBuilder private var emptyState: some View {
    VStack(alignment: .leading, spacing: 4) {
      if corpus.isLoading || corpus.isSearching {
        Text("reading…").font(.caption).foregroundStyle(.secondary)
      } else if !corpus.hasRead {
        Text("Nothing read yet — Check the server, then this table reads its corpus a page at a time.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if !corpus.isEmptyQuery {
        Text("No line matches this search in the \(corpus.rows.count) line\(corpus.rows.count == 1 ? "" : "s") read so far.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if corpus.more {
          Button("Read On") { Task { await corpus.loadNextPage() } }
            .controlSize(.small)
            .help("Reads the next page and looks again — the service has no search route to ask in one call")
        }
      } else {
        Text("This server's corpus holds no sentences for this locale yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text(corpus.footerLine)
          .font(.caption)
          .foregroundStyle(.secondary)
        if corpus.more && !corpus.isLoading {
          Text("scroll for more")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 0)
      }
      if let note = corpus.searchNote {
        Text(note)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      if corpus.valuesMayHaveMoved {
        Text("Press Read Again to see the values the run wrote — the rows below are what the server held before it.")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
  }
}

// MARK: - columns

/// The three column widths, cut from the table's own width once per layout: a
/// GeometryReader per row would measure the same thing a hundred times.
private struct ColumnWidths {
  let line: CGFloat
  let comment: CGFloat
  let value: CGFloat
  static let spacing: CGFloat = 12

  init(total: CGFloat) {
    let usable = max(total - 24 - ColumnWidths.spacing * 2, 560)
    line = usable * 0.38
    comment = usable * 0.27
    value = usable * 0.35
  }
}

// MARK: - cells

/// The source side of a line: the sentence the corpus is keyed by, with the
/// namespace it was registered under. Never editable — the sentence IS the
/// message's identity (its hash), and the service has no route that renames one.
private struct LineCell: View {
  let row: ServerCorpus.Row

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(row.source)
        .lineLimit(4)
        .help(row.source)
        .textSelection(.enabled)
      Text(row.namespace)
        .font(.caption2)
        .monospaced()
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// This locale's value, with who wrote it: the badges say where the value comes
/// from and whether it is behind the source, and the cell itself is editable —
/// a person's edit is written as `gold`.
private struct ValueCell: View {
  let corpus: ServerCorpus
  let row: ServerCorpus.Row

  var body: some View {
    HStack(alignment: .top, spacing: 5) {
      OriginBadge(row: row)
      ServerEditCell(corpus: corpus, row: row, field: .value)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// What the server says about a value: a human's decision, a model's output,
/// something imported, and the stale stamp a changed source or comment leaves.
private struct OriginBadge: View {
  let row: ServerCorpus.Row

  var body: some View {
    HStack(spacing: 3) {
      switch row.origin {
      case "gold":
        Image(systemName: "checkmark.seal.fill")
          .foregroundStyle(.green)
          .help("gold — a person decided this value")
      case "machine":
        Image(systemName: "wand.and.stars")
          .foregroundStyle(.secondary)
          .help("machine — a model wrote it")
      case "imported":
        Image(systemName: "square.and.arrow.down")
          .foregroundStyle(.tertiary)
          .help("imported — it came from somewhere else and has nobody behind it")
      default:
        EmptyView()
      }
      if row.stale {
        Image(systemName: "clock.badge.exclamationmark")
          .foregroundStyle(.orange)
          .help("stale — the source or the comment changed after this value was written")
      }
    }
    .font(.system(size: 10))
    .frame(width: 14, alignment: .leading)
    .padding(.top, 2)
  }
}

/// One editable cell: the comment, or the locale's value.
///
/// The interaction is the Localization pane's language cell — text until
/// clicked, then a focused `TextEditor`, commit on focus loss, Escape cancels —
/// but the commit is an HTTP write, so the cell says it is writing, keeps the
/// draft on screen while it is, and shows whatever the server answered under it.
private struct ServerEditCell: View {
  let corpus: ServerCorpus
  let row: ServerCorpus.Row
  let field: ServerCorpus.Field

  @State private var draft = ""
  @State private var isEditing = false
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Group {
        if isEditing {
          TextEditor(text: $draft)
            .font(.body)
            .focused($focused)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 22, maxHeight: 160)
            .background(tint)
            .onAppear { focused = true }
            .onExitCommand { cancel() }
            .onChange(of: focused) { _, isFocused in
              if !isFocused { commit() }
            }
        } else {
          Group {
            if shown.isEmpty {
              Text(placeholder)
                .foregroundStyle(.tertiary)
            } else {
              Text(shown)
                .lineLimit(4)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(minHeight: 22, alignment: .topLeading)
          .help(isEditedLocally ? "\(shown)\n\nwritten from this pane" : shown)
          .background(tint)
          .onTapGesture {
            draft = text
            corpus.clearNote(for: row.source, field)
            isEditing = true
          }
        }
      }
      .font(.body)

      if let note = corpus.note(for: row.source, field) {
        Text(note)
          .font(.caption2)
          .foregroundStyle(isFailure(note) ? .orange : .secondary)
          .lineLimit(2)
      }
    }
    .onChange(of: text) { _, newText in
      // Adopt what the server holds (a reload, or the write landing) unless the
      // reader is mid-edit.
      if !isEditing && !focused {
        draft = newText
      }
    }
  }

  // MARK: - text

  private var text: String {
    field == .value ? row.value : row.comment
  }

  private var isEditedLocally: Bool {
    field == .value ? row.valueEditedLocally : row.commentEditedLocally
  }

  /// While a write is out the draft is what the reader typed — the old value is
  /// not put back under the cursor.
  private var shown: String {
    corpus.isWriting(row.source, field) ? draft : text
  }

  private var placeholder: String {
    field == .value ? "missing — click to add" : "add a comment — click to edit"
  }

  private var tint: Color {
    (isEditedLocally || corpus.isWriting(row.source, field))
      ? Color.accentColor.opacity(0.08)
      : Color.clear
  }

  private func isFailure(_ note: String) -> Bool {
    !(note.hasPrefix("written") || note.hasPrefix("comment written"))
  }

  // MARK: - commit

  private func commit() {
    let typed = draft
    isEditing = false
    // A comment is prose: the newlines a TextEditor keeps are not part of it. A
    // value is not trimmed — a trailing space can be the point of one.
    let candidate = field == .comment ? typed.trimmingCharacters(in: .whitespacesAndNewlines) : typed
    guard candidate != text else { return }
    Task { await corpus.write(candidate, for: row, field: field) }
  }

  private func cancel() {
    draft = text
    isEditing = false
  }
}
