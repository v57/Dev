//
//  StoragePermissions.swift
//  Dev
//

import ComponentKit
import SwiftUI
import Foundation

/// Full Disk Access: what lets the scan into the folders macOS keeps from
/// apps — browser profiles, other apps' containers, Mail and Messages, iOS
/// backups, the Trash. There is no API that asks; the test is to open a file
/// only Full Disk Access can read.
nonisolated enum FullDiskAccess {
  static var isGranted: Bool {
    let home = NSHomeDirectory()
    for probe in [
      "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
      "\(home)/Library/Safari/CloudTabs.db",
      "\(home)/Library/Safari/Bookmarks.plist",
    ] {
      let descriptor = open(probe, O_RDONLY)
      if descriptor >= 0 {
        close(descriptor)
        return true
      }
      // Only "not permitted" means no access; a missing probe says nothing.
      if errno == EPERM || errno == EACCES { return false }
    }
    return false
  }

  /// Privacy & Security › Full Disk Access.
  @MainActor
  static func openSettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    KitDesktop.open(url)
  }

  /// Privacy & Security › App Management: what moving another app's bundle
  /// to the Trash needs.
  @MainActor
  static func openAppManagementSettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
    KitDesktop.open(url)
  }
}

/// The places only Full Disk Access can read. Added to a scan only when the
/// access is there: without it every one of them measures as nothing, and
/// some (another app's container) would raise a permission prompt per app.
nonisolated extension StorageDiscovery {
  mutating func addProtected() {
    addChromiumProfiles()
    folder(.web, "Browser Caches", "Safari (container)",
      "Library/Containers/com.apple.Safari/Data/Library/Caches", .cache)

    folder(.appData, "Mail & Messages", "Mail downloads",
      "Library/Containers/com.apple.mail/Data/Library/Mail Downloads", .cache,
      detail: "Attachments Mail saved when you opened them")
    folder(.appData, "Mail & Messages", "Mail", "Library/Mail", .data,
      cleanup: .revealOnly(reason: "Manage mailboxes from Mail"))
    folder(.appData, "Mail & Messages", "Messages attachments", "Library/Messages/Attachments", .data,
      cleanup: .revealOnly(reason: "Use Messages › Settings › Keep Messages, or remove large attachments in System Settings › General › Storage"))
  }

  /// Chromium-family profiles keep their heaviest caches beside the profile
  /// itself, not in ~/Library/Caches: the service-worker cache (offline web
  /// apps), the shader caches, and Chrome's on-device AI model.
  private mutating func addChromiumProfiles() {
    let browsers = [
      ("Chrome", "Google/Chrome"), ("Chrome Canary", "Google/Chrome Canary"),
      ("Brave", "BraveSoftware/Brave-Browser"), ("Edge", "Microsoft Edge"),
      ("Vivaldi", "Vivaldi"), ("Arc", "Arc/User Data"), ("Chromium", "Chromium"),
    ]
    for (browser, folder) in browsers {
      let root = h("Library/Application Support/\(folder)")
      guard isDirectory(root) else { continue }
      let names = Self.chromiumProfileNames(root: root)

      for profile in children(of: root) where exists(profile + "/Preferences") {
        let id = (profile as NSString).lastPathComponent
        let label = "\(browser) · \(names[id] ?? id)"
        for (cache, title) in [
          ("Service Worker/CacheStorage", "service worker cache"),
          ("Service Worker/ScriptCache", "service worker scripts"),
          ("Cache", "cache"), ("Code Cache", "code cache"), ("GPUCache", "GPU cache"),
          ("IndexedDB", "IndexedDB"),
        ] {
          // IndexedDB is site data (offline docs, drafts), not a cache.
          let safety: StorageSafety = cache == "IndexedDB" ? .data : .cache
          self.folder(.web, "Browser Profiles", "\(label) \(title)", "\(profile)/\(cache)", safety,
            minBytes: 5_000_000)
        }
      }
      for shader in ["GrShaderCache", "GraphiteDawnCache", "ShaderCache", "component_crx_cache"] {
        self.folder(.web, "Browser Profiles", "\(browser) \(shader)", "\(root)/\(shader)", .cache,
          minBytes: 5_000_000)
      }
      self.folder(.aiModels, "Local models", "\(browser) on-device model", "\(root)/OptGuideOnDeviceModel",
        .rebuildable, detail: "Gemini Nano, downloaded again when a site asks for it")
    }
  }

  /// Profile folder → the name the browser shows ("Default" → "Work").
  private static func chromiumProfileNames(root: String) -> [String: String] {
    guard let data = FileManager.default.contents(atPath: root + "/Local State"),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let profile = json["profile"] as? [String: Any],
      let cache = profile["info_cache"] as? [String: [String: Any]]
    else { return [:] }
    return cache.compactMapValues { $0["name"] as? String }
  }

  /// Sandboxed apps' containers that no app row claimed. Apple's own are
  /// left to the rules above (Mail, Safari) and to the system.
  mutating func addContainers() {
    for (folder, group) in [("Containers", "App Containers"), ("Group Containers", "App Containers")] {
      for path in children(of: h("Library/\(folder)")) where isDirectory(path) {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("com.apple."), !name.contains(".com.apple."), !isCovered(path) else { continue }
        add(StorageItem(
          id: path, category: Self.assistant(named: name) ?? .appData, group: group, title: name,
          detail: folder == "Containers" ? "Sandbox container" : "Shared app-group container",
          paths: [path], safety: .data, cleanup: .trash, minBytes: 50_000_000))
      }
    }
  }
}
