//
//  ReleaseRunner.swift
//  Dev
//

import CodeActions
import Foundation
import Observation

// MARK: - ReleaseStep

/// One step of `release.sh`, in the order the script runs them.
nonisolated enum ReleaseStep: String, CaseIterable, Identifiable, Sendable {
  case check, build, test, screenshots, archive, direct, bundle, github, appstore, googleplay, msstore
  /// Asked for by name only: `all` doesn't include it.
  case bump

  var id: String { rawValue }

  var title: String {
    switch self {
    case .check: return String(localized: "Check")
    case .build: return String(localized: "Build")
    case .test: return String(localized: "Test")
    case .screenshots: return String(localized: "Screenshots")
    case .archive: return String(localized: "Archive")
    case .direct: return String(localized: "Sign & Notarize")
    case .bundle: return String(localized: "Result Archive")
    case .github: return String(localized: "GitHub Release")
    case .appstore: return "App Store Connect"
    case .googleplay: return "Google Play"
    case .msstore: return "Microsoft Store"
    case .bump: return String(localized: "Version Bump")
    }
  }

  var detail: String {
    switch self {
    case .check: return String(localized: "Tools, certificate, notary profile, package pins, the build machine")
    case .build: return String(localized: "A release build")
    case .test: return String(localized: "The test scheme")
    case .screenshots: return String(localized: "The scenes in .dev/screenshots.json, or a UI test per locale")
    case .archive: return String(localized: "The release build, packaged: .xcarchive, .dmg, .zip, .tar.gz or .apk")
    case .direct: return String(localized: "Developer ID, notarized and stapled .zip and .dmg")
    case .bundle: return String(localized: "One zip of every platform's files, with a manifest")
    case .github: return String(localized: "A release with every platform's download files, Windows and Linux ones signed")
    case .appstore: return String(localized: "Uploads the archive")
    case .googleplay: return String(localized: "Uploads the Android build")
    case .msstore: return String(localized: "Submits the Windows build")
    case .bump: return String(localized: "Sets the project's version and drafts its changelog from git log")
    }
  }

  /// What the step sends outside this Mac, or nil when it stays local. Such steps
  /// ask before they run.
  var publishes: String? {
    switch self {
    case .direct: return String(localized: "uploads the app to Apple's notary service")
    case .github: return String(localized: "creates a GitHub release with the download files")
    case .appstore: return String(localized: "uploads a build to App Store Connect")
    case .googleplay: return String(localized: "uploads a build to Google Play")
    case .msstore: return String(localized: "submits a build to the Microsoft Store")
    default: return nil
    }
  }

  /// Steps that build or ship one platform; the others (the result archive, the GitHub release) take every
  /// platform's files in the run.
  var takesPlatform: Bool { self != .bundle && self != .github && self != .bump }
}

// MARK: - ReleasePlatform

/// What a release step builds for: Apple platforms on this Mac, Windows and Linux on a machine of that system
/// (a UTM VM), Android cross-compiled on this Mac. release.sh's `--platform`.
nonisolated enum ReleasePlatform: String, CaseIterable, Identifiable, Sendable {
  case macos, ios, windows, linux, android

  var id: String { rawValue }

  var title: String {
    switch self {
    case .macos: return "macOS"
    case .ios: return "iOS"
    case .windows: return "Windows"
    case .linux: return "Linux"
    case .android: return "Android"
    }
  }

  var systemImage: String {
    switch self {
    case .macos: return "laptopcomputer"
    case .ios: return "iphone"
    case .windows: return "pc"
    case .linux: return "terminal"
    case .android: return "candybarphone"
    }
  }

  /// The system of the machine that builds it, for the platforms that don't build on this Mac.
  var buildSystem: VirtualMachine.System? {
    switch self {
    case .windows: return .windows
    case .linux: return .linux
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

  /// What release.sh gets from Dev besides its arguments: this app as dev-screenshots (`Dev --screenshots`) and the
  /// archive's release link (xcodebuild-release and its tools: CodeActions' copy inside this app). Never a GitHub token:
  /// the github step only writes what to publish, and Dev publishes it in-process (`GitHubReleasePublisher`).
  static func environment() -> [String: String] {
    var environment: [String: String] = [:]
    if let executable = Bundle.main.executablePath { environment["DEV_APP_EXECUTABLE"] = executable }
    if let tools = ReleaseTools.folder { environment["RELEASE_TOOLS"] = tools.path }
    return environment
  }

  func run(
    _ steps: [ReleaseStep], in root: URL, version: String, dryRun: Bool = false
  ) {
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
    let environment = Self.environment()
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
      if let artifact = WorkflowRun.Artifact(marker: line, stepID: "") { artifacts.append(artifact.url) }
    case "finished": finishedVersion = parts.count > 1 ? parts[1] : ""
    default: break
    }
  }
}
