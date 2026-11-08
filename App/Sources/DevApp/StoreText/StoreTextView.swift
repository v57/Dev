//
//  StoreTextView.swift
//  Dev
//

import ComponentKit
import Foundation
import PlatformBroadcast
import SwiftUI
import VaultKit

/// The Store Text tab: everything a store or release page says, written once and reused. Left, the fields; middle, the
/// text being edited (the base text, a destination's override, or a locale's); right, how long it is at every
/// destination, counted as you type. Every edit goes straight to `.dev/store/`, which agents edit over MCP too. Nothing
/// reaches the network except from Import, Publish or Translate.
struct StoreTextView: View {
  let root: URL
  let projectName: String

  /// A field with what the left column says about it.
  private struct FieldState: Equatable {
    var isOver = false
    var isEmpty = true
    var isPrivate = false
  }

  @State private var texts: StoreTexts?
  @State private var settings = StoreSettings()
  @State private var versions: [String] = []
  @State private var version: String?
  @State private var field: StoreField = .name
  /// Which text is open: nil is the base text.
  @State private var destination: StoreDestination?
  @State private var locale = ""

  /// The open text as it's being typed, saved shortly after each change.
  @State private var buffer = ""
  @State private var bufferAddress: StoreAddress?
  @State private var saveTask: Task<Void, Never>?
  @State private var inherited: StoreTexts.Resolved?
  @State private var isDraft = true
  @State private var translationState: StoreTexts.TranslationState = .missing

  @State private var rows: [StoreTexts.SlotReport] = []
  @State private var states: [StoreField: FieldState] = [:]
  @State private var privateCount = 0
  @State private var trackedPrivate: [String] = []
  @State private var observer: Broadcast.Observation?
  @State private var vaultStatus: StoreVaultSync.Status = .unknown
  @State private var vaultObserver: VaultChangeObserver?
  @State private var vaultTask: Task<Void, Never>?

  @State private var showsSetup = false
  @State private var showsNewVersion = false
  @State private var syncMode: StoreSyncSheet.Mode?
  @State private var translating: Int?
  @State private var translateTask: Task<Void, Never>?
  @State private var notice: String?

  var body: some View {
    KitWindowLayout {
      fieldList
        .frame(width: 240)
        .kitPane(.secondary)
      editor
        .frame(maxWidth: .infinity)
        .kitPane()
      inspector
        .frame(width: 310)
        .kitPane(.secondary)
    }
    .toolbar {
      KitToolbarItem(placement: .primaryAction) {
        ToolGroup {
          Button("Setup", systemImage: "gearshape") { showsSetup = true }
            .kitHelp("Setup", meta: "Languages, destinations and the keys Import and Publish use", systemImage: "gearshape")
          translateButton
          Button("Import", systemImage: "square.and.arrow.down") { syncMode = .importing }
            .kitHelp("Import", meta: "Read the text a service has now, once, and keep what you pick", systemImage: "square.and.arrow.down")
          Button("Publish", systemImage: "paperplane") { syncMode = .publishing }
            .kitHelp("Publish", meta: "Compare with what's live, then send after you confirm", systemImage: "paperplane")
        }
      }
    }
    .task(id: root) { await open() }
    .onChange(of: field) { reopen() }
    .onChange(of: destination) { reopen() }
    .onChange(of: locale) { reopen() }
    .onChange(of: version) { reopen() }
    .onChange(of: buffer) { edited() }
    .onAppear {
      // An agent saved over MCP: show it, unless the same text is being typed here.
      observer = Broadcast.observe(AgentChannel.changed) { info in
        guard info["project"] == root.path else { return }
        Task { @MainActor in
          reload()
        }
      }
      // Another device's text arrived, or this device's other windows wrote.
      vaultObserver = VaultChangeObserver { Task { @MainActor in scheduleVaultSync() } }
    }
    .onDisappear {
      flush()
      observer?.cancel()
      observer = nil
      vaultObserver = nil
      vaultTask?.cancel()
      translateTask?.cancel()
      // What was just typed reaches the vault even though the tab closed.
      let root = root
      Task { _ = await StoreVaultSync.sync(root: root) }
    }
    .kitSheet(isPresented: $showsSetup, onDismiss: { reload() }) {
      StoreSetupSheet(root: root)
    }
    .kitSheet(isPresented: $showsNewVersion, onDismiss: { reload() }) {
      StoreNewVersionSheet(root: root) { created in
        version = created
        field = .changelog
      }
    }
    .kitSheet(
      isPresented: Binding(get: { syncMode != nil }, set: { if !$0 { syncMode = nil } }), onDismiss: { reload() }
    ) {
      if let syncMode {
        StoreSyncSheet(root: root, mode: syncMode, version: version, destinations: settings.used)
      }
    }
    .kitNotice(
      "Store Text", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
      message: notice.map { "\($0)" })
  }

  // MARK: - Fields

  private var fieldList: some View {
    KitList(selection: Binding(get: { Optional(field) }, set: { if let picked = $0 { field = picked } })) {
      KitSection("Listing", systemImage: "doc.plaintext", hue: .blue) {
        ForEach(StoreField.listing) { fieldRow($0) }
      }
      KitSection("Links", systemImage: "link", hue: .gray) {
        ForEach(StoreField.links) { fieldRow($0) }
      }
      KitSection("Review", systemImage: "checkmark.seal", hue: .green) {
        fieldRow(.reviewNotes)
      }
      KitSection("Version", meta: version ?? String(localized: "None yet"), systemImage: "number", hue: .orange) {
        if !versions.isEmpty {
          KitPicker(
            "Version", selection: Binding(get: { version ?? "" }, set: { version = $0 }),
            options: versions.map { ("\($0)", $0) })
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        ForEach(StoreField.perVersion) { fieldRow($0) }
      } accessory: {
        Button("New Version…", systemImage: "plus") { showsNewVersion = true }
          .kitHelp("New Version", meta: "Starts its changelog from git log, as a draft to edit", systemImage: "plus")
      }
    }
  }

  private func fieldRow(_ item: StoreField) -> some View {
    let state = states[item] ?? FieldState()
    return SidebarRow(value: item, item.title) {
      RowTile(systemImage: item.systemImage, hue: state.isOver ? .red : (state.isEmpty ? .gray : .blue))
    } trailing: {
      if state.isOver {
        StatusDot(hue: .red)
      } else if !state.isEmpty, state.isPrivate {
        Image(systemName: "lock").kitFont(.caption).foregroundStyle(.kitSecondary)
      }
    }
    .isCurrent(field == item)
  }

  // MARK: - Editor

  private var address: StoreAddress {
    StoreAddress(
      field: field, destination: destination, locale: locale == settings.baseLocale || !field.isLocalized ? nil : locale,
      version: field.isPerVersion ? version : nil)
  }

  private var scopes: [StoreDestination] { settings.used.filter { $0.slot(field) != nil } }

  @ViewBuilder
  private var editor: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      if field.isPerVersion, version == nil {
        EmptyState(
          systemImage: "number", title: "No Version Yet",
          message: "A new version starts its changelog from git log, as a draft to edit."
        ) {
          Button("New Version…") { showsNewVersion = true }.buttonStyle(.kitPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        scopeBar
        if destination != nil, buffer.isEmpty, let inherited {
          inheritedText(inherited)
        } else {
          textField
        }
        footer
      }
    }
    .padding(18)
  }

  private var header: some View {
    HStack(spacing: 10) {
      RowTile(systemImage: field.systemImage, hue: .blue)
      Text(field.title).kitFont(.title3).fontWeight(.semibold)
      stateChip
      Spacer()
      if settings.allLocales.count > 1, field.isLocalized {
        KitPicker("Language", selection: $locale, options: settings.allLocales.map { ("\(Self.localeTitle($0))", $0) })
          .kitPickerMaxWidth(180)
      }
    }
  }

  @ViewBuilder
  private var stateChip: some View {
    if !buffer.isEmpty {
      if field.isAlwaysPrivate {
        Chip("Private", systemImage: "lock", hue: .gray)
          .kitHelp("Always private", meta: "Written for one reader: it stays out of git.", systemImage: "lock")
      } else {
        Button {
          setReady(isDraft)
        } label: {
          Chip(isDraft ? "Draft" : "Ready", systemImage: isDraft ? "lock" : "checkmark", hue: isDraft ? .orange : .green)
        }
        .buttonStyle(.plain)
        .kitHelp(
          isDraft ? "Draft: kept out of git" : "Ready: goes in the repository",
          meta: isDraft ? "Press when this text may be public." : "Press to keep it out of git again.",
          systemImage: isDraft ? "lock" : "checkmark")
      }
    }
  }

  private var scopeBar: some View {
    let scopes = scopes
    return HStack(spacing: 10) {
      if !scopes.isEmpty {
        KitSegmented(
          selection: $destination,
          segments: [KitSegment("Base", value: StoreDestination?.none)]
            + scopes.map { KitSegment($0.shortTitle, value: Optional($0)) })
      }
      Spacer()
      if destination != nil, !buffer.isEmpty {
        Button("Remove Override") {
          buffer = ""
          flush()
          reload()
        }
        .buttonStyle(.kit)
      }
    }
  }

  private func inheritedText(_ inherited: StoreTexts.Resolved) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ScrollView {
        Text(inherited.isEmpty ? "No base text yet." : inherited.text)
          .foregroundStyle(.kitSecondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .frame(maxHeight: field.isSingleLine ? 60 : .infinity)
      .kitSurface(.card, cornerRadius: KitMetrics.radiusCard)
      HStack {
        Text("\(destination?.title ?? "") uses the base text.").foregroundStyle(.kitSecondary).kitFont(.callout)
        Spacer()
        Button("Write an Override") { buffer = inherited.text }
          .buttonStyle(.kit)
      }
      if field.isSingleLine { Spacer() }
    }
  }

  @ViewBuilder
  private var textField: some View {
    if field.isSingleLine {
      TextField(field.title, text: $buffer, prompt: Text(prompt))
        .labelsHidden()
        .kitField()
      Spacer(minLength: 0)
    } else {
      TextEditor(text: $buffer)
        .kitFont(.body)
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .kitSurface(.card, cornerRadius: KitMetrics.radiusCard)
        .accessibilityLabel(field.title)
    }
  }

  private var prompt: String {
    switch field {
    case .category: "DEVELOPER_TOOLS"
    case .copyright: String(localized: "2026 Your Name")
    case .supportURL, .marketingURL, .privacyURL: "https://"
    default: field.title
    }
  }

  /// What the open text is, under it.
  @ViewBuilder
  private var footer: some View {
    let isBase = address.locale == nil
    HStack(spacing: 10) {
      if field.isList { Text("One per line.").foregroundStyle(.kitSecondary) }
      if !isBase, field.isTranslated {
        switch translationState {
        case .missing: Text("Not translated yet.").foregroundStyle(.kitSecondary)
        case .current: Text("Translated by Dev. Editing it makes it yours: translation leaves it alone.").foregroundStyle(.kitSecondary)
        case .outdated: Text("The base text changed since this was translated.").foregroundStyle(.orange)
        case .manual: Text("Written by hand: translation leaves it alone.").foregroundStyle(.kitSecondary)
        }
      }
      Spacer()
      Text(StoreTexts.path + "/" + (isDraft || field.isAlwaysPrivate ? "private/" : "") + (texts?.relativePath(address) ?? ""))
        .kitFont(.monoSmall)
        .foregroundStyle(.kitTertiary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .kitFont(.callout)
  }

  private static func localeTitle(_ code: String) -> String {
    Locale.current.localizedString(forIdentifier: code) ?? code
  }

  // MARK: - Limits

  private var inspector: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        FormCard("Limits") {
          let shown = rows.filter { $0.slot.field == field && ($0.locale == locale || !$0.destination.isLocalized) }
          if shown.isEmpty {
            GroupRow("Not shown anywhere", help: "No destination in use has this field.")
          }
          ForEach(shown, id: \.destination) { row in limitRow(row) }
        }
        .controlSize(.small)
        FormCard("Out of Git") {
          GroupRow(
            privateCount == 1 ? "1 private text" : "\(privateCount) private texts",
            help: "Drafts, review notes and messages to testers live in .dev/store/private/, which .dev/store/.gitignore keeps out of commits. \(vaultNote)")
          if !trackedPrivate.isEmpty {
            FormRow(
              "\(trackedPrivate.count) already in git",
              help: "Files in private/ that git tracks: the ignore rule can't hide them. Remove them with git rm --cached before pushing.",
              systemImage: "exclamationmark.triangle", hue: .red)
          }
        }
        .controlSize(.small)
      }
      .padding(14)
    }
  }

  /// The row's count from what's being typed when it shows the open text, so it moves with each keystroke.
  private func liveText(_ row: StoreTexts.SlotReport) -> String {
    guard let open = bufferAddress, open.field == row.slot.field else { return row.resolved.text }
    if row.resolved.address == open { return buffer }
    // Text typed since the last save: an override this destination has just got, or a first base text.
    if open.destination == row.destination, !buffer.isEmpty { return buffer }
    if open.destination == nil, row.resolved.origin == .missing { return buffer }
    return row.resolved.text
  }

  private func limitRow(_ row: StoreTexts.SlotReport) -> some View {
    let text = liveText(row)
    let count = text.isEmpty ? nil : row.slot.limit?.count(StoreTexts.normalized(text, field: row.slot.field), field: row.slot.field)
    let hue: Hue = count?.isOver == true ? (row.slot.isEstimate ? .orange : .red) : .accent
    var notes: [String] = []
    if let count {
      notes.append(count.text)
    } else if row.slot.limit == nil, !text.isEmpty {
      notes.append(String(localized: "\(text.count) characters"))
    }
    if let long = count?.longItem { notes.append(String(localized: "\"\(long)\" is too long")) }
    switch row.resolved.origin {
    case .override: notes.append(String(localized: "its own text"))
    case .locale: notes.append(String(localized: "this language's text"))
    case .baseOverride: notes.append(String(localized: "its own text, not translated"))
    case .base:
      notes.append(
        row.locale == settings.baseLocale
          ? String(localized: "base text") : String(localized: "base text, not translated"))
    case .missing: notes.append(String(localized: "empty"))
    }
    if let hint = row.slot.hint { notes.append(hint) }
    if !row.slot.isSent { notes.append(String(localized: "set by hand on the service")) }
    return GroupRow(
      "\(row.destination.shortTitle): \(row.slot.title)",
      help: "\(notes.joined(separator: " · "))"
    ) {
      HStack(spacing: 8) {
        if let count { MicroBar(value: min(count.fraction, 1), hue: hue) }
        if !row.slot.isSent, !text.isEmpty { KitCopyButton(value: text) }
      }
    }
  }

  // MARK: - Translate

  @ViewBuilder
  private var translateButton: some View {
    if let translating {
      Button("Stop", systemImage: "stop.fill", role: .destructive) { translateTask?.cancel() }
        .kitHelp("Stop", meta: "Translating: \(translating) done", systemImage: "stop.fill")
    } else {
      Button("Translate", systemImage: "globe") { translate() }
        .kitHelp("Translate", meta: "Fill the other languages with the model in Settings", systemImage: "globe")
        .disabled(settings.locales.isEmpty)
    }
  }

  private func translate() {
    guard let texts else { return }
    flush()
    let version = version, settings = settings
    translating = 0
    translateTask = Task {
      var failure: String?
      for locale in settings.locales where !Task.isCancelled {
        let work = await Task.detached { StoreTranslator.work(in: texts, locale: locale, version: version) }.value
        let result = await StoreTranslator.run(work, from: settings.baseLocale, in: texts) { done in translating = done }
        failure = result.failure ?? failure
      }
      translating = nil
      notice = failure.map { "Translation stopped: \($0)" }
      reload()
    }
  }

  // MARK: - Loading and saving

  private func open() async {
    let opened = StoreTexts(root: root)
    texts = opened
    settings = opened.settings()
    locale = settings.baseLocale
    if LaunchOptions.isScreenshotMode, LaunchOptions.open == "storeSetup" { showsSetup = true }
    reload()
    await syncVault()
  }

  private var vaultNote: String {
    switch vaultStatus {
    case .unknown, .kept: String(localized: "They're also encrypted in your vault, for your other devices.")
    case .notInVault: String(localized: "This project isn't in your vault, so they're only on this device.")
    case .failed(let message): String(localized: "They're only on this device for now: the vault said \(message)")
    }
  }

  /// Soon after a change, so typing doesn't make a pass per pause.
  private func scheduleVaultSync() {
    vaultTask?.cancel()
    vaultTask = Task {
      try? await Task.sleep(for: .milliseconds(1500))
      guard !Task.isCancelled else { return }
      await syncVault()
    }
  }

  /// One pass of the mirror. What's typed is saved first and goes with it; text that arrived replaces the open text
  /// unless more was typed during the pass, which then merges in the next one.
  private func syncVault() async {
    flush()
    let typed = buffer
    let status = await StoreVaultSync.sync(root: root)
    vaultStatus = status
    guard case .kept(let report) = status, report.changedFiles else { return }
    if buffer == typed { bufferAddress = nil }
    if report.conflicts > 0 {
      notice = String(localized: "Two devices changed the same text. Both versions are in it, between conflict markers: pick one and remove the markers.")
    }
    reload()
  }

  /// The tool's picture of the disk, read off the main thread; the open text only when it isn't being typed.
  private func reload() {
    flush()
    let opened = StoreTexts(root: root)
    texts = opened
    settings = opened.settings()
    if !settings.allLocales.contains(locale) { locale = settings.baseLocale }
    versions = opened.versions()
    if version == nil || !versions.contains(version ?? "") { version = versions.first }
    loadBuffer()
    let version = version
    Task {
      let (rows, states, count) = await Task.detached { () -> ([StoreTexts.SlotReport], [StoreField: FieldState], Int) in
        let rows = opened.report(version: version)
        var states: [StoreField: FieldState] = [:]
        for field in StoreField.allCases {
          let own = rows.filter { $0.slot.field == field }
          let base = opened.entry(StoreAddress(field: field, version: field.isPerVersion ? version : nil))
          states[field] = FieldState(
            isOver: own.contains { !$0.slot.isEstimate && $0.count?.isOver == true },
            isEmpty: base == nil, isPrivate: base?.isPrivate == true)
        }
        return (rows, states, opened.privateFileCount())
      }.value
      self.rows = rows
      self.states = states
      self.privateCount = count
      self.trackedPrivate = await opened.trackedPrivateFiles()
    }
    scheduleVaultSync()
  }

  /// A selection changed: save what was open, then read what's open now.
  private func reopen() {
    flush()
    if !scopes.contains(where: { $0 == destination }) { destination = nil }
    loadBuffer()
  }

  private func loadBuffer() {
    guard let texts else { return }
    let address = address
    if field.isPerVersion, version == nil {
      bufferAddress = nil
      buffer = ""
      return
    }
    let entry = texts.entry(address)
    // What's typed stays as typed when it says the same as the file: a save trims it, and the space just typed
    // shouldn't vanish.
    if bufferAddress != address || StoreTexts.normalized(buffer, field: address.field) != entry?.text ?? "" {
      buffer = entry?.text ?? ""
    }
    bufferAddress = address
    // A new text starts as a draft; one that's there says where it is.
    isDraft = entry?.isPrivate ?? true
    translationState = texts.translationState(of: address)
    inherited = address.destination == nil
      ? nil : texts.resolved(field, destination: nil, locale: address.locale, version: address.version)
  }

  /// The reader typed: save shortly, so the file follows without a write per keystroke.
  private func edited() {
    guard let bufferAddress, let texts, texts.entry(bufferAddress)?.text != StoreTexts.normalized(buffer, field: field) else { return }
    saveTask?.cancel()
    saveTask = Task {
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      flush()
      reload()
    }
  }

  /// Writes the open text now if it differs from the file.
  private func flush() {
    saveTask?.cancel()
    guard let bufferAddress, let texts else { return }
    let clean = StoreTexts.normalized(buffer, field: bufferAddress.field)
    guard texts.entry(bufferAddress)?.text ?? "" != clean else { return }
    do {
      try texts.write(clean, at: bufferAddress)
      if bufferAddress.locale != nil { try texts.forgetTranslationSource(of: bufferAddress) }
    } catch {
      notice = error.localizedDescription
    }
  }

  private func setReady(_ ready: Bool) {
    guard let texts else { return }
    flush()
    do {
      try texts.setReady(
        ready, field: field, destination: destination, version: field.isPerVersion ? version : nil)
    } catch {
      notice = error.localizedDescription
    }
    reload()
  }
}
