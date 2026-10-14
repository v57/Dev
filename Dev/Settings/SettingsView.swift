//
//  SettingsView.swift
//  Dev
//

import SwiftUI

/// The app's Settings window (⌘,): General, Translation, Agents (the MCP
/// server) and Advanced (the imported translation database and clearing the
/// translation store).
struct SettingsView: View {
  @AppStorage("settings.tab") private var tab = "translation"

  var body: some View {
    TabView(selection: $tab) {
      GeneralSettingsView()
        .tabItem { Label("General", systemImage: "gearshape") }
        .tag("general")
      TranslationSettingsView()
        .tabItem { Label("Translation", systemImage: "globe") }
        .tag("translation")
      AgentsSettingsView()
        .tabItem { Label("Agents", systemImage: "powerplug") }
        .tag("agents")
      AdvancedSettingsView()
        .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        .tag("advanced")
    }
    .frame(width: 600)
  }
}

/// Where projects open and what the sidebar shows.
struct GeneralSettingsView: View {
  @AppStorage(ProjectOpener.key) private var openIn = ProjectOpener.Target.xcode.rawValue
  @AppStorage(SidebarPreferences.showReviewBadge) private var showsReviewBadge = true
  @AppStorage(SidebarPreferences.offerNonGitFolders) private var offersFolders = true

  var body: some View {
    Form {
      Picker("Open projects in", selection: $openIn) {
        ForEach(ProjectOpener.Target.allCases) { Text($0.title).tag($0.rawValue) }
      }
      Toggle("Show strings to review in the sidebar", isOn: $showsReviewBadge)
      Toggle(isOn: $offersFolders) {
        Text("Offer folders without git when adding a folder of repos")
        Text("Folders that look like projects are ticked for you.")
      }
    }
    .formStyle(.grouped)
    .frame(minHeight: 220)
  }
}

/// The imported translation database and the translation store.
struct AdvancedSettingsView: View {
  var body: some View {
    let db = ImportedTranslationDB.shared
    Form {
      Section("Imported Translation Database") {
        HStack {
          if let url = db.fileURL {
            VStack(alignment: .leading, spacing: 2) {
              Text(url.lastPathComponent)
              Text(url.deletingLastPathComponent().path(percentEncoded: false)
                .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } else {
            Text("None").foregroundStyle(.secondary)
          }
          Spacer()
          Button(db.isImported ? "Replace…" : "Choose…") { Task { await db.importViaPanel() } }
            .disabled(AppContext.shared.shell?.isRunning == true)
          if db.isImported {
            Button("Remove", role: .destructive) { db.remove() }
              .disabled(AppContext.shared.shell?.isRunning == true)
          }
        }
        Text("Translations a database already holds are used before a model is asked.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Section("Translation Store") {
        ClearTranslationStoreSection()
      }
    }
    .formStyle(.grouped)
    .frame(minHeight: 320)
    .task { db.restoreIfNeeded() }
  }
}

/// The keys the General tab writes and the sidebar reads.
enum SidebarPreferences {
  static let showReviewBadge = "general.showReviewBadge"
  static let offerNonGitFolders = "general.offerNonGitFolders"
}

/// Which model translation runs on. Users bring their own key: pick a provider,
/// paste its key (kept in the login keychain), pick a model.
struct TranslationSettingsView: View {
  @State private var model = ModelSettingsModel()

  var body: some View {
    @Bindable var model = model
    Form {
      Section {
        Picker("Provider", selection: $model.providerID) {
          Text("Choose…").tag("")
          ForEach(ProviderPreset.Group.allCases, id: \.self) { group in
            Section(group.rawValue) {
              ForEach(ProviderPreset.all.filter { $0.group == group }) { preset in
                Text(preset.name).tag(preset.id)
              }
            }
          }
        }
        if let preset = model.preset {
          if let note = preset.note {
            Text(note)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          if preset.asksForBaseURL {
            TextField("Base URL", text: $model.baseURL, prompt: Text(preset.baseURL.isEmpty
              ? "https://example.com/v1" : preset.baseURL))
          }
          if preset.id == ProviderPreset.custom.id {
            Picker("API", selection: $model.wire) {
              Text("Chat Completions").tag(Wire.chatCompletions)
              Text("Responses").tag(Wire.responses)
            }
          }
        }
      }

      if let preset = model.preset {
        keySection(preset)
        modelSection(preset)
        Section {
          HStack {
            Button("Test") { Task { await model.test() } }
              .disabled(model.isTesting)
            if model.isTesting { ProgressView().controlSize(.small) }
            if let result = model.testResult {
              Label(result.message, systemImage: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(result.succeeded ? .green : .red)
                .lineLimit(2)
                .textSelection(.enabled)
            } else if let problem = model.problem {
              Text(problem).foregroundStyle(.secondary)
            }
          }
        }
      }

      Section {
        HStack {
          Text("Keys you already use for other tools can be imported from the environment or from Hermes.")
            .font(.callout)
            .foregroundStyle(.secondary)
          Spacer()
          if let status = model.importStatus {
            Text(status).font(.callout).foregroundStyle(.secondary)
          }
          Button("Import Keys…") { model.findImportableKeys() }
        }
      }
    }
    .formStyle(.grouped)
    .frame(minHeight: 520)
    .sheet(isPresented: Binding(
      get: { !model.importCandidates.isEmpty },
      set: { if !$0 { model.importCandidates = [] } }
    )) {
      ImportKeysSheet(model: model)
    }
  }

  @ViewBuilder
  private func keySection(_ preset: ProviderPreset) -> some View {
    Section("API Key") {
      HStack {
        SecureField("API key", text: $model.keyDraft, prompt: Text(preset.needsKey ? "Paste your key" : "Optional"))
          .onSubmit { model.saveKey() }
        Button("Save") { model.saveKey() }
          .disabled(model.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      HStack {
        switch model.keyState {
        case .stored:
          Label("Saved in your keychain", systemImage: "key.fill")
            .foregroundStyle(.secondary)
          Spacer()
          Button("Remove", role: .destructive) { model.removeKey() }
        case .environment(let name):
          Label("Read from $\(name)", systemImage: "terminal")
            .foregroundStyle(.secondary)
        case .missing:
          Label("No key yet", systemImage: "key")
            .foregroundStyle(.secondary)
        case .notNeeded:
          Label("This server needs no key", systemImage: "checkmark")
            .foregroundStyle(.secondary)
        }
        if let url = preset.keysURL.flatMap(URL.init(string:)) {
          Spacer()
          Link(preset.needsKey ? "Get a key" : "Download", destination: url)
        }
      }
      .font(.callout)
    }
  }

  @ViewBuilder
  private func modelSection(_ preset: ProviderPreset) -> some View {
    Section("Model") {
      HStack {
        TextField("Model", text: $model.model, prompt: Text("model id"))
        if !model.availableModels.isEmpty {
          Menu("Available") {
            ForEach(model.availableModels, id: \.self) { id in
              Button(id) { model.model = id }
            }
          }
          .fixedSize()
        }
        Button("Fetch Models") { Task { await model.fetchModels() } }
          .disabled(model.isFetchingModels)
      }
      if let error = model.fetchError {
        Text(error).font(.callout).foregroundStyle(.red)
      }
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
          .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(recommendation.model).font(.body.monospaced())
            Text(recommendation.role.rawValue)
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(roleColor.opacity(0.18), in: Capsule())
              .foregroundStyle(roleColor)
          }
          Text([recommendation.reason, recommendation.priceLabel].compactMap { $0 }.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var roleColor: Color {
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
          .keyboardShortcut(.cancelAction)
        Button("Import") { model.importKeys() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 400)
  }
}
