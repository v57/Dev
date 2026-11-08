//
//  StoreSheets.swift
//  Dev
//

import ComponentKit
import DevDesktop
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import and Publish

/// Import… and Publish…: picks a service and reads it only when asked. Import lists what it would write and keeps what
/// the reader leaves ticked. Publish lists what would change against what's live and sends after a confirmation.
struct StoreSyncSheet: View {
  enum Mode: Equatable {
    case importing, publishing
    var title: String { self == .importing ? String(localized: "Import") : String(localized: "Publish") }
  }

  let root: URL
  let mode: Mode
  let version: String?
  let destinations: [StoreDestination]

  @Environment(\.kitDismiss) private var dismiss
  @State private var destination: StoreDestination = .appStore
  @State private var isWorking = false
  @State private var error: String?
  @State private var live: StoreLive?
  @State private var plan = StorePublishPlan()
  @State private var items: [StoreImportItem] = []
  @State private var skippedItems: Set<String> = []
  @State private var lines: [String] = []
  @State private var isDone = false
  @State private var confirming = false

  private var texts: StoreTexts { StoreTexts(root: root) }
  private var config: ReleaseConfig? { ReleaseConfig.load(from: root) }
  /// The vault account the project belongs to, whose GitHub sign-in it uses (as its release runs do).
  private var accountID: String { VaultProjects.shared.account(of: root) }
  private var missing: String? { StoreCredentials.missing(destination, config: config, accountID: accountID) }

  private var meta: LocalizedStringKey {
    switch mode {
    case .importing:
      "Reads what \(destination.title) has now, once. Text that differs from your base text becomes this destination's override. Nothing changes until you press Import."
    case .publishing:
      "Compares your text with what \(destination.title) has now. Nothing is sent until you confirm, and a field empty here is left alone there."
    }
  }

  var body: some View {
    KitSheet(
      title: mode == .importing ? "Import · \(destination.title)" : "Publish · \(destination.title)", meta: meta,
      systemImage: mode == .importing ? "square.and.arrow.down" : "paperplane", width: 620
    ) {
      FormCard {
        GroupRow("Service", help: live.map { "\($0.summary)" }) {
          KitPicker("Service", selection: $destination, options: destinations.map { ("\($0.title)", $0) })
        }
        if let version, mode == .publishing {
          GroupRow("Version", help: "The changelog and message to testers of this version") {
            Text(version).foregroundStyle(.kitSecondary)
          }
        }
        if let missing {
          FormRow("\(missing)", help: "Store Text ▸ Setup holds the keys.", systemImage: "key", hue: .orange)
        }
      }
      if live != nil {
        if mode == .importing { importList } else { publishList }
      }
      if !lines.isEmpty {
        ScrollView {
          Text(lines.joined(separator: "\n"))
            .kitFont(.monoSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(height: 90)
        .kitSurface(.card, cornerRadius: KitMetrics.radiusCard)
      }
    } footer: {
      if let error {
        SheetStatus(error, systemImage: "exclamationmark.triangle", status: .failed)
      } else if isWorking {
        SheetStatus(live == nil ? "Reading…" : "Sending…", systemImage: "arrow.triangle.2.circlepath", status: .working)
      } else if isDone {
        SheetStatus(mode == .importing ? "Imported" : "Published", systemImage: "checkmark", status: .done)
      }
      Button(isDone ? "Done" : "Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      if !isDone {
        if live == nil {
          Button("Read from \(destination.shortTitle)") { Task { await read() } }
            .buttonStyle(.kitPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking || missing != nil)
        } else if mode == .importing {
          Button("Import \(chosen.count)") { applyImport() }
            .buttonStyle(.kitPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking || chosen.isEmpty)
        } else {
          Button("Publish \(plan.changes.count)…") { confirming = true }
            .buttonStyle(.kitPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking || plan.changes.isEmpty || !plan.overLimit.isEmpty)
        }
      }
    }
    .onAppear { destination = destinations.first ?? .appStore }
    .onChange(of: destination) {
      live = nil
      error = nil
      lines = []
      isDone = false
    }
    .kitConfirmation(
      "Send \(plan.changes.count) changes to \(destination.title)?", isPresented: $confirming,
      message: confirmationMessage, systemImage: "paperplane", confirm: "Send", role: nil
    ) {
      Task { await publish() }
    }
  }

  private var confirmationMessage: LocalizedStringKey {
    switch destination {
    case .appStore: "This changes the text in App Store Connect. It doesn't submit anything for review."
    case .github: "This changes the repository page and release notes on GitHub, where anyone can read them."
    case .googlePlay: "This commits an edit on Google Play, which can start a review. It stops if one is already under way."
    case .microsoftStore: "This saves the text on a draft submission. You send it for certification in Partner Center."
    }
  }

  // MARK: Lists

  private var chosen: [StoreImportItem] { items.filter { !skippedItems.contains($0.id) } }

  @ViewBuilder
  private var importList: some View {
    FormCard("What it would write") {
      if items.isEmpty {
        GroupRow("Nothing new", help: "Everything \(destination.title) has is already here.")
      }
      ForEach(items) { item in
        GroupRow(item.title, help: item.value.count > 160 ? String(item.value.prefix(160)) + "…" : item.value) {
          Toggle(
            item.title,
            isOn: Binding(
              get: { !skippedItems.contains(item.id) },
              set: { if $0 { skippedItems.remove(item.id) } else { skippedItems.insert(item.id) } })
          )
          .labelsHidden()
          .toggleStyle(.kitSwitch)
        }
      }
    }
    .controlSize(.small)
  }

  @ViewBuilder
  private var publishList: some View {
    if !plan.overLimit.isEmpty {
      FormCard("Over the limit") {
        ForEach(plan.overLimit, id: \.self) { line in
          FormRow("\(line)", help: "Shorten it to publish.", systemImage: "exclamationmark.triangle", hue: .red)
        }
      }
      .controlSize(.small)
    }
    FormCard("What would change") {
      if plan.changes.isEmpty {
        GroupRow("Nothing to send", help: "\(destination.title) already says what you have here.")
      }
      ForEach(plan.changes) { change in
        VStack(alignment: .leading, spacing: 6) {
          Text(change.title + (change.locale.map { " · \($0)" } ?? "")).fontWeight(.semibold)
          if let old = change.old {
            Text(old).lineLimit(6).strikethrough().foregroundStyle(.kitSecondary).kitFont(.callout)
          } else {
            Text("Empty there now").foregroundStyle(.kitTertiary).kitFont(.callout)
          }
          Text(change.new).lineLimit(6).kitFont(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
      }
    }
    .controlSize(.small)
    if !plan.skipped.isEmpty || !plan.manual.isEmpty {
      FormCard("Not sent") {
        ForEach(plan.skipped, id: \.self) { GroupRow($0) }
        ForEach(plan.manual) { slot in
          GroupRow("\(slot.title)", help: "\(destination.title)'s API can't set this: copy it across.") {
            KitCopyButton(value: texts.resolved(slot.field, destination: destination, version: version).text)
          }
        }
      }
      .controlSize(.small)
    }
  }

  // MARK: Actions

  private func read() async {
    isWorking = true
    error = nil
    defer { isWorking = false }
    do {
      let service = try await StoreCredentials.service(destination, root: root, config: config, accountID: accountID)
      // An import takes the service's newest version; a publish compares with the one open here.
      var live = try await service.fetch(version: mode == .importing ? nil : version)
      if live.version == nil { live.version = version }
      if mode == .importing {
        items = texts.importPlan(destination: destination, live: live)
      } else {
        plan = texts.publishPlan(destination: destination, live: live, version: version)
      }
      self.live = live
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func applyImport() {
    do {
      try texts.apply(chosen)
      lines.append("Wrote \(chosen.count) texts to \(StoreTexts.path).")
      isDone = true
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func publish() async {
    isWorking = true
    error = nil
    defer { isWorking = false }
    do {
      let service = try await StoreCredentials.service(destination, root: root, config: config, accountID: accountID)
      let changes = plan.changes
      try await service.publish(changes, version: version) { line in
        Task { @MainActor in lines.append(line) }
      }
      try texts.markPublished(changes, destination: destination, version: version)
      isDone = true
    } catch {
      self.error = error.localizedDescription
    }
  }
}

// MARK: - New version

/// New Version…: names the version and starts its changelog from `git log` as a draft to edit. It stays private until
/// the reader marks it ready or publishes it. Optionally sets the Xcode project's `MARKETING_VERSION` too, through
/// `release.sh bump`.
struct StoreNewVersionSheet: View {
  let root: URL
  let onCreate: (String) -> Void

  @Environment(\.kitDismiss) private var dismiss
  @State private var version = ""
  @State private var changelog = ""
  @State private var error: String?
  @State private var setsProject = false
  @State private var isWorking = false

  private var hasProject: Bool {
    DevCapabilities.xcode && ReleaseRunner.scriptURL != nil && !(ReleaseConfig.load(from: root)?["PROJECT"] ?? "").isEmpty
  }

  var body: some View {
    KitSheet(
      title: "New Version", meta: "The commits since the last tag start its changelog. Edit them: it's a draft, kept out of git.",
      systemImage: "number", width: 620
    ) {
      FormCard {
        GroupRow("Version") {
          TextField("Version", text: $version, prompt: Text("1.2.0"))
            .labelsHidden()
            .kitField()
            .frame(width: 140)
        }
        if hasProject {
          GroupRow("Set the project's version", help: "Writes MARKETING_VERSION in the Xcode project, for you to commit.") {
            Toggle("Set the project's version", isOn: $setsProject).labelsHidden().toggleStyle(.kitSwitch)
          }
        }
      }
      TextEditor(text: $changelog)
        .kitFont(.body)
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(height: 240)
        .kitSurface(.card, cornerRadius: KitMetrics.radiusCard)
        .accessibilityLabel("Changelog")
    } footer: {
      if let error { SheetStatus(error, systemImage: "exclamationmark.triangle", status: .failed) }
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Create") { Task { await create() } }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(version.isEmpty || isWorking)
    }
    .task {
      let texts = StoreTexts(root: root)
      // One after the other: corelibs' Process can hang when launched in parallel.
      let next = await texts.suggestedVersion()
      let log = await texts.changelogDraft()
      if version.isEmpty { version = next }
      if changelog.isEmpty { changelog = log }
    }
  }

  private func create() async {
    isWorking = true
    defer { isWorking = false }
    let texts = StoreTexts(root: root)
    let clean = version.trimmingCharacters(in: .whitespaces)
    do {
      let address = StoreAddress(field: .changelog, version: clean)
      guard texts.entry(address) == nil else { throw StoreTextError("Version \(clean) already has a changelog.") }
      try texts.write(changelog.isEmpty ? "- " : changelog, at: address)
      if setsProject, let script = ReleaseRunner.scriptURL {
        let result = await LineProcess.run(
          "/bin/bash", [script.path, "--project", root.path, "--version", clean, "bump"], directory: root)
        guard result.status == 0 else { throw StoreTextError(result.output.split(separator: "\n").last.map(String.init) ?? "release.sh bump failed.") }
      }
      onCreate(clean)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

// MARK: - Setup

/// Setup: the languages and destinations a project uses, and the keys Import and Publish need. The keys go where the
/// other release keys live (release.env names a key file, the keychain holds a secret), never in `.dev/store/`.
struct StoreSetupSheet: View {
  let root: URL

  @Environment(\.kitDismiss) private var dismiss
  @State private var settings = StoreSettings()
  @State private var newLocale = ""
  @State private var config: ReleaseConfig?
  @State private var savedConfig: ReleaseConfig?
  @State private var secret = ""
  @State private var error: String?
  @State private var choosingPlayKey = false

  var body: some View {
    KitSheet(
      title: "Store Text Setup", meta: "Works with no accounts and no network. The keys below are only for Import and Publish.",
      systemImage: "gearshape", width: 560
    ) {
      FormCard("Languages") {
        GroupRow("Base language", help: "The one you write in; Translate fills the others") {
          TextField("Base language", text: $settings.baseLocale)
            .labelsHidden().kitField().frame(width: 120)
        }
        ForEach(settings.locales, id: \.self) { locale in
          GroupRow(Locale.current.localizedString(forIdentifier: locale) ?? locale, help: locale) {
            Button("Remove") { settings.locales.removeAll { $0 == locale } }.buttonStyle(.kit)
          }
        }
        GroupRow("Add a language", help: "A code such as de-DE or ja") {
          HStack(spacing: 8) {
            TextField("Add a language", text: $newLocale, prompt: Text("de-DE"))
              .labelsHidden().kitField().frame(width: 120)
            Button("Add") { addLocale() }.buttonStyle(.kit).disabled(newLocale.isEmpty)
          }
        }
      }
      .controlSize(.small)
      FormCard("Destinations") {
        ForEach(StoreDestination.allCases) { destination in
          GroupRow(destination.title) {
            Toggle(destination.title, isOn: binding(destination)).labelsHidden().toggleStyle(.kitSwitch)
          }
        }
        GroupRow("Bundle ID", help: "How App Store Connect and Google Play know the app; empty asks the Xcode scheme") {
          TextField(
            "Bundle ID", text: Binding(get: { settings.bundleID ?? "" }, set: { settings.bundleID = $0.isEmpty ? nil : $0 }),
            prompt: Text("dev.v57.app")
          )
          .labelsHidden().kitField().frame(width: 220)
        }
      }
      .controlSize(.small)
      if config == nil {
        FormCard {
          FormRow(
            "No release.env", help: "Set it up in Workflows ▸ Release Settings to add keys for Import and Publish.",
            systemImage: "exclamationmark.triangle", hue: .orange)
        }
      } else {
        keys
      }
    } footer: {
      if let error { SheetStatus(error, systemImage: "exclamationmark.triangle", status: .failed) }
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Save") { save() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
    .task {
      let texts = StoreTexts(root: root)
      settings = texts.settings()
      config = ReleaseConfig.load(from: root)
      savedConfig = config
    }
  }

  @ViewBuilder
  private var keys: some View {
    FormCard("App Store Connect") {
      AppStoreConnectKeyFields(config: configBinding, offersNotary: false)
    }
    .controlSize(.small)
    FormCard("GitHub") {
      GroupRow("Repository", help: "Uses your GitHub sign-in from Settings") {
        keyField("Repository", "GITHUB_REPO", "owner/name")
      }
    }
    .controlSize(.small)
    FormCard("Google Play") {
      GroupRow(
        "Service account key",
        help: (config?["GOOGLE_PLAY_KEY_PATH"] ?? "").isEmpty ? "None" : "\(config?["GOOGLE_PLAY_KEY_PATH"] ?? "")"
      ) {
        Button("Choose…") { choosingPlayKey = true }
          .buttonStyle(.kit)
          .fileImporter(isPresented: $choosingPlayKey, allowedContentTypes: [UTType(filenameExtension: "json") ?? .data]) { result in
            if case .success(let url) = result { config?["GOOGLE_PLAY_KEY_PATH"] = url.path }
          }
      }
      GroupRow("Package", help: "Empty uses the bundle ID") { keyField("Package", "GOOGLE_PLAY_PACKAGE", "dev.v57.app") }
      GroupRow("Test track", help: "Where the message to testers goes") { keyField("Test track", "GOOGLE_PLAY_TRACK", "internal") }
    }
    .controlSize(.small)
    FormCard("Microsoft Store") {
      GroupRow("Store ID") { keyField("Store ID", "MS_STORE_APP_ID", "9NBLGGH…") }
      GroupRow("Tenant ID") { keyField("Tenant ID", "MS_STORE_TENANT_ID", "") }
      GroupRow("Client ID") { keyField("Client ID", "MS_STORE_CLIENT_ID", "") }
      GroupRow("Client secret", help: StoreCredentials.microsoftSecret() == nil ? "Kept in the keychain" : "Saved in the keychain") {
        SecureField("Client secret", text: $secret).labelsHidden().kitField().frame(width: 220)
      }
    }
    .controlSize(.small)
  }

  private var configBinding: Binding<ReleaseConfig> {
    Binding(get: { config ?? ReleaseConfig() }, set: { config = $0 })
  }

  private func keyField(_ title: String, _ key: String, _ prompt: String) -> some View {
    TextField(
      title,
      text: Binding(get: { config?[key] ?? "" }, set: { config?[key] = $0.trimmingCharacters(in: .whitespaces) }),
      prompt: Text(prompt)
    )
    .labelsHidden()
    .kitField()
    .frame(width: 220)
  }

  private func binding(_ destination: StoreDestination) -> Binding<Bool> {
    Binding(
      get: { settings.used.contains(destination) },
      set: { isOn in
        var used = settings.used
        if isOn, !used.contains(destination) { used.append(destination) }
        if !isOn { used.removeAll { $0 == destination } }
        // Keep them in the one order, and never none: empty means all of them.
        settings.destinations = StoreDestination.allCases.filter { used.contains($0) }
      })
  }

  private func addLocale() {
    let code = newLocale.trimmingCharacters(in: .whitespaces)
    do {
      try StoreTexts.check(code, "locale")
      if code != settings.baseLocale, !settings.locales.contains(code) { settings.locales.append(code) }
      newLocale = ""
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func save() {
    do {
      if !newLocale.isEmpty { addLocale() }
      try StoreTexts(root: root).save(settings)
      if let config, config != savedConfig { try config.save(to: root) }
      if !secret.isEmpty { StoreCredentials.saveMicrosoftSecret(secret) }
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
