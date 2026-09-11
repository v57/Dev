//
//  ScanXcodeProject.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import Foundation

/// One Xcode target the scan compiles as a module of its own.
nonisolated struct ScanXcodeTarget: Identifiable {
  var projectName: String
  var name: String
  /// Synchronized root groups (Xcode 16 `PBXFileSystemSynchronizedRootGroup`)
  /// — scanned recursively.
  var directories: [URL]
  /// Classic targets: the exact source files listed in the sources build
  /// phase (resolved through the pbxproj group chain).
  var files: [URL]

  var id: String { "\(projectName)/\(name)" }
}

/// Reads an `.xcodeproj`'s project file to learn which directories/files
/// belong to which Xcode target — the app-target half of the scan (a SwiftPM
/// package holds only the library modules; the app's own sources live in the
/// Xcode project and are never part of any `Package.swift`).
///
/// This is a deliberately small subset of the pbxproj (NeXTSTEP plist)
/// format: object bodies are brace-scanned, fields read as scalars and
/// lists, and paths resolved by walking the group chain up to the main
/// group. Targets that are test bundles are skipped.
nonisolated enum ScanXcodeProject {
  /// Directory names never descended into while looking for projects.
  private static let skippedDirectoryNames: Set<String> = [
    ".build", ".git", ".svn", ".hg", ".swiftpm",
    "Packages", "DerivedData", "build", "checkouts", "xcuserdata",
  ]

  /// Every `*.xcodeproj` bundle under `root` (artifact dirs skipped).
  static func findProjects(under root: URL) -> [URL] {
    var results: [URL] = []
    var stack: [URL] = [root.standardizedFileURL]

    while let directory = stack.popLast() {
      let contents = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )) ?? []
      for item in contents {
        let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDirectory else { continue }
        if item.pathExtension == "xcodeproj" {
          results.append(item.standardizedFileURL)
          continue  // never descend into the bundle
        }
        let isLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        let name = item.lastPathComponent
        if !isLink, !skippedDirectoryNames.contains(name) {
          stack.append(item)
        }
      }
    }
    return results.sorted { $0.path < $1.path }
  }

  /// The project's development region (`developmentRegion` on its
  /// `PBXProject` object), or nil when the tree holds no project that
  /// declares one. This is the language Xcode treats as the source of a new
  /// String Catalog, so a generated catalog is authored in the same language
  /// the project's own `.xcstrings` would be.
  static func developmentRegion(under root: URL) -> String? {
    for projectURL in findProjects(under: root) {
      let pbxURL = projectURL.appendingPathComponent("project.pbxproj")
      guard let text = try? String(contentsOf: pbxURL, encoding: .utf8) else { continue }
      let objects = parseObjects(text)
      guard let project = objects.values.first(where: { $0.isa == "PBXProject" }),
            let region = project.scalars["developmentRegion"],
            !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      return region
    }
    return nil
  }

  /// The scannable targets of one project bundle.
  static func targets(inProjectAt projectURL: URL) -> [ScanXcodeTarget] {
    let projectDirectory = projectURL.deletingLastPathComponent()
    let projectName = projectURL.deletingPathExtension().lastPathComponent
    let pbxURL = projectURL.appendingPathComponent("project.pbxproj")
    guard let text = try? String(contentsOf: pbxURL, encoding: .utf8) else { return [] }

    let objects = parseObjects(text)
    guard !objects.isEmpty else { return [] }

    // Parent map (children -> parent) for group-chain path resolution.
    var parentOf: [String: String] = [:]
    for object in objects.values {
      for child in object.lists["children"] ?? [] where parentOf[child] == nil {
        parentOf[child] = object.id
      }
    }

    let appTargets = objects.values
      .filter { $0.isa == "PBXNativeTarget" }
      .filter { target in
        let productType = target.scalars["productType"] ?? ""
        return !productType.contains("test") && !productType.contains("aggregate")
      }

    var targets: [ScanXcodeTarget] = []
    for target in appTargets {
      let name = target.scalars["name"] ?? target.scalars["productName"] ?? target.id
      var directories: [URL] = []
      for groupID in target.lists["fileSystemSynchronizedGroups"] ?? [] {
        guard let url = resolve(
          groupID, objects: objects, parentOf: parentOf,
          mainGroup: mainGroupID(objects: objects), projectDirectory: projectDirectory)
        else { continue }
        if directories.contains(url) == false {
          directories.append(url)
        }
      }

      var files: [URL] = []
      let buildPhaseIDs = target.lists["buildPhases"] ?? []
      let sourcePhaseIDs = buildPhaseIDs.filter { objects[$0]?.isa == "PBXSourcesBuildPhase" }
      for phaseID in sourcePhaseIDs {
        guard let phase = objects[phaseID] else { continue }
        for buildFileID in phase.lists["files"] ?? [] {
          guard let buildFile = objects[buildFileID],
                let fileRefID = buildFile.scalars["fileRef"],
                let fileRef = objects[fileRefID],
                fileRef.isa == "PBXFileReference"
          else { continue }
          guard let url = resolve(
            fileRefID, objects: objects, parentOf: parentOf,
            mainGroup: mainGroupID(objects: objects), projectDirectory: projectDirectory)
          else { continue }
          guard url.pathExtension.lowercased() == "swift" else { continue }
          if files.contains(url) == false {
            files.append(url)
          }
        }
      }

      directories.sort { $0.path < $1.path }
      files.sort { $0.path < $1.path }
      guard !directories.isEmpty || !files.isEmpty else { continue }
      targets.append(
        ScanXcodeTarget(
          projectName: projectName, name: name,
          directories: directories, files: files))
    }
    return targets.sorted { $0.id < $1.id }
  }

  // MARK: - path resolution

  /// Resolves an object's filesystem URL by walking its group chain up to the
  /// main group, joining every `path` component (groups without a `path`
  /// contribute nothing). Nodes whose `sourceTree` is not group-relative are
  /// not resolvable here and return nil.
  private static func resolve(
    _ id: String,
    objects: [String: PbxObject],
    parentOf: [String: String],
    mainGroup: String?,
    projectDirectory: URL
  ) -> URL? {
    var components: [String] = []
    var current: String? = id
    var isAbsolute = false
    var sourceRoot = false

    while let nodeID = current, let object = objects[nodeID] {
      let sourceTree = object.scalars["sourceTree"] ?? "<group>"
      if let path = object.scalars["path"], !path.isEmpty {
        switch sourceTree {
        case "<group>":
          components.insert(path, at: 0)
        case "SOURCE_ROOT":
          components.insert(path, at: 0)
          sourceRoot = true
        case "<absolute>":
          components = [path]
          isAbsolute = true
        default:
          return nil  // SDKROOT / BUILT_PRODUCTS_DIR / DEVELOPER_DIR …
        }
      }
      if sourceRoot || isAbsolute { break }
      if nodeID == mainGroup { break }
      current = parentOf[nodeID]
    }

    guard !components.isEmpty else { return nil }
    let joined = components.joined(separator: "/")
    if isAbsolute { return URL(fileURLWithPath: joined).standardizedFileURL }
    return projectDirectory.appendingPathComponent(joined).standardizedFileURL
  }

  private static func mainGroupID(objects: [String: PbxObject]) -> String? {
    objects.values.first { $0.isa == "PBXProject" }?.scalars["mainGroup"]
  }

  // MARK: - pbxproj (subset) parsing

  private struct PbxObject {
    var id: String
    var isa: String
    var scalars: [String: String] = [:]
    var lists: [String: [String]] = [:]
  }

  /// Every `ID /* name */ = { … };` object in the file, with its `isa`,
  /// scalar fields and list fields. Driven by the object-id pattern rather
  /// than a linear brace walk, so the file's top-level wrapper (and any
  /// object nested inside another) is handled for free.
  private static func parseObjects(_ text: String) -> [String: PbxObject] {
    var objects: [String: PbxObject] = [:]
    let pattern = "\\b([0-9A-Fa-f]{8,})[ \\t]*(?:/\\*[^*]*\\*/[ \\t]*)?=[ \\t]*\\{"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return objects }
    let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)

    for match in regex.matches(in: text, range: searchRange) {
      guard let idRange = Range(match.range(at: 1), in: text),
            let openRange = Range(match.range, in: text),
            let body = balancedBody(text, from: openRange.upperBound)
      else { continue }
      let id = String(text[idRange])
      let fields = parseFields(body.text)
      guard let isa = fields.scalars["isa"] else { continue }
      objects[id] = PbxObject(id: id, isa: isa, scalars: fields.scalars, lists: fields.lists)
    }
    return objects
  }

  /// Text between a `{` and its matching `}` (quotes and comments ignored).
  /// `start` is the index just AFTER the outer `{`.
  private static func balancedBody(
    _ text: String,
    from start: String.Index
  ) -> (text: String, end: String.Index)? {
    var depth = 1
    var index = start
    var inString = false
    var escaped = false
    var inLineComment = false
    var inBlockComment = false

    while index < text.endIndex {
      let character = text[index]
      let next = text.index(after: index)

      if inLineComment {
        if character == "\n" { inLineComment = false }
      } else if inBlockComment {
        if character == "*", next < text.endIndex, text[next] == "/" {
          inBlockComment = false
          index = next
        }
      } else if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
      } else {
        switch character {
        case "\"":
          inString = true
        case "/" where next < text.endIndex && text[next] == "/":
          inLineComment = true
        case "/" where next < text.endIndex && text[next] == "*":
          inBlockComment = true
        case "{":
          depth += 1
        case "}":
          depth -= 1
          if depth == 0 {
            return (String(text[start..<index]), next)
          }
        default:
          break
        }
      }
      index = next
    }
    return nil
  }

  /// Scalar (`key = value;`) and list (`key = (a, b,);`) fields of one body.
  private static func parseFields(_ body: String) -> (scalars: [String: String], lists: [String: [String]]) {
    let cleaned = body.replacingOccurrences(
      of: "/\\*.*?\\*/", with: " ", options: .regularExpression)
    var scalars: [String: String] = [:]
    var lists: [String: [String]] = [:]

    if let listRegex = try? NSRegularExpression(
      pattern: "([A-Za-z_][A-Za-z0-9_]*)[ \\t\\n]*=[ \\t\\n]*\\(([^)]*)\\)[ \\t\\n]*;",
      options: [.dotMatchesLineSeparators]) {
      let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
      for match in listRegex.matches(in: cleaned, range: range) {
        guard let keyRange = Range(match.range(at: 1), in: cleaned),
              let valueRange = Range(match.range(at: 2), in: cleaned)
        else { continue }
        let key = String(cleaned[keyRange])
        let items = cleaned[valueRange]
          .split(separator: ",")
          .map { $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "" }
          .filter { !$0.isEmpty }
        lists[key] = items
      }
    }

    if let scalarRegex = try? NSRegularExpression(
      pattern: "([A-Za-z_][A-Za-z0-9_]*)[ \\t\\n]*=[ \\t\\n]*([^;()]*);",
      options: [.dotMatchesLineSeparators]) {
      let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
      for match in scalarRegex.matches(in: cleaned, range: range) {
        guard let keyRange = Range(match.range(at: 1), in: cleaned),
              let valueRange = Range(match.range(at: 2), in: cleaned)
        else { continue }
        let key = String(cleaned[keyRange])
        let value = String(cleaned[valueRange])
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        scalars[key] = value
      }
    }
    return (scalars, lists)
  }
}
