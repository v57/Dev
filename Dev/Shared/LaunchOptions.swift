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
}
