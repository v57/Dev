//
//  LaunchOptions.swift
//  Dev
//

import Foundation

/// How this launch was asked to behave. Screenshots (`.dev/screenshots.json`) launch Dev with
/// `-DevScreenshotMode` and a demo project, so the pictures never show the
/// user's own projects, servers or translation memory.
nonisolated enum LaunchOptions {
  /// The store is in memory, and nothing the run does is kept.
  static let isScreenshotMode = ProcessInfo.processInfo.arguments.contains("-DevScreenshotMode")

  /// Folders to import as projects at launch (`DEV_DEMO_PROJECTS`, colon-separated).
  static var demoProjects: [URL] {
    (ProcessInfo.processInfo.environment["DEV_DEMO_PROJECTS"] ?? "")
      .split(separator: ":").map { URL(fileURLWithPath: String($0)) }
  }

  /// `-DevOpen storage|vms`: a tool to open instead of a project, `welcome` nothing (ContentView reads it per scene);
  /// `-DevOpen releaseSettings` or `editWorkflow` (with `-DevTool workflows`) opens Release Settings or the first
  /// workflow's sheet, `addServer` the Add Connection sheet.
  static var open: String? { value(after: "-DevOpen") }

  /// `-DevStoragePage smartScan|languages|<category>`: Storage's first page.
  static var storagePage: String? { value(after: "-DevStoragePage") }

  /// `-DevHangLog <file>`: main-thread stalls are logged there (`MainThreadWatchdog`).
  static var hangLog: String? { value(after: "-DevHangLog") }

  private static func value(after flag: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }
}
