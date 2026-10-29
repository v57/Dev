//
//  ServerRunBar.swift
//  Dev
//

import ComponentKit
import SwiftUI

/// The server pane's controls: which locale to translate into, which namespace
/// to scope to, and the pair of starts — `Translate` and its icon-only
/// skip-learning twin — followed by what the run is doing.
///
/// The pair is deliberately the SAME pair the Localization pane offers
/// (`Label("Translate", systemImage: "translate")`, `.borderedProminent`, then
/// the `forward.fill` twin sharing `Translation.Run.skipLearningHelp`), because
/// both panes start the same plan; only the rows differ (a project's catalog
/// here, this server's corpus there). A start that cannot run says WHY in its
/// tooltip instead of going grey silently.
struct ServerRunBar: View {
  let row: ServerRow
  let store: ServerStore
  /// The pane's run, so the stats table can refresh off the same object.
  let run: ServerRun
  /// Called when a run finishes, so the pane re-reads the server's tally.
  let onFinished: () -> Void

  /// Locales the server already holds, from the pane's stats.
  let serverLocales: [LocalizeStats.Row]
  /// Namespaces present in the corpus, fetched once by the pane.
  let namespaces: [String]

  @State private var locale: String = ServerRunBar.commonLocales.first ?? "fr"
  @State private var scope: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Picker("Locale", selection: $locale) {
          ForEach(localeChoices, id: \.self) { code in
            Text(label(for: code)).tag(code)
          }
        }
        .frame(maxWidth: 220)
        .help("The language this run translates into")

        if !namespaces.isEmpty {
          Picker("Scope", selection: $scope) {
            Text("All sentences").tag(String?.none)
            ForEach(namespaces, id: \.self) { namespace in
              Text(namespace).tag(String?.some(namespace))
            }
          }
          .frame(maxWidth: 200)
          .help("Translate only this namespace (a smaller, cheaper run)")
        }

        Button {
          start(.full)
        } label: {
          Label("Translate", systemImage: "translate")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canStart)
        .help(translateHelp)

        // The twin: the same run with the learning step left out. Icon-only,
        // because the difference is ONE thing and the tooltip is where it is
        // said — the sentence is shared with the other panes' twin.
        Button {
          start(.skipLearning)
        } label: {
          Image(systemName: "forward.fill")
        }
        .disabled(!canStart)
        .help(skipLearningHelp)

        if run.isRunning {
          Button("Stop") { run.cancel() }
            .help("Stops between batches — every value already accepted stays")
        }
      }

      if run.progress != nil {
        ServerRunEstimateBar(run: run)
      }
      if !run.summaryLine.isEmpty {
        Text(run.summaryLine)
          .font(.caption)
          .foregroundStyle(run.isRunning ? .secondary : .primary)
          .textSelection(.enabled)
      }
      ForEach(run.notes.suffix(4), id: \.self) { note in
        Text(note)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .onChange(of: run.phase) { _, phase in
      if phase == .finished || phase == .cancelled { onFinished() }
    }
  }

  // MARK: - choices

  /// Every locale the app is willing to ask for: what the server already holds
  /// first (those are the ones with values to compare against), then the common
  /// set, so a fresh deployment with no values anywhere can still be translated.
  private var localeChoices: [String] {
    var codes = serverLocales.map(\.locale)
    for code in Self.commonLocales where !codes.contains(code) { codes.append(code) }
    return codes
  }

  private func label(for code: String) -> String {
    guard let row = serverLocales.first(where: { $0.locale == code }) else { return code }
    return "\(code) — \(row.total - row.missing)/\(row.total)"
  }

  /// The locale with the most work, so the default is the useful one.
  static func defaultLocale(from rows: [LocalizeStats.Row]) -> String {
    rows.max { $0.missing < $1.missing }?.locale ?? commonLocales.first ?? "fr"
  }

  static let commonLocales = [
    "fr", "de", "es", "it", "pt-PT", "nl", "pl", "ru", "uk", "tr", "sv", "da", "fi", "cs",
    "zh-Hans", "ja", "ko", "ar", "hi", "id", "vi", "th",
  ]

  // MARK: - start

  private func start(_ plan: ServerRun.Plan) {
    run.start(connection: connection, locale: locale, scope: scope, plan: plan)
  }

  private var connection: ServerConnection {
    // A row the store cannot resolve would be a bug in the pane, not a state the
    // reader can fix; the run reports it as a failure rather than pretending.
    store.connection(id: row.id) ?? ServerConnection(id: row.id, name: row.name, endpoint: row.endpoint)
  }

  private var canStart: Bool {
    !run.isRunning && row.base != nil && row.keySource != .missing
  }

  private var translateHelp: String {
    if run.isRunning { return "A run is in progress — stop it first" }
    if row.base == nil { return "The endpoint is not a usable http(s) URL — edit this server" }
    if row.keySource == .missing { return "No key: add one to this server, or set \(ServerKeychain.sharedKeyName)" }
    return "Run learn, then translate every sentence this server is missing in \(locale), then the row pass. Values are written back as machine values."
  }

  private var skipLearningHelp: String {
    if run.isRunning { return "A run is in progress — stop it first" }
    return "\(Translation.Run.skipLearningHelp) — here it skips folding this server's verified values in first."
  }
}

/// The run's estimated progress and the time it has left (`ServerRun.Progress`), read on a
/// timer while the run lasts, as the project run's `Translation.RunEstimateBar` does; once it
/// stops, the bar stays where it got to.
struct ServerRunEstimateBar: View {
  let run: ServerRun

  var body: some View {
    TimelineView(.animation(minimumInterval: 0.5, paused: !run.isRunning)) { _ in
      let estimate = run.estimate
      HStack(spacing: 12) {
        KitProgressBar(status: status(estimate))
        Text(estimate?.line ?? (run.isRunning ? "Estimating…" : ""))
          .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
    }
  }

  private func status(_ estimate: Translation.Run.Estimate?) -> WorkStatus {
    switch run.phase {
    case .finished: return .done
    case .failed(let message): return .failed(message)
    default:
      return run.isRunning
        ? .working(progress: estimate?.fraction) : .paused(progress: estimate?.fraction)
    }
  }
}
