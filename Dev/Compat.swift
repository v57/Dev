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
  /// `safeAreaBar` on macOS 26 (the bar blurs the content scrolling under it);
  /// `safeAreaInset` before it, which reserves the same space without the blur.
  @ViewBuilder
  func compatSafeAreaBar<Content: View>(
    edge: VerticalEdge, @ViewBuilder content: () -> Content
  ) -> some View {
    if #available(macOS 26, *) {
      safeAreaBar(edge: edge, content: content)
    } else {
      safeAreaInset(edge: edge, spacing: 0, content: content)
    }
  }

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
