//
//  SettingsView.swift
//  Dev
//

import ComponentKit
import SwiftUI

/// The app's Settings window (⌘,): General, Translation, Agents (the MCP
/// server) and Advanced (the imported translation database and clearing the
/// translation store).
struct SettingsView: View {
  @AppStorage("settings.tab") private var tab = "translation"

  var body: some View {
    KitSettings(selection: $tab, window: .hiddenTitleBar) {
      SettingsPane("General", systemImage: "gearshape", id: "general") { GeneralSettingsView() }
      SettingsPane("Translation", systemImage: "globe", hue: .blue, id: "translation") { TranslationSettingsView() }
      SettingsPane("Agents", systemImage: "powerplug", id: "agents") { AgentsSettingsView() }
      SettingsPane("Advanced", systemImage: "slider.horizontal.3", id: "advanced") { AdvancedSettingsView() }
    }
    .frame(width: 640, height: 560)
    .toolbar(removing: .title)
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
  }
}

/// Where projects open and what the sidebar shows.
struct GeneralSettingsView: View {
  @AppStorage(ProjectOpener.key) private var openIn = ProjectOpener.Target.xcode.rawValue
  @AppStorage(SidebarPreferences.showReviewBadge) private var showsReviewBadge = true
  @AppStorage(SidebarPreferences.offerNonGitFolders) private var offersFolders = true
  @AppStorage(SidebarPreferences.onlyXcodeProjects) private var onlyXcodeProjects = true

  var body: some View {
    FormCard {
      FormRow("Open projects in", systemImage: "arrow.up.forward.app", hue: .blue) {
        KitPicker("Open projects in", selection: $openIn, options: ProjectOpener.Target.allCases.map { ($0.title, $0.rawValue) })
      }
      FormRow("Show strings to review in the sidebar", systemImage: "text.badge.checkmark", hue: .orange) {
        Toggle("Show strings to review in the sidebar", isOn: $showsReviewBadge)
          .labelsHidden().toggleStyle(.kitSwitch)
      }
      FormRow(
        "Show only Xcode projects",
        help: "Folders without an .xcodeproj stay in the other v57 apps.", systemImage: "hammer", hue: .blue
      ) {
        Toggle("Show only Xcode projects", isOn: $onlyXcodeProjects).labelsHidden().toggleStyle(.kitSwitch)
      }
      FormRow(
        "Offer folders without git when adding a folder of repos",
        help: "Folders that look like projects are ticked for you.", systemImage: "folder.badge.plus", hue: .gray
      ) {
        Toggle("Offer folders without git", isOn: $offersFolders).labelsHidden().toggleStyle(.kitSwitch)
      }
    }
  }
}

/// The imported translation database and the translation store.
struct AdvancedSettingsView: View {
  var body: some View {
    let db = ImportedTranslationDB.shared
    let isRunning = AppContext.shared.shell?.isRunning == true
    VStack(alignment: .leading, spacing: 18) {
      FormCard(
        "Imported Translation Database",
        footer: "Translations a database already holds are used before a model is asked."
      ) {
        FormRow(
          db.fileURL?.lastPathComponent ?? "None",
          help: db.fileURL.map {
            $0.deletingLastPathComponent().path(percentEncoded: false)
              .replacingOccurrences(of: NSHomeDirectory(), with: "~")
          },
          systemImage: "cylinder.split.1x2", hue: db.isImported ? .green : .gray
        ) {
          HStack(spacing: 6) {
            Button(db.isImported ? "Replace…" : "Choose…") { Task { await db.importViaPanel() } }
            if db.isImported {
              Button("Remove", role: .destructive) { db.remove() }
            }
          }
          .buttonStyle(.kit)
          .disabled(isRunning)
        }
      }
      FormCard("Translation Store") {
        ClearTranslationStoreSection()
      }
    }
    .task { db.restoreIfNeeded() }
  }
}

/// The keys the General tab writes and the sidebar reads.
enum SidebarPreferences {
  static let showReviewBadge = "general.showReviewBadge"
  static let offerNonGitFolders = "general.offerNonGitFolders"
  static let onlyXcodeProjects = "general.onlyXcodeProjects"
}

/// Which model translation runs on. Users bring their own key: pick a provider,
/// paste its key (kept in the login keychain), pick a model.
struct TranslationSettingsView: View {
  @State private var model = ModelSettingsModel()

  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 18) {
      FormCard {
        FormRow("Provider", help: model.preset?.note, systemImage: "globe", hue: .blue) {
          KitPicker("Provider", selection: $model.providerID, sections: providerSections)
        }
        if let preset = model.preset {
          if preset.asksForBaseURL {
            FormRow("Base URL", systemImage: "link", hue: .gray, field: TextField(
              "Base URL", text: $model.baseURL,
              prompt: Text(preset.baseURL.isEmpty ? "https://example.com/v1" : preset.baseURL)))
          }
          if preset.id == ProviderPreset.custom.id {
            FormRow("API", systemImage: "point.3.connected.trianglepath.dotted", hue: .gray) {
              KitPicker("API", selection: $model.wire, options: [("Chat Completions", Wire.chatCompletions), ("Responses", Wire.responses)])
            }
          }
        }
      }

      if let preset = model.preset {
        keySection(preset)
        modelSection(preset)
        FormCard {
          FormRow(
            "Test", help: model.testResult?.message ?? model.problem,
            systemImage: model.testResult.map { $0.succeeded ? "checkmark" : "xmark" } ?? "bolt",
            hue: model.testResult.map { $0.succeeded ? .green : .red } ?? .gray
          ) {
            Button("Test") { Task { await model.test() } }
              .buttonStyle(.kit)
              .status(model.isTesting ? .working : .idle)
              .disabled(model.isTesting)
          }
          .textSelection(.enabled)
        }
      }

      FormCard {
        FormRow(
          "Keys you already use for other tools can be imported from the environment or from Hermes.",
          help: model.importStatus, systemImage: "key", hue: .orange
        ) {
          Button("Import Keys…") { model.findImportableKeys() }.buttonStyle(.kit)
        }
      }
    }
    .sheet(isPresented: Binding(
      get: { !model.importCandidates.isEmpty },
      set: { if !$0 { model.importCandidates = [] } }
    )) {
      ImportKeysSheet(model: model)
    }
  }

  @ViewBuilder
  private func keySection(_ preset: ProviderPreset) -> some View {
    FormCard("API Key") {
      FormRow("API key", help: keyStateText, systemImage: "key.fill", hue: .orange, field: HStack {
        SecureField("API key", text: $model.keyDraft, prompt: Text(preset.needsKey ? "Paste your key" : "Optional"))
          .onSubmit { model.saveKey() }
        Button("Save") { model.saveKey() }
          .buttonStyle(.kitPlain)
          .disabled(model.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
      })
      if case .stored = model.keyState {
        FormRow("Remove the saved key", systemImage: "trash", hue: .red) {
          Button("Remove", role: .destructive) { model.removeKey() }.buttonStyle(.kit)
        }
      }
      if let url = preset.keysURL.flatMap(URL.init(string:)) {
        FormRow(preset.needsKey ? "Get a key" : "Download", systemImage: "arrow.up.right.square", hue: .blue) {
          Link(preset.needsKey ? "Open" : "Download", destination: url)
        }
      }
    }
  }

  private var keyStateText: String {
    switch model.keyState {
    case .stored: "Saved in your keychain"
    case .environment(let name): "Read from $\(name)"
    case .missing: "No key yet"
    case .notNeeded: "This server needs no key"
    }
  }

  /// "Choose…" on its own, then the presets under their groups (Recommended, Popular, …).
  private var providerSections: [(String, [KitSegment<String>])] {
    [("", [KitSegment("Choose…", value: "")])]
      + ProviderPreset.Group.allCases.map { group in
        (group.rawValue, ProviderPreset.all.filter { $0.group == group }.map { KitSegment($0.name, value: $0.id) })
      }
  }

  @ViewBuilder
  private func modelSection(_ preset: ProviderPreset) -> some View {
    FormCard("Model") {
      FormRow("Model", systemImage: "cpu", hue: .purple, error: model.fetchError,
              field: HStack {
        TextField("Model", text: $model.model, prompt: Text("model id"))
        if !model.availableModels.isEmpty {
          KitMenuButton("Available") {
            KitMenuOptions(selection: $model.model, options: model.availableModels.map { ($0, $0) })
          }
        }
        Button("Fetch Models") { Task { await model.fetchModels() } }
          .buttonStyle(.kitPlain)
          .disabled(model.isFetchingModels)
      })
      ForEach(preset.recommendations) { recommendation in
        RecommendationRow(recommendation: recommendation, isSelected: model.model == recommendation.model) {
          model.model = recommendation.model
        }
      }
    }
  }
}

/// One recommended model: role, id, price and why.
private struct RecommendationRow: View {
  let recommendation: ModelRecommendation
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? AnyShapeStyle(Hue.accent.fill) : AnyShapeStyle(.kitTertiary))
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(recommendation.model).kitFont(.mono)
            Chip(recommendation.role.rawValue, hue: roleHue).controlSize(.small)
          }
          Text([recommendation.reason, recommendation.priceLabel].compactMap { $0 }.joined(separator: " · "))
            .kitFont(.caption)
        }
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var roleHue: Hue {
    switch recommendation.role {
    case .best: return .purple
    case .value: return .blue
    case .free: return .green
    }
  }
}

/// Confirms which found keys go into the keychain. The values are never shown.
private struct ImportKeysSheet: View {
  let model: ModelSettingsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Import \(model.importCandidates.count == 1 ? "this key" : "these keys")?")
        .font(.headline)
      Text("Each key is copied into your login keychain for Dev.")
        .foregroundStyle(.secondary)
      ForEach(model.importCandidates) { candidate in
        VStack(alignment: .leading, spacing: 2) {
          Text(candidate.providerName)
          Text("from \(candidate.source)").font(.caption).foregroundStyle(.secondary)
        }
      }
      HStack {
        Spacer()
        Button("Cancel") { model.importCandidates = [] }
          .buttonStyle(.kit)
          .keyboardShortcut(.cancelAction)
        Button("Import") { model.importKeys() }
          .buttonStyle(.kitPrimary)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 400)
  }
}
