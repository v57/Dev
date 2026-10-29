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

#if os(Windows) || os(Linux)
/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1`.
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../\(name)")
}
// Off Apple platforms SwiftUI is v57/SwiftUI, for the app's own libraries.
package.dependencies.append(v57("SwiftUI"))
for target in package.targets where ["DevDesktop", "DevGraphics"].contains(target.name) {
  target.dependencies.append(.product(name: "SwiftUI", package: "SwiftUI"))
}
#endif
#if os(Linux)
// The app on SwiftUI's GTK backend: an executable built from the Xcode project's sources with its settings
// (V57_LOCAL=1 swift build --product Dev). The Mac-only tools (App Icon, screenshot capture and framing, App Store
// Connect, UTM, the storage cleaner) say they are available on macOS (DevCapabilities).
package.dependencies += [
  v57("Component"), v57("Vault"), v57("Code"), v57("Database"), v57("Git"), v57("UpdateKit"), v57("Platform"),
]
package.targets.append(
  .executableTarget(
    name: "Dev",
    dependencies: [
      "DevScreenshots", "DevScreenshotsCapture", "DevDesktop", "DevGraphics",
      .product(name: "SwiftUI", package: "SwiftUI"), .product(name: "SQLite3", package: "SwiftUI"),
      .product(name: "CryptoKit", package: "SwiftUI"), .product(name: "SwiftUIPortability", package: "SwiftUI"),
      .product(name: "ComponentKit", package: "Component"), .product(name: "VaultKit", package: "Vault"),
      .product(name: "VaultUI", package: "Vault"), .product(name: "CodeProgress", package: "Code"),
      .product(name: "CodeWorkspace", package: "Code"), .product(name: "CodeActions", package: "Code"),
      .product(name: "SQLiteKit", package: "Database"), .product(name: "WireKit", package: "Database"),
      .product(name: "GitHubKit", package: "Git"), .product(name: "UpdateKit", package: "UpdateKit"),
      .product(name: "PlatformDiskUsage", package: "Platform"), .product(name: "PlatformImage", package: "Platform"),
      .product(name: "PlatformLanguageModel", package: "Platform"),
      .product(name: "PlatformBroadcast", package: "Platform"), .product(name: "PlatformHTTP", package: "Platform"),
    ],
    path: "Dev", exclude: ["AppIcon.icon", "Release/release.sh"],
    swiftSettings: [
      .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
      .enableUpcomingFeature("MemberImportVisibility"),
      // On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published), URLSession and the
      // file APIs SwiftUIPortability adds along, and `import SwiftUI` brings Observation (@Observable): every file
      // gets them here too.
      .unsafeFlags(
        ["Combine", "FoundationNetworking", "Observation", "SwiftUIPortability"].flatMap {
          ["-Xfrontend", "-import-module", "-Xfrontend", $0]
        }),
    ]))
package.products.append(.executable(name: "Dev", targets: ["Dev"]))
#endif
