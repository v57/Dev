//
//  ScreenshotsStore.swift
//  Dev
//

import Foundation
import Observation

/// Each project's screenshots: what is on disk, the recipe, and a capture or
/// processing in flight. Owned once by ContentView, so the Overview strip and
/// the Screenshots tab read the same state.
@Observable
final class ScreenshotsStore {
  enum Phase: Equatable {
    case idle
    case capturing
    case processing
  }

  private(set) var libraries: [URL: ScreenshotLibrary] = [:]
  private(set) var recipes: [URL: ScreenshotRecipe] = [:]
  private(set) var reports: [URL: ScreenshotProcessor.SavedReport] = [:]
  private(set) var phases: [URL: Phase] = [:]
  /// The capture's output, for the log sheet.
  private(set) var logs: [URL: [String]] = [:]
  /// Why the last capture or processing failed, shown once.
  var errors: [URL: String] = [:]

  @ObservationIgnored private var processes: [URL: LineProcess] = [:]

  func phase(_ root: URL) -> Phase { phases[root] ?? .idle }

  func library(_ root: URL) -> ScreenshotLibrary? { libraries[root] }

  func recipe(_ root: URL) -> ScreenshotRecipe? { recipes[root] }

  /// Re-reads the project's folders and recipe, off the main actor.
  func refresh(_ root: URL) async {
    let (library, recipe, report) = await Task.detached(priority: .userInitiated) {
      (ScreenshotLibrary.scan(root), ScreenshotRecipe.load(in: root), ScreenshotProcessor.loadReport(in: root))
    }.value
    libraries[root] = library
    recipes[root] = recipe
    reports[root] = report
  }

  /// Runs release.sh's screenshots step (the project's screenshot UI test, per
  /// locale), then the recipe.
  func capture(_ root: URL) {
    guard phase(root) == .idle, let script = ReleaseRunner.scriptURL else { return }
    phases[root] = .capturing
    logs[root] = []
    errors[root] = nil
    let process = LineProcess("/bin/bash", [script.path, "--project", root.path, "screenshots"], directory: root)
    processes[root] = process
    Task {
      do {
        for try await line in process.lines() {
          logs[root, default: []].append(line)
          if line.hasPrefix("::fail ") { errors[root] = String(line.split(separator: " ", maxSplits: 2).last ?? "") }
          if line.hasPrefix("::skip ") { errors[root] = "Skipped: " + String(line.split(separator: " ", maxSplits: 2).last ?? "") }
        }
      } catch {
        errors[root] = error.localizedDescription
      }
      processes[root] = nil
      phases[root] = .idle
      if process.status == 0, errors[root] == nil {
        await processLatest(root)
      } else {
        await refresh(root)
      }
    }
  }

  func cancelCapture(_ root: URL) { processes[root]?.terminate() }

  /// Applies the recipe to the latest captures.
  func processLatest(_ root: URL) async {
    guard phase(root) == .idle else { return }
    phases[root] = .processing
    let report = await ScreenshotProcessor.processLatest(in: root)
    if !report.succeeded { errors[root] = report.lines.joined(separator: "\n") }
    phases[root] = .idle
    await refresh(root)
  }

  /// Saves the recipe the reader edited, then renders with it.
  func save(_ recipe: ScreenshotRecipe, in root: URL) async {
    do {
      try recipe.save(in: root, by: "you")
      recipes[root] = ScreenshotRecipe.load(in: root)
      await processLatest(root)
    } catch {
      errors[root] = error.localizedDescription
    }
  }
}
