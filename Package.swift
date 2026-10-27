// swift-tools-version: 6.4

import PackageDescription

let settings: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency")]
/// The app's own libraries, written as the app is: Swift 5 with the main actor by default.
let app: [SwiftSetting] = [
  .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
]

let package = Package(
  name: "Dev", platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    // Apps link this: the screenshot format and the hook that sets up a scene.
    .library(name: "DevScreenshots", targets: ["DevScreenshots"]),
    // Dev and the command line link this: captures scenes on this Mac and its simulators.
    .library(name: "DevScreenshotsCapture", targets: ["DevScreenshotsCapture"]),
    .executable(name: "dev-screenshots", targets: ["dev-screenshots"]),
    // The Dev app links these: its desktop integration (panels, other apps, the quit guard, a full-screen viewer)
    // and its drawing (app icons with actool, framed screenshots), each with what other systems have.
    .library(name: "DevDesktop", targets: ["DevDesktop"]),
    .library(name: "DevGraphics", targets: ["DevGraphics"]),
  ],
  targets: [
    .target(name: "DevScreenshots", path: "DevKit/Screenshots", swiftSettings: settings),
    .target(
      name: "DevScreenshotsCapture", dependencies: ["DevScreenshots"], path: "DevKit/ScreenshotsCapture",
      swiftSettings: settings),
    .executableTarget(
      name: "dev-screenshots", dependencies: ["DevScreenshotsCapture"], path: "DevKit/dev-screenshots",
      swiftSettings: settings),
    .target(name: "DevDesktop", path: "DevKit/Desktop", swiftSettings: app),
    .target(name: "DevGraphics", dependencies: ["DevScreenshots"], path: "DevKit/Graphics", swiftSettings: app),
    .testTarget(
      name: "DevScreenshotsTests", dependencies: ["DevScreenshotsCapture"], path: "DevKit/Tests",
      swiftSettings: settings),
  ])
