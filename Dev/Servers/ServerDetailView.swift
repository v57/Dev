//
//  ServerDetailView.swift
//  Dev
//

import SwiftUI

/// The pane for one server: what it is, whether it answers, and what its corpus
/// holds.
///
/// This is a READ-ONLY view of the service on purpose. The Localize tool owns
/// the corpus work (values, comments, runs) for a project's catalog; the server
/// pane answers the two questions a reader has while looking at the sidebar:
/// "is this server the one I think it is" and "does it have the strings I am
/// about to import". Both come from `localize/stats`, which writes nothing.
struct ServerDetailView: View {
  let serverID: String
  let store: ServerStore

  @State private var rows: [LocalizeStats.Row] = []
  @State private var messages: Int?
  @State private var commented: Int?
  @State private var loadError: String?
  @State private var isLoading = false
  @State private var editing = false
  /// The pane's translation run: started from the bar, its progress and its
  /// summary are shown beside the stats the run moves.
  @State private var run = ServerRun()
  /// Namespaces present in the corpus, for the scope picker. Read once per pane.
  @State private var namespaces: [String] = []

  private var row: ServerRow? { store.row(id: serverID) }
  private var status: ServerStatus { store.statuses[serverID] ?? .unknown }

  var body: some View {
    Group {
      if let row {
        content(row)
      } else {
        ContentUnavailableView(
          "Server not found", systemImage: "server.rack",
          description: Text("This connection was removed. Pick another one in the sidebar."))
      }
    }
    .navigationTitle(row?.name ?? "Server")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          Task { await check() }
        } label: {
          Label("Check", systemImage: "arrow.clockwise")
        }
        .disabled(row == nil || isLoading)
        .help("Ask this server for its tally")

        Button("Edit…") { editing = true }
          .disabled(row == nil)
      }
    }
    .sheet(isPresented: $editing) {
      ServerFormView(editing: store.connection(id: serverID)) { name, endpoint, key in
        store.update(id: serverID, name: name, endpoint: endpoint, key: key)
      }
    }
    .task(id: serverID) { await check() }
  }

  // MARK: - content

  private func content(_ row: ServerRow) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header(row)
        statusBlock
        // The run bar sits with the stats it moves: press Translate below and
        // these numbers are what changes.
        ServerRunBar(
          row: row,
          store: store,
          run: run,
          onFinished: { Task { await check() } },
          serverLocales: rows,
          namespaces: namespaces)
        if let loadError {
          Label(loadError, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        if !rows.isEmpty {
          statsTable
        } else if store.statuses[serverID]?.isOnline == true {
          // Registered but untranslated is the normal state of a fresh
          // deployment: the boot registration fills the inventory, values
          // appear only after a client's run.
          Text("No translated values in any locale yet — the inventory is registered, nothing is translated.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func header(_ row: ServerRow) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(row.endpoint)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
      Text(row.keySource.label)
        .font(.caption)
        .foregroundStyle(row.keySource == .missing ? .orange : .secondary)
      if let at = store.checkedAt[serverID] {
        Text("last checked \(at.formatted(date: .omitted, time: .standard))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var statusBlock: some View {
    HStack(spacing: 8) {
      switch status {
      case .online(let messages, let commented):
        Label("\(messages) sentences, \(commented) commented", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      case .checking:
        Label("checking…", systemImage: "clock")
          .foregroundStyle(.secondary)
      case .unknown:
        Label("not checked yet", systemImage: "questionmark.circle")
          .foregroundStyle(.secondary)
      case .offline(let detail):
        Label(detail, systemImage: "xmark.circle.fill")
          .foregroundStyle(.red)
      case .notConfigured(let detail):
        Label(detail, systemImage: "exclamationmark.circle.fill")
          .foregroundStyle(.orange)
      }
    }
    .textSelection(.enabled)
  }

  private var statsTable: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Corpus by locale")
        .font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
        GridRow {
          Text("locale").font(.caption).foregroundStyle(.secondary)
          Text("total").font(.caption).foregroundStyle(.secondary)
          Text("machine").font(.caption).foregroundStyle(.secondary)
          Text("gold").font(.caption).foregroundStyle(.secondary)
          Text("missing").font(.caption).foregroundStyle(.secondary)
          Text("stale").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(rows, id: \.locale) { stats in
          GridRow {
            Text(stats.locale).monospaced()
            Text("\(stats.total)").monospacedDigit()
            Text("\(stats.machine)").monospacedDigit()
            Text("\(stats.gold)").monospacedDigit()
            Text("\(stats.missing)").monospacedDigit()
            Text("\(stats.stale)").monospacedDigit()
          }
        }
      }
    }
  }

  // MARK: - check

  /// A check runs the store's own check (so the sidebar dot and this pane can
  /// never disagree) and then reads the per-locale rows the store does not keep.
  private func check() async {
    guard row != nil else { return }
    isLoading = true
    loadError = nil
    await store.check(id: serverID)
    defer { isLoading = false }

    guard store.statuses[serverID]?.isOnline == true,
          let connection = store.connection(id: serverID),
          let client = connection.client else {
      rows = []
      messages = nil
      commented = nil
      return
    }
    do {
      let stats = try await client.post("localize/stats", [:], as: LocalizeStats.self)
      rows = stats.rows.sorted { $0.locale < $1.locale }
      messages = stats.messages
      commented = stats.commented
      await loadNamespaces(client)
    } catch {
      rows = []
      loadError = (error as? LocalizeClient.Error)?.description ?? "\(error)"
    }
  }

  /// The namespaces the corpus actually uses, for the run bar's scope picker.
  /// One page is enough to name them, and a failure here only costs the scope
  /// control — it must not blank the pane's stats, which did load.
  private func loadNamespaces(_ client: LocalizeClient) async {
    do {
      let page = try await client.post(
        "localize/messages", ["limit": 1000], as: LocalizeInventory.self)
      namespaces = Array(Set(page.items.map(\.namespace))).sorted()
    } catch {
      namespaces = []
    }
  }
}
