//
//  ModelSettingsModel.swift
//  Dev
//

import Foundation
import Observation

/// The Settings pane's state for the translation model. Writes go straight to
/// `ModelSettings`' storage (UserDefaults and the keychain), so the next call
/// reads them; this type only holds what the form shows.
@Observable
final class ModelSettingsModel {
  var providerID: String {
    didSet {
      guard providerID != oldValue else { return }
      defaults.set(providerID, forKey: ModelSettings.Key.provider)
      // A model or URL typed for one provider means nothing to the next.
      // The value pick first: a good translation per dollar is the safe default.
      let picks = preset?.recommendations ?? []
      model = (picks.first { $0.role == .value } ?? picks.first)?.model ?? ""
      baseURL = ""
      availableModels = []
      testResult = nil
      refreshKeyState()
    }
  }
  var model: String {
    didSet { defaults.set(model, forKey: ModelSettings.Key.model) }
  }
  var baseURL: String {
    didSet { defaults.set(baseURL, forKey: ModelSettings.Key.baseURL) }
  }
  var wire: Wire {
    didSet { defaults.set(wire.rawValue, forKey: ModelSettings.Key.wire) }
  }

  /// The key being typed; cleared once saved.
  var keyDraft = ""
  /// Where the current provider's key comes from, for the status line.
  private(set) var keyState: KeyState = .missing

  enum KeyState: Equatable {
    case stored
    case environment(String)
    case missing
    case notNeeded
  }

  /// Models the provider listed, after "Fetch Models".
  private(set) var availableModels: [String] = []
  private(set) var isFetchingModels = false
  private(set) var fetchError: String?

  private(set) var isTesting = false
  private(set) var testResult: TestResult?

  struct TestResult: Equatable {
    let succeeded: Bool
    let message: String
  }

  /// Keys found by "Import Keys", waiting for the reader's confirmation.
  var importCandidates: [ImportCandidate] = []
  /// What the last import found when there was nothing to confirm.
  private(set) var importStatus: String?

  struct ImportCandidate: Identifiable, Equatable {
    let presetID: String
    let providerName: String
    let source: String
    let key: String
    var id: String { presetID }
  }

  private let defaults = UserDefaults.standard

  init() {
    providerID = ModelSettings.providerID ?? ""
    model = ModelSettings.model ?? ""
    baseURL = ModelSettings.baseURL ?? ""
    wire = ModelSettings.wire ?? .chatCompletions
    refreshKeyState()
  }

  var preset: ProviderPreset? { ProviderPreset.preset(id: providerID) }

  /// The problem a run would report right now, or nil when it can go.
  var problem: String? { ModelSettings.problem }

  // MARK: - key

  func saveKey() {
    guard let preset else { return }
    ProviderKeychain.save(keyDraft, account: preset.id)
    keyDraft = ""
    testResult = nil
    refreshKeyState()
  }

  func removeKey() {
    guard let preset else { return }
    ProviderKeychain.delete(account: preset.id)
    refreshKeyState()
  }

  func refreshKeyState() {
    guard let preset else { keyState = .missing; return }
    if ProviderKeychain.hasStoredKey(for: preset) {
      keyState = .stored
    } else if let name = preset.keyNames.first(where: {
      !(ProcessInfo.processInfo.environment[$0] ?? "").isEmpty
    }) {
      keyState = .environment(name)
    } else {
      keyState = preset.needsKey ? .missing : .notNeeded
    }
  }

  // MARK: - import

  /// Looks for keys in the environment and in Hermes' `.env`; the reader confirms
  /// before anything is written.
  func findImportableKeys() {
    importCandidates = ProviderKeychain.importable().map {
      ImportCandidate(
        presetID: $0.preset.id, providerName: $0.preset.name, source: $0.source, key: $0.key)
    }
    importStatus = importCandidates.isEmpty ? "No new keys found." : nil
  }

  func importKeys() {
    for candidate in importCandidates {
      ProviderKeychain.save(candidate.key, account: candidate.presetID)
    }
    if providerID.isEmpty, let first = importCandidates.first {
      providerID = first.presetID
    }
    importStatus = "Imported \(importCandidates.count) \(importCandidates.count == 1 ? "key" : "keys")."
    importCandidates = []
    refreshKeyState()
  }

  // MARK: - models

  /// Asks the provider for its model list (`GET <base>/models`).
  func fetchModels() async {
    guard let preset else { return }
    let root = baseURL.isEmpty ? preset.baseURL : baseURL
    guard let url = URL(string: root)?.appendingPathComponent("models") else { return }
    isFetchingModels = true
    fetchError = nil
    defer { isFetchingModels = false }
    var request = URLRequest(url: url, timeoutInterval: 20)
    if let key = ProviderKeychain.key(for: preset) {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    request.setValue(RoutedModel.userAgent, forHTTPHeaderField: "User-Agent")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(status) else {
        fetchError = "The provider answered \(status)."
        return
      }
      availableModels = Self.modelIDs(in: data)
      if availableModels.isEmpty { fetchError = "The provider listed no models." }
    } catch {
      fetchError = error.localizedDescription
    }
  }

  /// Ids from an OpenAI-style `{"data": [{"id": …}]}` or a bare `{"models": […]}`.
  nonisolated static func modelIDs(in data: Data) -> [String] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return []
    }
    let entries = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
    let ids = entries.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
    return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  // MARK: - test

  /// One tiny translation through the configured model, so a wrong key, URL or
  /// model id shows up here instead of in the first batch of a run.
  func test() async {
    guard let model = RoutedModel.current, model.isUsable else {
      testResult = TestResult(succeeded: false, message: problem ?? "Settings are incomplete.")
      return
    }
    isTesting = true
    defer { isTesting = false }
    let client = OpenAIChatClient(
      endpoint: model.endpoint, wire: model.wire, apiKey: model.bearer, model: model.model,
      headers: model.allHeaders, timeout: 60)
    let started = Date.now
    do {
      let reply = try await client.complete(
        system: "You translate app interface strings. Answer with the translation only.",
        user: "Translate into French: \"Save changes\"")
      let seconds = Date.now.timeIntervalSince(started)
      let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
      testResult = TestResult(
        succeeded: true,
        message: "\"\(text.prefix(80))\" in \(seconds.formatted(.number.precision(.fractionLength(1)))) s")
    } catch {
      testResult = TestResult(succeeded: false, message: error.localizedDescription)
    }
  }
}
