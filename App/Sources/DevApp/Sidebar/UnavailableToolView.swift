//
//  UnavailableToolView.swift
//  Dev
//

import ComponentKit
import DevDesktop
import SwiftUI

/// A tool this system lacks (the Mac-only ones: App Icon, Screenshots, Storage, Virtual Machines), in its pane's
/// place: what it needs and why.
struct UnavailableToolView: View {
  /// The tool's name, for accessibility (the window's title already shows it).
  let title: String
  let systemImage: String
  let reason: String

  var body: some View {
    EmptyState(
      systemImage: systemImage, title: "Available on \(DevCapabilities.requiredSystem)", message: reason
    )
    .accessibilityLabel("\(title) is available on \(DevCapabilities.requiredSystem)")
    .kitPane()
  }
}

extension UnavailableToolView {
  /// App Icon, with or without a project.
  static var appIcon: UnavailableToolView {
    UnavailableToolView(
      title: "App Icon", systemImage: "app.badge",
      reason: "Dev draws icons from SF Symbols and compiles them with Xcode's actool.")
  }
}
