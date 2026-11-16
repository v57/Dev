//
//  SourceIndex.swift
//  Dev
//
//  Where a catalog key is written in the project's Swift code. A string's file is the best
//  context a catalog does not carry: strings of one file are one screen, and the file's name
//  says which. A language batch is ordered by it and names it (`Prompt.itemLines`).
//
//  The read is lexical and deliberately rough: every string literal of every Swift file
//  under the roots, normalized the way the compiler turns a literal into a key (an
//  interpolation is a format specifier), and matched against the catalog's keys the same
//  way. A key no literal matches has no location and is batched after the rest.
//

import Foundation

extension Translation {
  nonisolated enum SourceIndex {
    struct Location: Hashable, Sendable {
      /// The file's path from its module on (`DevApp/Sidebar/ProjectRow.swift`), or under
      /// its root with the root's own name first.
      let file: String
      let line: Int
    }

    /// Folders that hold no source of the project's own.
    static let skipped: Set<String> = [
      ".build", ".git", ".swiftpm", "build", "Build", "DerivedData", "Pods", "Carthage", "node_modules",
      "checkouts", "SourcePackages", "Tests", "UITests",
    ]

    /// The first place each key is written, for the keys any literal matches.
    static func locations(of keys: Set<String>, in roots: [URL]) -> [String: Location] {
      var wanted: [String: [String]] = [:]
      for key in keys { wanted[normalizedKey(key), default: []].append(key) }
      var found: [String: Location] = [:]
      for root in roots {
        let base = root.standardizedFileURL
        guard
          let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { continue }
        for case let url as URL in walker {
          if skipped.contains(url.lastPathComponent) || url.lastPathComponent.hasSuffix("Tests") {
            walker.skipDescendants()
            continue
          }
          guard url.pathExtension == "swift",
            let text = try? String(contentsOf: url, encoding: .utf8)
          else { continue }
          let relative = shortPath(
            base.lastPathComponent + "/" + url.standardizedFileURL.path.dropFirst(base.path.count).drop { $0 == "/" })
          for literal in literals(in: text) {
            guard let keys = wanted[literal.text] else { continue }
            for key in keys where found[key] == nil {
              found[key] = Location(file: relative, line: literal.line)
            }
          }
          if found.count == keys.count { return found }
        }
      }
      return found
    }

    /// A path from its module on: what follows `Sources/` (`DevApp/Storage/StoragePages.swift`),
    /// or the path under the root when it has no `Sources` folder.
    static func shortPath(_ path: String) -> String {
      let parts = path.split(separator: "/")
      guard let sources = parts.lastIndex(of: "Sources"), sources + 1 < parts.count else { return path }
      return parts[(sources + 1)...].joined(separator: "/")
    }

    // MARK: - normalizing

    /// A key as a literal would read: every format specifier one marker.
    static func normalizedKey(_ key: String) -> String {
      key.replacingOccurrences(
        of: #"%(?:\d+\$)?[-+#0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|j|t|L)?[diouxXeEfgGaAcCsSp@]"#,
        with: "\u{1}", options: .regularExpression)
    }

    /// The single-line string literals of a Swift file, interpolations as one marker and
    /// escapes resolved, with the line each starts on. Comments are skipped.
    static func literals(in source: String) -> [(text: String, line: Int)] {
      var found: [(String, Int)] = []
      let characters = Array(source.unicodeScalars)
      var index = 0
      var line = 1
      func peek(_ offset: Int) -> Unicode.Scalar? {
        index + offset < characters.count ? characters[index + offset] : nil
      }
      while index < characters.count {
        let character = characters[index]
        if character == "\n" {
          line += 1
          index += 1
        } else if character == "/", peek(1) == "/" {
          while index < characters.count, characters[index] != "\n" { index += 1 }
        } else if character == "/", peek(1) == "*" {
          index += 2
          while index < characters.count, !(characters[index] == "*" && peek(1) == "/") {
            if characters[index] == "\n" { line += 1 }
            index += 1
          }
          index += 2
        } else if character == "\"", peek(1) == "\"", peek(2) == "\"" {
          // A multi-line literal: skipped, its lines counted.
          index += 3
          while index < characters.count, !(characters[index] == "\"" && peek(1) == "\"" && peek(2) == "\"") {
            if characters[index] == "\n" { line += 1 }
            index += 1
          }
          index += 3
        } else if character == "\"" {
          index += 1
          if let text = readLiteral(characters, &index) { found.append((text, line)) }
        } else {
          index += 1
        }
      }
      return found
    }

    /// One literal from just after its opening quote to just after its closing one; nil
    /// for one that runs into a line break (not a single-line literal).
    private static func readLiteral(_ characters: [Unicode.Scalar], _ index: inout Int) -> String? {
      var text = String.UnicodeScalarView()
      while index < characters.count {
        let character = characters[index]
        if character == "\n" { return nil }
        if character == "\"" {
          index += 1
          return String(text)
        }
        if character == "\\", index + 1 < characters.count {
          let next = characters[index + 1]
          index += 2
          switch next {
          case "(":
            // An interpolation, nested parentheses and strings included.
            var depth = 1
            while index < characters.count, depth > 0 {
              let inner = characters[index]
              if inner == "\n" { return nil }
              if inner == "(" { depth += 1 }
              if inner == ")" { depth -= 1 }
              if inner == "\"" {
                index += 1
                _ = readLiteral(characters, &index)
                continue
              }
              index += 1
            }
            text.append("\u{1}")
          case "n": text.append("\n")
          case "t": text.append("\t")
          case "\"": text.append("\"")
          case "\\": text.append("\\")
          case "'": text.append("'")
          case "0": text.append("\0")
          case "u":
            // \u{…}
            var digits = ""
            if index < characters.count, characters[index] == "{" {
              index += 1
              while index < characters.count, characters[index] != "}" {
                digits.unicodeScalars.append(characters[index])
                index += 1
              }
              index += 1
            }
            if let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) { text.append(scalar) }
          default: text.append(next)
          }
          continue
        }
        text.append(character)
        index += 1
      }
      return nil
    }
  }
}
