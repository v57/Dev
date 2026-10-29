// swift-tools-version: 6.4
// DevKit, the libraries; the app is the package in App/. Nothing here depends on another v57 repository (but
// v57/SwiftUI off Apple platforms), so every app can link DevScreenshots and Dev's app can link those apps' libraries.

import PackageDescription

let settings: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency")]
/// The libraries the app links, written as the app is: Swift 5 with the main actor by default.
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
    // Dev's app links these: its desktop integration (panels, other apps, the quit guard, a full-screen viewer)
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

#if os(Windows) || os(Linux)
/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1`.
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../\(name)")
}
// Off Apple platforms SwiftUI is v57/SwiftUI, for DevDesktop and DevGraphics.
package.dependencies.append(v57("SwiftUI"))
for target in package.targets where ["DevDesktop", "DevGraphics"].contains(target.name) {
  target.dependencies.append(.product(name: "SwiftUI", package: "SwiftUI"))
}
#endif
