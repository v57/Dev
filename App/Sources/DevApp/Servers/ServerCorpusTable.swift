//
//  ServerCorpusTable.swift
//  Dev
//

import ComponentKit
import SwiftUI

/// The server pane's line table: one line of a server's corpus per row, with its
/// comment and this locale's value, both editable in place.
///
/// It is the kit's grid, as the Localization pane's strings are — Return or a
/// double click edits a cell, Escape cancels — minus the parts a server corpus
/// does not have: a message carries no plural variations and no max-width
/// guideline, so there is no plural editor and no Longest column. A write is an
/// HTTP request: the row carries the edited mark while it is out, and the cell
/// shows what the server answered under it.
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
  @State private var selection: Set<ServerCorpus.Row.ID> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      controls
      if corpus.visibleRows.isEmpty && corpus.error == nil {
        emptyState
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        KitGrid(
          corpus.visibleRows, columns: columns, selection: $selection,
          rowState: { corpus.isWriting($0.source, .value) || corpus.isWriting($0.source, .comment) ? .edited : nil },
          rowHeight: .automatic
        ) {
          trailing
        }
      }
      footer
    }
  }

  // MARK: - controls

  private var controls: some View {
    HStack(spacing: 10) {
      KitPicker(
        "Locale", selection: Binding(get: { corpus.locale }, set: { corpus.locale = $0 }),
        segments: localeChoices.map { KitSegment(label(for: $0), value: $0) })
        .frame(maxWidth: 240)
        .kitHelp("Locale", meta: "The locale this table shows a value for")

      KitSearchField(
        text: Binding(get: { corpus.searchText }, set: { corpus.searchText = $0 }),
        prompt: "Search lines and comments", status: corpus.isSearching ? .working : .idle)
        .frame(maxWidth: 320)

      Spacer(minLength: 8)

      if corpus.valuesMayHaveMoved {
        Label("a run wrote values while this table was open", systemImage: "arrow.triangle.2.circlepath")
          .kitFont(.caption)
          .foregroundStyle(Hue.orange.text)
      }

      Button(corpus.valuesMayHaveMoved ? "Read Again" : "Reload", systemImage: "arrow.clockwise") {
        Task { await corpus.reload() }
      }
      .buttonStyle(.kit)
      .controlSize(.small)
      .disabled(corpus.isLoading)
      .kitHelp(
        corpus.valuesMayHaveMoved ? "Read Again" : "Reload", status: corpus.isLoading ? .working : .idle)
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

  private var columns: [KitGridColumn<ServerCorpus.Row>] {
    [
      KitGridColumn("Line", width: 320) { row in LineCell(row: row) },
      KitGridColumn(
        "Comment", width: 240, value: { $0.comment }, edit: { write($1, row: $0, field: .comment) }
      ) { row in
        NotedCell(corpus: corpus, row: row, field: .comment)
      },
      KitGridColumn(
        corpus.locale.isEmpty ? "Value" : "Value (\(corpus.locale))", id: "value", width: 300,
        value: { $0.value }, edit: { write($1, row: $0, field: .value) }
      ) { row in
        HStack(alignment: .top, spacing: 5) {
          OriginBadge(row: row)
          NotedCell(corpus: corpus, row: row, field: .value)
        }
      },
    ]
  }

  /// A comment is prose: the newlines a field keeps are not part of it. A value is not trimmed — a trailing space
  /// can be the point of one.
  private func write(_ typed: String, row: ServerCorpus.Row, field: ServerCorpus.Field) {
    let candidate = field == .comment ? typed.trimmingCharacters(in: .whitespacesAndNewlines) : typed
    guard candidate != (field == .value ? row.value : row.comment) else { return }
    corpus.clearNote(for: row.source, field)
    Task { await corpus.write(candidate, for: row, field: field) }
  }

  // MARK: - what the bottom of the table says

  /// The row after the last line: the next page's sentinel, or a failure with its own retry.
  @ViewBuilder private var trailing: some View {
    if let error = corpus.error {
      HStack(spacing: 8) {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .kitFont(.caption)
          .foregroundStyle(Hue.orange.text)
        Button("Try Again") { Task { await corpus.retry() } }
          .buttonStyle(.kit)
          .controlSize(.small)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    } else if corpus.more {
      HStack(spacing: 6) {
        LiveIcon(systemImage: "arrow.down", hue: .gray, status: .working, size: 16)
        Text("reading the next page…")
          .kitFont(.caption)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .onAppear { Task { await corpus.loadNextPage() } }
    }
  }

  /// The table without rows, which is three different empties: not read yet, nothing on the server, nothing matching.
  @ViewBuilder private var emptyState: some View {
    if corpus.isLoading || corpus.isSearching {
      EmptyState(systemImage: "text.magnifyingglass", title: "Reading…", status: .working)
    } else if !corpus.hasRead {
      EmptyState(
        systemImage: "text.alignleft", title: "Nothing Read Yet",
        message: "Check the server, then this table reads its corpus a page at a time.")
    } else if !corpus.isEmptyQuery {
      EmptyState(
        systemImage: "magnifyingglass", title: "No Matches",
        message: "No line matches this search in the \(corpus.rows.count) lines read so far."
      ) {
        if corpus.more {
          Button("Read On") { Task { await corpus.loadNextPage() } }
            .buttonStyle(.kit)
            .help("Reads the next page and looks again — the service has no search route to ask in one call")
        }
      }
    } else {
      EmptyState(
        systemImage: "text.alignleft", title: "No Sentences",
        message: "This server's corpus holds no sentences for this locale yet.")
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 2) {
      MetaLine {
        Text(corpus.footerLine)
        if corpus.more && !corpus.isLoading {
          Text("scroll for more").foregroundStyle(.kitTertiary)
        }
      }
      if let note = corpus.searchNote {
        Text(note)
          .kitFont(.caption)
      }
      if corpus.valuesMayHaveMoved {
        Text("Press Read Again to see the values the run wrote — the rows below are what the server held before it.")
          .kitFont(.caption)
          .foregroundStyle(Hue.orange.text)
      }
    }
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
      Text(row.namespace)
        .kitFont(.monoSmall)
        .foregroundStyle(.kitTertiary)
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
          .foregroundStyle(Hue.green.fill)
          .help("gold — a person decided this value")
      case "machine":
        Image(systemName: "wand.and.stars")
          .foregroundStyle(.kitSecondary)
          .help("machine — a model wrote it")
      case "imported":
        Image(systemName: "square.and.arrow.down")
          .foregroundStyle(.kitTertiary)
          .help("imported — it came from somewhere else and has nobody behind it")
      default:
        EmptyView()
      }
      if row.stale {
        Image(systemName: "clock.badge.exclamationmark")
          .foregroundStyle(Hue.orange.fill)
          .help("stale — the source or the comment changed after this value was written")
      }
    }
    .kitFont(.caption)
    .frame(width: 14, alignment: .leading)
    .padding(.top, 2)
  }
}

/// A comment or a value as the grid shows it: the text (a quiet placeholder when there is none), tinted while it
/// was written from this pane, and what the server answered to the last write under it.
private struct NotedCell: View {
  let corpus: ServerCorpus
  let row: ServerCorpus.Row
  let field: ServerCorpus.Field

  var body: some View {
    let text = field == .value ? row.value : row.comment
    let edited = field == .value ? row.valueEditedLocally : row.commentEditedLocally
    VStack(alignment: .leading, spacing: 2) {
      if text.isEmpty {
        Text(field == .value ? "missing — double-click to add" : "add a comment — double-click to edit")
          .foregroundStyle(.kitTertiary)
      } else {
        Text(text)
          .lineLimit(4)
          .foregroundStyle(edited ? AnyShapeStyle(Hue.accent.text) : AnyShapeStyle(.kitLabel))
      }
      if let note = corpus.note(for: row.source, field) {
        Text(note)
          .kitFont(.caption)
          .foregroundStyle(isFailure(note) ? AnyShapeStyle(Hue.orange.text) : AnyShapeStyle(.kitSecondary))
          .lineLimit(2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func isFailure(_ note: String) -> Bool {
    !(note.hasPrefix("written") || note.hasPrefix("comment written"))
  }
}
