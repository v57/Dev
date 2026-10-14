// swift-tools-version: 6.4

import PackageDescription

let settings: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency")]

let package = Package(
  name: "Dev", platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    // Apps link this: the screenshot format and the hook that sets up a scene.
    .library(name: "DevScreenshots", targets: ["DevScreenshots"]),
    // Dev and the command line link this: captures scenes on this Mac and its simulators.
    .library(name: "DevScreenshotsCapture", targets: ["DevScreenshotsCapture"]),
    .executable(name: "dev-screenshots", targets: ["dev-screenshots"]),
  ],
  targets: [
    .target(name: "DevScreenshots", path: "DevKit/Screenshots", swiftSettings: settings),
    .target(
      name: "DevScreenshotsCapture", dependencies: ["DevScreenshots"], path: "DevKit/ScreenshotsCapture",
      swiftSettings: settings),
    .executableTarget(
      name: "dev-screenshots", dependencies: ["DevScreenshotsCapture"], path: "DevKit/dev-screenshots",
      swiftSettings: settings),
    .testTarget(
      name: "DevScreenshotsTests", dependencies: ["DevScreenshotsCapture"], path: "DevKit/Tests",
      swiftSettings: settings),
  ])
