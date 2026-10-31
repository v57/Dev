//
//  Compat.swift
//  Dev
//

import SwiftUI

// MARK: - macOS 15 fallbacks

/// The app runs on macOS 15, and a few views reach for macOS 26 modifiers. Each
/// one goes through here, so the fallback is written once and the call sites read
/// the same on both systems.
extension View {
  /// Liquid Glass on macOS 26; nothing before it, where the shape's own fill shows.
  @ViewBuilder
  func compatInteractiveGlass<S: Shape>(in shape: S) -> some View {
    if #available(macOS 26, *) {
      glassEffect(.regular.interactive(), in: shape)
    } else {
      self
    }
  }
}

/// The flexible space after the toolbar's title on macOS 26, which keeps the tools at the trailing edge (without the
/// system title, the toolbar lines them up right after the kit's); nothing before it, where they sit there already.
struct CompatTitleSpace: ToolbarContent {
  var body: some ToolbarContent {
    if #available(macOS 26, *) {
      ToolbarSpacer(.flexible)
    }
  }
}
