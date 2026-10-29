//
//  ScreenshotsStore.swift
//  Dev
//

import DevScreenshots
import Foundation
import Observation

/// Each project's screenshots: what is on disk, its `.dev/screenshots.json`, and a capture or
/// framing in flight. Owned once by ContentView, so the Overview strip and the Screenshots tab
/// read the same state.
@Observable
final class ScreenshotsStore {
  enum Phase: Equatable {
    case idle
    case capturing
    case processing
  }

  private(set) var libraries: [URL: ScreenshotLibrary] = [:]
  private(set) var reports: [URL: ScreenshotProcessor.SavedReport] = [:]
  private(set) var phases: [URL: Phase] = [:]
  /// The capture's output, for the log sheet.
  private(set) var logs: [URL: [String]] = [:]
  /// The capture waits for the reader to switch back to the app it captures.
  private(set) var paused: Set<URL> = []
  /// Why the last capture or framing failed, shown once.
  var errors: [URL: String] = [:]

  @ObservationIgnored private var processes: [URL: LineProcess] = [:]

  func phase(_ root: URL) -> Phase { phases[root] ?? .idle }

  func library(_ root: URL) -> ScreenshotLibrary? { libraries[root] }

  func config(_ root: URL) -> ScreenshotConfig? { libraries[root]?.config }

  /// Re-reads the project's config, pictures and status, off the main actor.
  func refresh(_ root: URL) async {
    let (library, report) = await Task.detached(priority: .userInitiated) {
      (ScreenshotLibrary.scan(root), ScreenshotProcessor.loadReport(in: root))
    }.value
    libraries[root] = library
    reports[root] = report
  }

  /// Takes the scenes in `.dev/screenshots.json` with Dev's own `dev-screenshots`, then frames them.
  func capture(_ root: URL) {
    guard phase(root) == .idle, let executable = Bundle.main.executablePath else { return }
    phases[root] = .capturing
    logs[root] = []
    errors[root] = nil
    let process = LineProcess(executable, ["--screenshots", "capture", "--project", root.path], directory: root)
    processes[root] = process
    Task {
      do {
        for try await line in process.lines() {
          logs[root, default: []].append(line)
          if line.contains("Paused: ") { paused.insert(root) }
          if line.contains("Going on: ") { paused.remove(root) }
          if line.hasPrefix("error: ") { errors[root] = String(line.dropFirst("error: ".count)) }
        }
      } catch {
        errors[root] = error.localizedDescription
      }
      processes[root] = nil
      paused.remove(root)
      phases[root] = .idle
      if process.status != 0, errors[root] == nil {
        let failed = logs[root, default: []].filter { $0.contains(" failed: ") }.count
        errors[root] = failed > 0 ? "\(failed) pictures were not captured: see the log." : "The capture stopped: see the log."
      }
      // Frame whatever was taken, even when some scenes failed.
      await processLatest(root)
    }
  }

  func cancelCapture(_ root: URL) { processes[root]?.terminate() }

  /// Frames the latest captures.
  func processLatest(_ root: URL) async {
    guard phase(root) == .idle else { return }
    phases[root] = .processing
    let report = await ScreenshotProcessor.processLatest(in: root)
    if !report.succeeded, errors[root] == nil { errors[root] = report.lines.joined(separator: "\n") }
    phases[root] = .idle
    await refresh(root)
  }

  /// Saves the framing and captions the reader edited into the file as it is on disk now, so scenes
  /// edited elsewhere are kept, then renders with them.
  func save(_ draft: ScreenshotConfig, in root: URL) async {
    do {
      try Self.save(framing: draft.framing, captions: draft.captions, in: root, by: "you")
      errors[root] = nil
      await refresh(root)
      await processLatest(root)
    } catch {
      errors[root] = error.localizedDescription
    }
  }

  /// Writes `framing` and the scenes' captions (by id) into the project's config, touching nothing
  /// else, and adds new captions to the caption catalog. The app and the MCP server both save here.
  nonisolated static func save(
    framing: ScreenshotConfig.Framing?, captions: [String: String?], in root: URL, by author: String
  ) throws {
    guard var config = try ScreenshotConfig.load(in: root) else {
      throw ScreenshotsError("\(root.lastPathComponent) has no \(ScreenshotConfig.path) to add the framing to.")
    }
    if var framing {
      framing.updatedBy = author
      framing.updatedAt = Date()
      config.framing = framing
    }
    for index in config.scenes.indices {
      if let caption = captions[config.scenes[index].id] {
        config.scenes[index].caption = caption.flatMap { $0.isEmpty ? nil : $0 }
      }
    }
    try config.save(in: root)
    let catalog = (config.framing ?? ScreenshotConfig.Framing()).caption.catalog
    let keys = config.scenes.compactMap(\.caption)
    if !keys.isEmpty { try? CaptionCatalog.addMissingKeys(keys, to: root.appendingPathComponent(catalog)) }
  }
}

nonisolated struct ScreenshotsError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

extension ScreenshotConfig {
  /// The scenes' captions by id, as `ScreenshotsStore.save` takes them.
  nonisolated var captions: [String: String?] {
    Dictionary(scenes.map { ($0.id, $0.caption) }) { first, _ in first }
  }
}
