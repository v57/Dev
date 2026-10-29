//
//  AppContext.swift
//  Dev
//

import Foundation

/// The main window's shared stores, for the scenes that do not live inside it:
/// the Settings window (clearing the translation store) and the menu commands.
/// ContentView fills it on appear; the references are weak, so a closed window
/// leaves them empty and the callers say so.
@MainActor
final class AppContext {
  static let shared = AppContext()

  weak var localization: LocalizationStore?
  weak var shell: Translation.Shell?
  weak var sidebar: SidebarViewModel?

  private init() {}
}
