// swift-tools-version:5.9
import PackageDescription

// xcstrings-merge: scan Swift packages in a repo tree, extract localizable
// keys (LocalizedStringKey / String(localized:) / LocalizedStringResource /
// Text literal mechanism) via the Swift toolchain, and merge them into one
// .xcstrings String Catalog without clobbering existing translations.

let package = Package(
  name: "xcstrings-merge",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "xcstrings-merge", targets: ["xcstrings-merge"])
  ],
  targets: [
    .executableTarget(name: "xcstrings-merge")
  ]
)
