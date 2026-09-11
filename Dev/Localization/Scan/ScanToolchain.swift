//
//  ScanToolchain.swift
//  Dev
//
//  Created by Dmitry on 11.09.26.
//

import Foundation

// MARK: - ScanPlatform

/// The platform a scan's compiles target.
///
/// A Swift package/Xcode project that builds for iOS cannot be type-checked
/// against the HOST's products, and the host build usually fails outright for
/// such a tree (measured on vijo/playgra: `swift build` for macOS dies on
/// `glassEffect(_:in:) is only available in macOS 26.0 or newer`, and every
/// module that imports UIKit errors out), so the scan has to mirror the
/// platform the tree actually builds for. SwiftPM/Xcode name that platform's
/// build products per configuration (`Debug` vs `Debug-iphonesimulator`), which
/// is the only thing the extraction has to agree with.
nonisolated enum ScanPlatform: String, Sendable {
  case host
  case iosSimulator

  /// `swiftbuild` (Xcode 26+, the default SwiftPM engine) product directory.
  var productDirectoryName: String {
    switch self {
    case .host: return "Debug"
    case .iosSimulator: return "Debug-iphonesimulator"
    }
  }

  /// Classic SwiftPM `.build/<triple>/` product directory name.
  var legacyProductDirectoryName: String {
    switch self {
    case .host: return "debug"
    case .iosSimulator: return "debug-iphonesimulator"
    }
  }

  /// Directory of SwiftPM/Xcode-generated clang modulemaps for this platform.
  /// The NON-platform directory holds duplicates for the host, so mixing the
  /// two redefines the same module.
  var moduleMapDirectoryName: String {
    switch self {
    case .host: return "GeneratedModuleMaps"
    case .iosSimulator: return "GeneratedModuleMaps-iphonesimulator"
    }
  }

  /// SDK name for `xcrun --sdk …`.
  var sdkName: String {
    switch self {
    case .host: return "macosx"
    case .iosSimulator: return "iphonesimulator"
    }
  }
}

// MARK: - ScanToolchain

/// Everything the extraction needs to compile the way the tree's own build
/// does: the SDK/target triple, the platform's product + modulemap directories,
/// and the compilation conditions its Debug products were built with.
nonisolated struct ScanToolchain: Sendable {
  var platform: ScanPlatform
  /// `-sdk` path for a cross-platform build; nil for the host.
  var sdkPath: String?
  /// `-target` triple (`arm64-apple-ios17.0-simulator`); nil for the host.
  var targetTriple: String?
  /// `-D` conditions. The extraction type-checks against DEBUG builds (both
  /// SwiftPM's `debug` configuration and Xcode's Debug), and a package manifest
  /// can declare `#if debug`-only APIs the sources rely on (playgra does:
  /// `ServerManager.apply()` assigns through a member only present in debug),
  /// so the conditions are part of "compiles the way Xcode does".
  var defines: [String] = ["debug", "DEBUG"]
  /// Product directories to put on the module search path, most specific
  /// first. The first one that exists wins for a given module, so a wrong-slice
  /// copy in a later directory cannot shadow a usable one.
  var productDirectoryNames: [String]
  /// Names of the clang modulemap directories to attach, in order.
  var moduleMapDirectoryNames: [String]

  static func host() -> ScanToolchain {
    ScanToolchain(
      platform: .host, sdkPath: nil, targetTriple: nil,
      productDirectoryNames: ["Debug", "debug"],
      moduleMapDirectoryNames: ["GeneratedModuleMaps"])
  }

  static func iosSimulator(doubleTarget: String) -> ScanToolchain {
    let sdk = ScanShell.run(
      "/usr/bin/xcrun", arguments: ["--sdk", "iphonesimulator", "--show-sdk-path"],
      currentDirectory: nil, timeout: 60).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return ScanToolchain(
      platform: .iosSimulator,
      sdkPath: sdk.isEmpty ? nil : sdk,
      targetTriple: doubleTarget,
      productDirectoryNames: ["Debug-iphonesimulator", "debug-iphonesimulator"],
      moduleMapDirectoryNames: ["GeneratedModuleMaps-iphonesimulator"])
  }

  /// A module's file may be compiled either way; the args that select the
  /// platform, ready to append to a swiftc invocation.
  var platformArguments: [String] {
    var args: [String] = []
    if let sdkPath { args += ["-sdk", sdkPath] }
    if let targetTriple { args += ["-target", targetTriple] }
    for define in defines { args += ["-D", define] }
    return args
  }
}

// MARK: - Slice detection

/// Reads a Swift module product's directory to learn which architecture slices
/// exist (`arm64-apple-ios-simulator.swiftmodule`), so the extraction's
/// `-target` matches the products it type-checks against. A mismatch is a hard
/// error with a confusing message ("could not find module 'X' for target
/// 'arm64-apple-ios-simulator'; found: x86_64-…"), and the slices present
/// depend on how the user's Xcode last built (playgra's checked-in products
/// were x86_64-only before an arm64 build refreshed them).
nonisolated enum ScanSliceDetector {
  /// Preferred slice triples for a platform, in order: the host's own
  /// architecture first (Apple Silicon → arm64), then the other one.
  static func hostPreferredArchitectures() -> [String] {
    #if arch(arm64)
    return ["arm64", "x86_64"]
    #else
    return ["x86_64", "arm64"]
    #endif
  }

  /// Slice file names found in any module bundle inside `directory`, e.g.
  /// `["arm64-apple-ios-simulator", "x86_64-apple-ios-simulator"]`.
  static func slices(inProductsDirectory directory: URL, limit: Int = 24) -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    var found: Set<String> = []
    var inspected = 0
    for name in names.sorted() where name.hasSuffix(".swiftmodule") {
      inspected += 1
      if inspected > limit { break }
      let bundle = directory.appendingPathComponent(name)
      let sliceNames = (try? FileManager.default.contentsOfDirectory(atPath: bundle.path)) ?? []
      for slice in sliceNames where slice.hasSuffix(".swiftmodule") {
        found.insert(String(slice.dropLast(".swiftmodule".count)))
      }
    }
    return found.sorted()
  }

  /// The `-target` triple for an iOS-simulator build of `productsDirectory`,
  /// or nil when no iOS-simulator slice is present.
  static func iosSimulatorTriple(
    inProductsDirectory directory: URL, deploymentTarget: String
  ) -> String? {
    let slices = slices(inProductsDirectory: directory)
      .filter { $0.contains("apple-ios") && $0.contains("simulator") }
    guard !slices.isEmpty else { return nil }
    let arch = hostPreferredArchitectures().first { wanted in
      slices.contains { $0.hasPrefix(wanted + "-") }
    } ?? String(slices[0].split(separator: "-").first ?? "arm64")
    return "\(arch)-apple-ios\(deploymentTarget)-simulator"
  }
}

// MARK: - Platform resolution

/// Decides which platform a scan targets, from evidence in the tree rather
/// than a setting: an SDKROOT the project declares, or any module that imports
/// UIKit.
nonisolated enum ScanPlatformResolver {
  /// True when any of `files` uses a macOS-ONLY API — AppKit, either imported
  /// by name or reached through SwiftUI's macOS re-export.
  ///
  /// The distinction decides the platform for a target inside a tree that
  /// builds for both (playgra: an iOS app, an iOS broadcast extension and an
  /// AppKit preview app in one project). Requiring `import AppKit` was not
  /// enough — IconsPreview uses `NSBezierPath` with only `import SwiftUI` — and
  /// treating every unnamed target as macOS was worse: the extension
  /// (Broadcast: `ReplayKit` + `LiveKit`, no UIKit) then compiled for the host
  /// and could not find an iOS-only module.
  static func usesMacOSOnlyAPI(_ files: [URL], limit: Int = 400) -> Bool {
    let markers = [
      "import AppKit",
      "NSBezierPath", "NSView", "NSWindow", "NSApplication", "NSPasteboard",
      "NSScreen", "NSColor", "NSFont", "NSImage",
    ]
    for file in files.prefix(limit) {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      for marker in markers where text.contains(marker) { return true }
    }
    return false
  }

  /// True when any of `files` imports UIKit — the decisive mark of an iOS
  /// target (the macOS counterpart is AppKit). Bounded read: the first match
  /// wins.
  static func importsUIKit(_ files: [URL], limit: Int = 400) -> Bool {
    for file in files.prefix(limit) {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      if text.contains("import UIKit") { return true }
    }
    return false
  }

  /// True when the project declares an iOS SDK for its targets — the decisive
  /// mark of an iOS-only project. `IPHONEOS_DEPLOYMENT_TARGET` alone is NOT
  /// one: a multi-platform project (`SDKROOT = auto`, `SUPPORTED_PLATFORMS =
  /// "iphoneos iphonesimulator macosx …"`) carries that setting while building
  /// for the Mac, and treating it as iOS made a macOS tree compile every unit
  /// against the iOS SDK (`no such module 'AppKit'`).
  static func projectUsesIOSSDK(at projectURL: URL) -> Bool {
    let pbxURL = projectURL.appendingPathComponent("project.pbxproj")
    guard let text = try? String(contentsOf: pbxURL, encoding: .utf8) else { return false }
    return text.contains("SDKROOT = iphoneos;")
  }

  /// iOS deployment target as declared by a project or package, or nil.
  static func deploymentTarget(projectURLs: [URL], packageManifestText: String?) -> String? {
    for projectURL in projectURLs {
      let pbxURL = projectURL.appendingPathComponent("project.pbxproj")
      guard let text = try? String(contentsOf: pbxURL, encoding: .utf8) else { continue }
      if let value = firstMatch(in: text, pattern: "IPHONEOS_DEPLOYMENT_TARGET = ([0-9][0-9.]*);") {
        return value
      }
    }
    if let text = packageManifestText,
       let value = firstMatch(in: text, pattern: "IPHONEOS_DEPLOYMENT_TARGET = ([0-9][0-9.]*);") {
      return value
    }
    return nil
  }

  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          match.numberOfRanges > 1,
          let captured = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[captured])
  }
}

// MARK: - Project Swift settings

/// The Swift build settings a project declares, as swiftc arguments.
///
/// The extraction compiles the target's sources with a raw `swiftc`, so every
/// setting Xcode would pass has to be passed here too or the sources are
/// type-checked in a configuration they were never written for. Dev's own
/// project is the demonstration: with `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` missing, 12 of its files fail to compile ("call to main
/// actor-isolated initializer 'init()' in a synchronous nonisolated context")
/// and the salvage loop drops them.
nonisolated enum ScanSwiftSettings {
  /// Settings read from the project's build configurations. Per-target
  /// overrides are not distinguished — the union is what makes a target's
  /// sources compile, and a stray extra `-D` only widens what type-checks.
  static func arguments(fromProjectAt projectURL: URL) -> [String] {
    let pbxURL = projectURL.appendingPathComponent("project.pbxproj")
    guard let text = try? String(contentsOf: pbxURL, encoding: .utf8) else { return [] }
    var arguments: [String] = []

    if text.contains("SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;") {
      arguments += ["-default-isolation", "MainActor"]
    }
    if text.contains("SWIFT_APPROACHABLE_CONCURRENCY = YES;") {
      // What Xcode 26 passes for the setting; the compiler accepts the feature
      // name on this toolchain (verified).
      arguments += ["-enable-upcoming-feature", "NonisolatedNonsendingByDefault"]
    }
    for name in upcomingFeatures(in: text) {
      arguments += ["-enable-upcoming-feature", name]
    }
    for condition in compilationConditions(in: text) {
      arguments += ["-D", condition]
    }
    return arguments
  }

  /// `SWIFT_UPCOMING_FEATURE_<NAME> = YES;` -> `<NAME>` (CamelCase preserved).
  private static func upcomingFeatures(in text: String) -> [String] {
    matches(in: text, pattern: "SWIFT_UPCOMING_FEATURE_([A-Za-z0-9_]+) = YES;")
  }

  /// Conditions from `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and the `-D` flags
  /// of `OTHER_SWIFT_FLAGS`, minus the `$(inherited)` placeholder.
  private static func compilationConditions(in text: String) -> [String] {
    var names: [String] = []
    for value in matches(in: text, pattern: "SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"([^\"]*)\";") {
      names += value.split(separator: " ").map(String.init)
    }
    for value in matches(in: text, pattern: "OTHER_SWIFT_FLAGS = \"([^\"]*)\";") {
      let tokens = value.split(separator: " ").map(String.init)
      for (index, token) in tokens.enumerated() where token == "-D" && index + 1 < tokens.count {
        names.append(tokens[index + 1])
      }
    }
    return Set(names.filter { !$0.isEmpty && !$0.contains("$(") }).sorted()
  }

  private static func matches(in text: String, pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text)
      else { return nil }
      return String(text[captured])
    }
  }
}
