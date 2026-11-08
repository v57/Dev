//
//  LocalizationsView.swift
//  Dev
//
//  The Translations tool: every v57 app's strings in the translations repository. The list shows the sources (each
//  app's own strings, then the kits apps share) with how far they're translated; the overview holds the repository,
//  the apps a scan builds and the languages; a source's page shows which apps use it and each language's progress.
//

import ComponentKit
import SwiftUI

struct LocalizationsSidebarRow: View {
  @Environment(Translation.Shell.self) private var shell
  private var store: LocalizationsStore { .shared }

  var body: some View {
    SidebarRow(
      value: SidebarSelection.translations, "Translations", systemImage: "globe",
      status: store.isBusy ? .working() : .idle
    ) {
      if let activity = store.activity {
        Text(activity).foregroundStyle(.kitSecondary).lineLimit(1)
      }
    }
    .kitHelp(
      String(localized: "Translations"), meta: store.activity.map { "\($0)" } ?? String(localized: "Every app's strings in the translations repository"),
      systemImage: "globe")
    #if DEBUG
      .task { await store.listenForDebugCommands(shell: shell) }
    #endif
  }
}

struct LocalizationsView: View {
  @Environment(Translation.Shell.self) private var shell
  /// The source shown, "" for the overview.
  @State private var selected: String? = ""
  @State private var addingLanguages = false
  private var store: LocalizationsStore { .shared }

  var body: some View {
    ResizableSplit("translations.listWidth", pane: .leading, width: 290, range: 240...380, mainMinWidth: 440) {
      Group {
        if store.repoURL == nil {
          EmptyState(
            systemImage: "globe", title: "No Translations Repository",
            message: "Choose the checkout of v57/Localizations: one String Catalog per app and kit."
          ) {
            Button("Choose…") { store.chooseRepo() }.buttonStyle(.kitPrimary)
          }
        } else if let name = selected, !name.isEmpty {
          LocalizationsSourcePage(name: name)
            .id(name)
        } else {
          LocalizationsOverview(addingLanguages: $addingLanguages)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } pane: {
      sourceList
    }
    .toolbar {
      KitToolbarItem(placement: .primaryAction) {
        ToolGroup {
          if store.isBusy {
            Button("Stop", systemImage: "stop.fill") { store.cancel() }
              .kitHelp("Stop", meta: "Stop the build or the run; what's done is kept", systemImage: "stop.fill")
          }
          Button("Scan All", systemImage: "text.magnifyingglass") { store.scan() }
            .disabled(store.isBusy || store.repoURL == nil)
            .kitHelp("Scan All", meta: "Build every included app with string extraction on and update the catalogs", systemImage: "text.magnifyingglass")
          Button("Translate All", systemImage: "play.fill") { store.translate(shell: shell) }
            .disabled(store.isBusy || store.sourceNames.isEmpty)
            .kitHelp("Translate All", meta: "Translate every source into every language, one after the other", systemImage: "play.fill")
          Button("Build and Commit", systemImage: "checkmark.seal") { store.buildAndCommit() }
            .disabled(store.isBusy || store.repoURL == nil)
            .kitHelp("Build and Commit", meta: "Run Scripts/build, then commit each source that changed", systemImage: "checkmark.seal")
        }
      }
    }
    .kitSheet(isPresented: $addingLanguages) {
      LocalizationsLanguagesSheet()
    }
    .kitNotice(
      "Translations", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.dismissError() } }),
      message: store.error.map { "\($0)" })
    .task { store.refreshProgress() }
  }

  private var sourceList: some View {
    KitList(selection: $selected) {
      SidebarRow(
        value: "", String(localized: "Overview"), subtitle: (store.activity ?? store.summary).map { "\($0)" },
        systemImage: "square.grid.2x2", status: store.isBusy ? .working() : .idle)
      ForEach(store.sourceNames, id: \.self) { name in
        let source = store.source(name)
        let progress = store.progress[name]
        SidebarRow(
          value: name, name, subtitle: subtitle(source, progress),
          systemImage: source?.kind == .app ? "app" : "shippingbox",
          hue: source == nil ? .gray : nil,
          status: store.activity == String(localized: "Translating \(name)") ? .working() : .idle,
          progress: progress.map { progress in
            let languages = store.languages
            return languages.isEmpty ? 0 : languages.map(progress.fraction).reduce(0, +) / Double(languages.count)
          })
      }
    }
    .kitPane(.secondary)
  }

  private func subtitle(_ source: LocalizationsSource?, _ progress: SourceProgress?) -> String {
    guard let source else { return String(localized: "No scanned app uses it") }
    let keys = progress?.keys ?? source.keys.count
    let users = source.kind == .kit ? source.usedBy.joined(separator: ", ") : String(localized: "app")
    return String(localized: "\(keys) keys · \(users)")
  }
}

// MARK: - Overview

private struct LocalizationsOverview: View {
  @Binding var addingLanguages: Bool
  private var store: LocalizationsStore { .shared }

  var body: some View {
    ScrollView {
      VStack(spacing: KitMetrics.gutter) {
        FormCard("Repository", footer: "Translations only: Dev writes each catalog, Scripts/build compiles them and the commits are per source. Nothing is pushed.") {
          FormRow("Folder", help: store.repoURL.map { "\($0.path)" } ?? "", systemImage: "folder") {
            Button("Choose…") { store.chooseRepo() }
          }
          FormRow("Status", help: status, systemImage: "info.circle", status: store.isBusy ? .working() : .idle)
        }
        FormCard("Apps", footer: "Scan builds each app's -Local workspace with string extraction on (Xcode's own: the keys a String Catalog would get), in Dev's build folders. A kit another app links is a source of its own; a key goes in one place.") {
          ForEach(store.apps) { app in
            FormRow(app.name, help: appHelp(app), systemImage: "app", hue: app.included ? .accent : .gray) {
              HStack(spacing: 8) {
                Button("Scan") { store.scan([app.name]) }
                  .disabled(store.isBusy)
                Toggle("Include", isOn: Binding(get: { app.included }, set: { store.setIncluded(app.name, $0) }))
                  .toggleStyle(.kitSwitch)
                  .labelsHidden()
              }
            }
          }
          FormRow("Other App", help: "An app that isn't next to the repository, like Hub", systemImage: "plus.app") {
            Button("Add App…") { store.chooseApp() }
              .disabled(store.isBusy)
          }
        }
        FormCard("Languages", footer: "Every source is translated into these. Apps bundle a few and download the rest from the repository.") {
          FormRow(
            "\(store.languages.count) languages", help: "\(store.languages.joined(separator: ", "))",
            systemImage: "globe"
          ) {
            Button("Edit…") { addingLanguages = true }
          }
        }
        if !store.log.isEmpty {
          FormCard("Log") {
            ScrollView {
              Text(store.log.suffix(200).joined(separator: "\n"))
                .kitFont(.caption)
                .monospaced()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: 220)
          }
        }
      }
      .padding(KitMetrics.gutter)
    }
    .kitPane()
  }

  private var status: LocalizedStringKey {
    if let activity = store.activity { return "\(activity)…" }
    if let summary = store.summary { return "\(summary)" }
    return "\(store.sourceNames.count) sources"
  }

  private func appHelp(_ app: LocalizationsApp) -> String {
    guard let scan = store.state.scans[app.name] else { return String(localized: "Not scanned yet") }
    let sources = store.plan.lookup[app.name] ?? []
    let strings = sources.isEmpty ? String(localized: "no strings") : sources.joined(separator: " → ")
    return String(localized: "Scanned \(scan.date.formatted(date: .abbreviated, time: .shortened)) · \(strings)")
  }
}

// MARK: - One source

private struct LocalizationsSourcePage: View {
  let name: String
  @Environment(Translation.Shell.self) private var shell
  private var store: LocalizationsStore { .shared }

  var body: some View {
    let source = store.source(name)
    let progress = store.progress[name] ?? SourceProgress()
    let catalog = store.repoURL.map { LocalizationsRepo.catalog(name, in: $0) }
    ScrollView {
      VStack(spacing: KitMetrics.gutter) {
        FormCard(name) {
          FormRow(
            source?.kind == .kit ? "Kit" : source?.kind == .app ? "App" : "Not in the scan",
            help: kindHelp(source), systemImage: source?.kind == .app ? "app" : "shippingbox")
          FormRow(
            "\(progress.keys) keys to translate",
            help: progress.stale > 0 ? "\(progress.stale) stale (no longer in the code; kept, not translated)" : nil,
            systemImage: "text.quote")
          if let catalog {
            FormRow("Catalog", help: "\(catalog.path)", systemImage: "doc.text") {
              HStack(spacing: 8) {
                Button("Open in Xcode") { KitDesktop.open([catalog], withApp: "com.apple.dt.Xcode") }
                Button("Show in Finder") { KitDesktop.reveal([catalog]) }
              }
            }
          }
          FormRow("Translate", help: translateHelp, systemImage: "play.fill") {
            Button("Translate") { store.translate([name], shell: shell) }
              .buttonStyle(.kitPrimary)
              .disabled(store.isBusy)
          }
        }
        FormCard("Languages") {
          ForEach(store.languages, id: \.self) { code in
            let done = progress.translated[code] ?? 0
            let review = progress.needsReview[code] ?? 0
            FormRow(
              "\(Locale.current.localizedString(forIdentifier: code) ?? code)",
              help: review > 0
                ? "\(code) · \(done) of \(progress.keys) · \(review) to review"
                : "\(code) · \(done) of \(progress.keys)",
              systemImage: "globe", hue: done >= progress.keys && progress.keys > 0 ? .green : .accent
            ) {
              MicroBar(value: progress.fraction(code), hue: done >= progress.keys ? .green : .accent, width: 120)
            }
          }
        }
      }
      .padding(KitMetrics.gutter)
    }
    .kitPane()
  }

  private var translateHelp: LocalizedStringKey {
    if let problem = ModelSettings.problem { return "\(problem)" }
    if store.activity == String(localized: "Translating \(name)") { return "Translating…" }
    return "Into \(store.languages.count) languages with the Localization tab's pipeline; the catalog is saved when the run ends"
  }

  private func kindHelp(_ source: LocalizationsSource?) -> LocalizedStringKey {
    guard let source else { return "The repository has its catalog, but no included app's scan makes it" }
    let repo = URL(fileURLWithPath: source.repo).lastPathComponent
    switch source.kind {
    case .app: return "\(name)'s own strings (\(source.modules.joined(separator: ", ")))"
    case .kit: return "\(source.modules.joined(separator: ", ")) from \(repo), used by \(source.usedBy.joined(separator: ", "))"
    }
  }
}

// MARK: - Languages

private struct LocalizationsLanguagesSheet: View {
  @Environment(\.kitDismiss) private var dismiss
  @State private var selection: Set<String> = []
  private var store: LocalizationsStore { .shared }

  /// What the Localization tab offers, plus the bundled defaults it spells differently.
  private var offered: [String] {
    let all = LocalizationStore.offeredLanguages.filter { $0 != "en" }
    return all + LocalizationsState.defaultLanguages.filter { !all.contains($0) }
  }

  var body: some View {
    KitSheet(
      title: "Languages", meta: "\(selection.count) selected. Every source is translated into these.",
      systemImage: "globe", width: 680
    ) {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .leading)], alignment: .leading,
          spacing: 7
        ) {
          ForEach(offered.sorted(), id: \.self) { code in
            Toggle(
              code,
              isOn: Binding(
                get: { selection.contains(code) },
                set: { if $0 { selection.insert(code) } else { selection.remove(code) } })
            )
            .toggleStyle(.kitCheckbox)
            .help(Locale(identifier: "en").localizedString(forIdentifier: code) ?? code)
          }
        }
        .padding(10)
      }
      .frame(height: 340)
      .padding(.horizontal, KitMetrics.gutter)
    } footer: {
      Button("Select All") { selection = Set(offered) }
      Button("Defaults") { selection = Set(LocalizationsState.defaultLanguages) }
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Save") {
        for code in store.languages where !selection.contains(code) { store.removeLanguage(code) }
        store.addLanguages(offered.filter { selection.contains($0) })
        dismiss()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
    }
    .onAppear { selection = Set(store.languages) }
  }
}
