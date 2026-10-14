//
//  ReleaseRunner.swift
//  Dev
//

import Foundation
import GitHubKit
import Observation

// MARK: - ReleaseStep

/// One step of `release.sh`, in the order the script runs them.
nonisolated enum ReleaseStep: String, CaseIterable, Identifiable, Sendable {
  case check, build, test, screenshots, archive, direct, github, appstore

  var id: String { rawValue }

  var title: String {
    switch self {
    case .check: return "Check"
    case .build: return "Build"
    case .test: return "Test"
    case .screenshots: return "Screenshots"
    case .archive: return "Archive"
    case .direct: return "Sign & Notarize"
    case .github: return "GitHub Release"
    case .appstore: return "App Store Connect"
    }
  }

  var detail: String {
    switch self {
    case .check: return "Tools, certificate, notary profile, GitHub sign-in"
    case .build: return "A release build"
    case .test: return "The test scheme"
    case .screenshots: return "The scenes in .dev/screenshots.json, or a UI test per locale"
    case .archive: return "An archive with the version and build number"
    case .direct: return "Developer ID, notarized and stapled .zip and .dmg"
    case .github: return "A release with the download files"
    case .appstore: return "Uploads the archive"
    }
  }

  /// What the step sends outside this Mac, or nil when it stays local. Such steps
  /// ask before they run.
  var publishes: String? {
    switch self {
    case .direct: return "uploads the app to Apple's notary service"
    case .github: return "creates a GitHub release with the download files"
    case .appstore: return "uploads a build to App Store Connect"
    default: return nil
    }
  }
}

// MARK: - ReleaseRunner

/// One run of `release.sh` for a project: the steps' states, the log and the files
/// it made, read from the script's marker lines as they arrive.
@Observable
final class ReleaseRunner {
  enum StepState: Equatable {
    case idle, running, done
    case skipped(String)
    case failed(String)
  }

  private(set) var states: [ReleaseStep: StepState] = [:]
  private(set) var log: [String] = []
  private(set) var artifacts: [URL] = []
  private(set) var isRunning = false
  private(set) var finishedVersion: String?
  private(set) var exitStatus: Int32?

  private var process: LineProcess?
  private var task: Task<Void, Never>?

  /// The bundled script; `Tools/release/release.sh` in the repo points at the same file.
  static var scriptURL: URL? { Bundle.main.url(forResource: "release", withExtension: "sh") }

  func state(_ step: ReleaseStep) -> StepState { states[step] ?? .idle }

  func run(_ steps: [ReleaseStep], in root: URL, version: String, dryRun: Bool = false) {
    guard !isRunning, let script = Self.scriptURL else { return }
    states = [:]
    log = []
    artifacts = []
    finishedVersion = nil
    exitStatus = nil
    var arguments = [script.path, "--project", root.path]
    let version = version.trimmingCharacters(in: .whitespaces)
    if !version.isEmpty { arguments += ["--version", version] }
    if dryRun { arguments.append("--dry-run") }
    arguments += steps.map(\.rawValue)
    // The GitHub sign-in the v57 apps share (Git, Markdown): gh takes it from GH_TOKEN, so a GitHub
    // release needs no separate `gh auth login`.
    var environment: [String: String] = [:]
    if let token = (try? KeychainTokenStore.shared.load())?.token { environment["GH_TOKEN"] = token }
    // The screenshots step runs this app as dev-screenshots (`Dev --screenshots`).
    if let executable = Bundle.main.executablePath { environment["DEV_APP_EXECUTABLE"] = executable }
    let process = LineProcess("/bin/bash", arguments, directory: root, environment: environment)
    self.process = process
    isRunning = true
    task = Task { [weak self] in
      do {
        for try await line in process.lines() {
          self?.read(line)
        }
      } catch {
        self?.log.append("could not start release.sh: \(error.localizedDescription)")
      }
      guard let self else { return }
      self.exitStatus = process.status
      // A step still marked running was cut short (a cancel, or the script died).
      for (step, state) in self.states where state == .running {
        self.states[step] = .failed(process.status == 15 ? "cancelled" : "stopped")
      }
      self.isRunning = false
      self.process = nil
    }
  }

  func cancel() {
    process?.terminate()
  }

  private func read(_ line: String) {
    if log.count > 5_000 { log.removeFirst(1_000) }
    log.append(line)
    guard line.hasPrefix("::") else { return }
    let parts = line.dropFirst(2).split(separator: " ", maxSplits: 2).map(String.init)
    guard let marker = parts.first else { return }
    let step = parts.count > 1 ? ReleaseStep(rawValue: parts[1]) : nil
    let reason = parts.count > 2 ? parts[2] : ""
    switch marker {
    case "step": if let step { states[step] = .running }
    case "done": if let step { states[step] = .done }
    case "skip": if let step { states[step] = .skipped(reason) }
    case "fail": if let step { states[step] = .failed(reason) }
    case "artifact":
      let path = String(line.dropFirst("::artifact ".count))
      artifacts.append(URL(fileURLWithPath: path))
    case "finished": finishedVersion = parts.count > 1 ? parts[1] : ""
    default: break
    }
  }
}
