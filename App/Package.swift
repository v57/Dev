// swift-tools-version: 6.4
// The app, a package of its own beside DevKit (..), so the repositories it depends on (Code, Database, Git) can
// depend on DevKit's DevScreenshots without a cycle between packages.

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1` (in Xcode,
/// open Dev-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../../\(name)")
}

/// This repository's DevKit, the package at "..": SwiftPM names a path dependency after its folder, which is Dev in the
/// main checkout and the worktree's own name in a worktree.
let kits = String(Context.packageDirectory.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast().last ?? "Dev")

/// The app's settings: Swift 5 with the main actor by default, as the Xcode target had them.
let settings: [SwiftSetting] = [
  .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "DevApp", platforms: [.macOS(.v15)],
  products: [.library(name: "DevApp", targets: ["DevApp"])],
  dependencies: [
    .package(path: ".."),
    // The shared design, the vault, Code's progress, workspaces and actions (installs, the release tools), Database's
    // SQLite for the imported translation database, Git's GitHub sign-in, in-app updates and Platform's backends.
    v57("Component"), v57("Vault"), v57("Code"), v57("Database"), v57("Git"), v57("UpdateKit"), v57("Platform"),
  ],
  targets: [
    // The app, all of it but its entry point (Sources/Dev/DevMain.swift): Dev.xcodeproj builds that file into Dev.app
    // with Resources (the icon, entitlements and release.sh, which the app runs from its bundle); on Linux the Dev
    // target below does.
    .target(
      name: "DevApp",
      dependencies: [
        .product(name: "DevScreenshots", package: kits), .product(name: "DevScreenshotsCapture", package: kits),
        .product(name: "DevDesktop", package: kits), .product(name: "DevGraphics", package: kits),
        .product(name: "ComponentKit", package: "Component"), .product(name: "VaultKit", package: "Vault"),
        .product(name: "VaultUI", package: "Vault"), .product(name: "CodeProgress", package: "Code"),
        .product(name: "CodeWorkspace", package: "Code"), .product(name: "CodeActions", package: "Code"),
        .product(name: "SQLiteKit", package: "Database"), .product(name: "WireKit", package: "Database"),
        .product(name: "GitHubKit", package: "Git"), .product(name: "UpdateKit", package: "UpdateKit"),
        .product(name: "PlatformDiskUsage", package: "Platform"), .product(name: "PlatformImage", package: "Platform"),
        .product(name: "PlatformLanguageModel", package: "Platform"),
        .product(name: "PlatformBroadcast", package: "Platform"), .product(name: "PlatformHTTP", package: "Platform"),
      ],
      swiftSettings: settings),
    // The app's own tests (the translation store, localization flow, storage rules), no host app needed: `swift test`
    // here (V57_LOCAL=1 for the checkouts beside this one).
    .testTarget(name: "DevAppTests", dependencies: ["DevApp"], swiftSettings: settings),
  ])

#if os(Windows) || os(Linux)
// Off Apple platforms SwiftUI and the frameworks the app imports (SQLite3, CryptoKit) are v57/SwiftUI's stand-ins.
// Only here: on Apple platforms the app uses Apple's, and v57/SwiftUI (with its swift-syntax) stays out of the package
// graph Xcode resolves.
package.dependencies += [v57("SwiftUI")]
// On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published), URLSession and the file APIs
// SwiftUIPortability adds along, and `import SwiftUI` brings Observation (@Observable): every file gets them here too.
let appSettings =
  settings + [
    .unsafeFlags(
      ["Combine", "FoundationNetworking", "Observation", "SwiftUIPortability"].flatMap {
        ["-Xfrontend", "-import-module", "-Xfrontend", $0]
      })
  ]
for target in package.targets where ["DevApp", "DevAppTests"].contains(target.name) {
  if target.name == "DevApp" {
    target.dependencies += ["SwiftUI", "SQLite3", "CryptoKit", "SwiftUIPortability"].map {
      .product(name: $0, package: "SwiftUI")
    }
  }
  target.swiftSettings = appSettings
}
#endif
#if os(Linux)
// The app on SwiftUI's GTK backend (in App/: V57_LOCAL=1 swift build --product Dev; SwiftUI's Linux/scripts/build-app
// --package <this App folder> Dev stages it). The Mac-only tools (App Icon, screenshot capture and framing, App Store
// Connect, UTM, the storage cleaner) say they are available on macOS (DevCapabilities).
package.targets.append(
  .executableTarget(
    name: "Dev", dependencies: ["DevApp", .product(name: "SwiftUI", package: "SwiftUI")], swiftSettings: appSettings))
package.products.append(.executable(name: "Dev", targets: ["Dev"]))
#endif
