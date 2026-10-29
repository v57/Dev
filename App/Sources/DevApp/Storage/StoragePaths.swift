//
//  StoragePaths.swift
//  Dev
//

import Foundation

nonisolated extension String {
  /// True when `self` is `ancestor` or lies inside it, comparing whole path
  /// components (`/a/bc` is not inside `/a/b`).
  func isInside(_ ancestor: String) -> Bool {
    guard hasPrefix(ancestor) else { return false }
    if count == ancestor.count { return true }
    return ancestor.hasSuffix("/") || self[index(startIndex, offsetBy: ancestor.count)] == "/"
  }

  /// `~/…` for paths in the home folder: shorter on screen, same meaning.
  var abbreviatingHome: String {
    let home = NSHomeDirectory()
    guard !home.isEmpty, isInside(home) else { return self }
    return "~" + dropFirst(home.count)
  }
}
