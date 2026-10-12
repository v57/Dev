//
//  LaunchOptions.swift
//  Dev
//

import Foundation

/// How this launch was asked to behave. The screenshot UI tests launch Dev with
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

  /// `-DevTab overview|localization|icon|screenshots|workflows`: the tab the
  /// first project opens on (screenshot tests and design checks).
  static var tab: String? { value(after: "-DevTab") }

  /// `-DevOpen storage|vms`: a tool to open instead of a project;
  /// `-DevOpen releaseSettings` (with `-DevTab workflows`) opens Release Settings.
  static var open: String? { value(after: "-DevOpen") }

  /// `-DevStoragePage smartScan|languages|<category>`: Storage's first page.
  static var storagePage: String? { value(after: "-DevStoragePage") }

  /// `-DevSettingsTab general|translation|agents|advanced`: opens Settings on it.
  static var settingsTab: String? { value(after: "-DevSettingsTab") }

  /// `-DevRunWorkflow <id>`: runs that workflow of the first project at launch
  /// (design checks of a run in flight).
  static var runWorkflow: String? { value(after: "-DevRunWorkflow") }

  private static func value(after flag: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }
}
