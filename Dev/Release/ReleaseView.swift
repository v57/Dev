//
//  ReleaseView.swift
//  Dev
//

import AppKit
import SwiftUI

/// Every project's release runs, kept while the app is open so a run survives a
/// switch to another tool or project.
@Observable
final class ReleaseStore {
  /// Filled lazily while a view asks, so it must not be observed.
  @ObservationIgnored private var runners: [URL: ReleaseRunner] = [:]

  func runner(for root: URL) -> ReleaseRunner {
    if let runner = runners[root] { return runner }
    let runner = ReleaseRunner()
    runners[root] = runner
    return runner
  }
}

/// The Release tool for one project: its `release.env`, the steps to run, and the
/// live log of `release.sh`. Steps that send something out of this Mac (notary,
/// GitHub, App Store Connect) ask first.
struct ReleaseView: View {
  let root: URL
  @Environment(ReleaseStore.self) private var store

  @State private var config: ReleaseConfig?
  @State private var isDetecting = false
  @State private var selected: Set<ReleaseStep> = [.check, .build, .test, .archive]
  @State private var version = ""
  @State private var confirming: [ReleaseStep] = []
  @State private var showsSettings = false
  @State private var saveError: String?

  var body: some View {
    let runner = store.runner(for: root)
    Group {
      if let config {
        HSplitView {
          stepsColumn(runner, config: config)
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
          logColumn(runner)
            .frame(minWidth: 360)
        }
      } else {
        setupPrompt
      }
    }
    .task(id: root) { config = ReleaseConfig.load(from: root) }
    .sheet(isPresented: $showsSettings) {
      if let config {
        ReleaseSettingsSheet(config: config) { edited in
          save(edited)
        }
      }
    }
    .alert(
      "Send this release out?",
      isPresented: Binding(get: { !confirming.isEmpty }, set: { if !$0 { confirming = [] } })
    ) {
      Button("Run") {
        runner.run(ReleaseStep.allCases.filter(selected.contains), in: root, version: version)
        confirming = []
      }
      Button("Cancel", role: .cancel) { confirming = [] }
    } message: {
      Text(confirming.compactMap { step in step.publishes.map { "\(step.title) \($0)." } }
        .joined(separator: "\n"))
    }
  }

  // MARK: - setup

  private var setupPrompt: some View {
    ContentUnavailableView {
      Label("Release this project", systemImage: "shippingbox")
    } description: {
      Text("Dev reads the Xcode project, scheme, team and GitHub remote and writes a release.env you can edit. The same file drives Tools/release/release.sh from a terminal.")
    } actions: {
      Button(isDetecting ? "Reading the project…" : "Set Up Release") {
        Task {
          isDetecting = true
          let detected = await ReleaseConfig.detect(in: root)
          isDetecting = false
          save(detected)
          showsSettings = true
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isDetecting)
    }
  }

  private func save(_ edited: ReleaseConfig) {
    do {
      try edited.save(to: root)
      config = edited
    } catch {
      saveError = error.localizedDescription
    }
  }

  // MARK: - steps

  private func stepsColumn(_ runner: ReleaseRunner, config: ReleaseConfig) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(config["APP_NAME"].isEmpty ? root.lastPathComponent : config["APP_NAME"])
            .font(.headline)
          Text([config["SCHEME"], config["PLATFORM"], config["GITHUB_REPO"]].filter { !$0.isEmpty }
            .joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          showsSettings = true
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
        .help("Edit release.env")
      }
      .padding(12)
      Divider()
      List {
        ForEach(ReleaseStep.allCases) { step in
          StepRow(
            step: step,
            state: runner.state(step),
            isOn: Binding(
              get: { selected.contains(step) },
              set: { if $0 { selected.insert(step) } else { selected.remove(step) } }),
            isEnabled: !runner.isRunning)
        }
      }
      .listStyle(.inset)
      Divider()
      HStack {
        TextField("Version", text: $version, prompt: Text("from the project"))
          .frame(width: 120)
          .help("MARKETING_VERSION for the archive; empty uses the project's own")
        Spacer()
        if runner.isRunning {
          Button("Stop", role: .destructive) { runner.cancel() }
        } else {
          Menu {
            Button("Dry Run") {
              runner.run(ReleaseStep.allCases.filter(selected.contains), in: root, version: version, dryRun: true)
            }
            .help("Prints every command without running it")
          } label: {
            Text("Run")
          } primaryAction: {
            start(runner)
          }
          .menuStyle(.borderedButton)
          .fixedSize()
          .disabled(selected.isEmpty)
        }
      }
      .padding(12)
      if let saveError {
        Text(saveError).font(.caption).foregroundStyle(.red).padding([.horizontal, .bottom], 12)
      }
    }
  }

  private func start(_ runner: ReleaseRunner) {
    let outward = ReleaseStep.allCases.filter { selected.contains($0) && $0.publishes != nil }
    if outward.isEmpty {
      runner.run(ReleaseStep.allCases.filter(selected.contains), in: root, version: version)
    } else {
      confirming = outward
    }
  }

  // MARK: - log

  private func logColumn(_ runner: ReleaseRunner) -> some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(Array(runner.log.enumerated()), id: \.offset) { index, line in
              Text(line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color(for: line))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(index)
            }
          }
          .padding(10)
        }
        .onChange(of: runner.log.count) { _, count in
          proxy.scrollTo(count - 1, anchor: .bottom)
        }
      }
      .overlay {
        if runner.log.isEmpty {
          Text("Pick the steps and press Run.")
            .foregroundStyle(.secondary)
        }
      }
      if !runner.artifacts.isEmpty {
        Divider()
        ScrollView(.horizontal) {
          HStack {
            ForEach(runner.artifacts, id: \.self) { url in
              Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
              } label: {
                Label(url.lastPathComponent, systemImage: "doc")
              }
              .help("Show in Finder")
            }
          }
          .padding(10)
        }
      }
    }
  }

  private func color(for line: String) -> Color {
    if line.hasPrefix("::fail") || line.contains("error:") { return .red }
    if line.hasPrefix("::done") || line.hasPrefix("::finished") { return .green }
    if line.hasPrefix("::") { return .accentColor }
    if line.hasPrefix("$ ") { return .secondary }
    return .primary
  }
}

/// One step with its toggle and its state from the last run.
private struct StepRow: View {
  let step: ReleaseStep
  let state: ReleaseRunner.StepState
  @Binding var isOn: Bool
  let isEnabled: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Toggle("", isOn: $isOn)
        .labelsHidden()
        .disabled(!isEnabled)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(step.title)
          if step.publishes != nil {
            Image(systemName: "arrow.up.forward.circle")
              .foregroundStyle(.secondary)
              .help("Sends something out of this Mac; asks before running")
          }
        }
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      status
    }
  }

  private var subtitle: String {
    switch state {
    case .skipped(let reason), .failed(let reason): return reason
    default: return step.detail
    }
  }

  @ViewBuilder
  private var status: some View {
    switch state {
    case .idle: EmptyView()
    case .running: ProgressView().controlSize(.small)
    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
    }
  }
}

/// The `release.env` form.
private struct ReleaseSettingsSheet: View {
  @State var config: ReleaseConfig
  let onSave: (ReleaseConfig) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("App") {
          field("App name", "APP_NAME", "MyApp")
          field("Scheme", "SCHEME", "MyApp")
          field("Project", "PROJECT", "MyApp.xcodeproj")
          field("Workspace", "WORKSPACE", "MyApp.xcworkspace (instead of a project)")
          Picker("Platform", selection: binding("PLATFORM")) {
            Text("macOS").tag("macos")
            Text("iOS").tag("ios")
          }
          field("Team ID", "TEAM_ID", "ABCDE12345")
        }
        Section("Tests and screenshots") {
          field("Test scheme", "TEST_SCHEME", "empty skips tests")
          field("Test destination", "TEST_DESTINATION", "platform=macOS")
          field("Screenshot test", "SCREENSHOT_TEST", "MyAppUITests/ScreenshotTests")
          field("Locales", "SCREENSHOT_LOCALES", "en-US de-DE ja-JP")
        }
        Section {
          field("Formats", "DIRECT_DOWNLOAD", "zip dmg")
          Picker("Builds", selection: binding("DIRECT_ARCHS")) {
            Text("Universal").tag("universal")
            Text("Apple silicon").tag("arm64")
            Text("Both").tag("universal arm64")
          }
          .help("Both ships <App> (universal) and <App>-AppleSilicon, half the size")
          field("Notary profile", "NOTARY_PROFILE", "v57-notary")
        } header: {
          Text("Direct download")
        } footer: {
          Text("Create the notary profile once in Terminal: xcrun notarytool store-credentials <name>")
        }
        Section("GitHub") {
          field("Repository", "GITHUB_REPO", "owner/repo")
          Toggle("Create as draft", isOn: Binding(
            get: { config["GITHUB_DRAFT"] != "no" },
            set: { config["GITHUB_DRAFT"] = $0 ? "yes" : "no" }))
        }
        Section {
          Toggle("Upload to App Store Connect", isOn: Binding(
            get: { config["APP_STORE"] == "yes" },
            set: { config["APP_STORE"] = $0 ? "yes" : "no" }))
          field("API key ID", "ASC_KEY_ID", "optional")
          field("Issuer ID", "ASC_ISSUER_ID", "optional")
          field("Key file", "ASC_KEY_PATH", "~/.appstoreconnect/AuthKey_XXXX.p8")
        } header: {
          Text("App Store Connect")
        } footer: {
          Text("Without an API key the upload uses the account signed in to Xcode.")
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          onSave(config)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 520, height: 640)
  }

  private func binding(_ key: String) -> Binding<String> {
    Binding(get: { config[key] }, set: { config[key] = $0 })
  }

  private func field(_ title: String, _ key: String, _ prompt: String) -> some View {
    TextField(title, text: binding(key), prompt: Text(prompt))
  }
}
