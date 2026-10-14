//
//  ScreenshotProcessor.swift
//  Dev
//

import AppKit
import CoreText
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Library

/// The screenshots a project has on disk: what release.sh's screenshots step
/// captured (`build/release/<version>/screenshots/<locale>/`) and what the
/// recipe made of them (`build/screenshots/<locale>/`).
nonisolated struct ScreenshotLibrary: Sendable {
  struct Shot: Identifiable, Hashable, Sendable {
    /// The scene name: the attachment's name without the test's suffixes.
    let name: String
    let locale: String
    let captured: URL
    /// The post-processed picture, when the recipe has run.
    let final: URL?
    let pixelWidth: Int
    let pixelHeight: Int
    /// True when the capture differs from the same scene in the previous version.
    let changed: Bool

    var id: String { locale + "/" + name }
  }

  let root: URL
  /// The version folder the captures came from (`2.4.2`), or nil when none exist.
  let version: String?
  let capturedAt: Date?
  let locales: [String]
  let shots: [Shot]

  func shots(in locale: String) -> [Shot] { shots.filter { $0.locale == locale } }

  static func finalFolder(in root: URL) -> URL {
    root.appendingPathComponent("build/screenshots", isDirectory: true)
  }

  /// Reads what is on disk now. Cheap: names, image headers and, for the
  /// "changed" flag, a hash of each capture and its previous-version twin.
  static func scan(_ root: URL) -> ScreenshotLibrary {
    let fm = FileManager.default
    let releases = root.appendingPathComponent("build/release", isDirectory: true)
    let versions = ((try? fm.contentsOfDirectory(at: releases, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
      .filter { fm.fileExists(atPath: $0.appendingPathComponent("screenshots").path) }
      .sorted { modified($0) > modified($1) }
    guard let latest = versions.first else {
      return ScreenshotLibrary(root: root, version: nil, capturedAt: nil, locales: [], shots: [])
    }
    let previous = versions.dropFirst().first
    let folder = latest.appendingPathComponent("screenshots", isDirectory: true)
    let locales = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { !$0.hasPrefix(".") }.sorted { lhs, rhs in
        // The development language first, then alphabetical.
        if lhs.hasPrefix("en") != rhs.hasPrefix("en") { return lhs.hasPrefix("en") }
        return lhs < rhs
      }
    var shots: [Shot] = []
    for locale in locales {
      let current = Self.captures(in: folder.appendingPathComponent(locale))
      let earlier = previous.map { Self.captures(in: $0.appendingPathComponent("screenshots/\(locale)")) } ?? [:]
      for (name, url) in current.sorted(by: { $0.key < $1.key }) {
        let size = pixelSize(url)
        let final = finalFolder(in: root).appendingPathComponent("\(locale)/\(name).png")
        var changed = false
        if let before = earlier[name] { changed = digest(url) != digest(before) }
        shots.append(Shot(
          name: name, locale: locale, captured: url,
          final: fm.fileExists(atPath: final.path) ? final : nil,
          pixelWidth: size.0, pixelHeight: size.1, changed: changed))
      }
    }
    return ScreenshotLibrary(
      root: root, version: latest.lastPathComponent, capturedAt: modified(folder),
      locales: locales, shots: shots)
  }

  /// The PNGs xcresulttool exported, by scene name. Its manifest maps the
  /// exported files to the names the test gave them; without one, file names.
  static func captures(in folder: URL) -> [String: URL] {
    let fm = FileManager.default
    var out: [String: URL] = [:]
    if let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
       let json = try? JSONSerialization.jsonObject(with: data) {
      collect(json) { exported, suggested in
        let url = folder.appendingPathComponent(exported)
        guard fm.fileExists(atPath: url.path) else { return }
        out[sceneName(suggested)] = url
      }
    }
    if out.isEmpty {
      for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.lowercased().hasSuffix(".png") {
        out[sceneName(name)] = folder.appendingPathComponent(name)
      }
    }
    return out
  }

  private static func collect(_ json: Any, _ found: (String, String) -> Void) {
    if let dict = json as? [String: Any] {
      if let exported = dict["exportedFileName"] as? String {
        found(exported, dict["suggestedHumanReadableName"] as? String ?? exported)
      }
      dict.values.forEach { collect($0, found) }
    } else if let array = json as? [Any] {
      array.forEach { collect($0, found) }
    }
  }

  /// `01-localization_0_5E0C….png` → `01-localization`.
  static func sceneName(_ fileName: String) -> String {
    var name = (fileName as NSString).deletingPathExtension
    if let match = name.firstMatch(of: #/_\d+_[0-9A-Fa-f-]{8,}$/#) {
      name = String(name[..<match.range.lowerBound])
    }
    return name
  }

  static func pixelSize(_ url: URL) -> (Int, Int) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return (0, 0) }
    return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
  }

  private static func digest(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func modified(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
  }
}

// MARK: - Processor

/// Renders the App Store pictures: the background, the translated caption on
/// top, the capture scaled with rounded corners and a shadow. Pure Core
/// Graphics, so it runs off the main actor and in the MCP server alike.
nonisolated enum ScreenshotProcessor {
  struct Report: Sendable {
    var succeeded = true
    var lines: [String] = []
    /// Captions that need more lines than the recipe allows: locale/scene.
    var overflowing: [String] = []
    var rendered = 0
  }

  /// Processes the latest captures with the project's recipe. Without a recipe
  /// it writes a starter one first, so the result is always a full set.
  static func processLatest(in root: URL) async -> Report {
    await Task.detached(priority: .userInitiated) { process(root) }.value
  }

  static func process(_ root: URL) -> Report {
    var report = Report()
    let library = ScreenshotLibrary.scan(root)
    guard !library.shots.isEmpty else {
      report.succeeded = false
      report.lines.append("No captured screenshots: run the Screenshots step first.")
      return report
    }
    let platform = ReleaseConfig.load(from: root)?["PLATFORM"] ?? "macos"
    var recipe = ScreenshotRecipe.load(in: root)
      ?? ScreenshotRecipe.starter(for: Array(Set(library.shots.map(\.name))).sorted(), platform: platform)
    if ScreenshotRecipe.load(in: root) == nil {
      try? recipe.save(in: root, by: "Dev")
      recipe = ScreenshotRecipe.load(in: root) ?? recipe
    }
    let catalog = CaptionCatalog.load(root.appendingPathComponent(recipe.caption.catalog))
    let out = ScreenshotLibrary.finalFolder(in: root)
    for shot in library.shots {
      let scene = recipe.scene(named: shot.name)
      let caption = scene?.caption.map { CaptionCatalog.caption($0, locale: shot.locale, in: catalog) }
      let target = out.appendingPathComponent("\(shot.locale)/\(shot.name).png")
      do {
        let lines = try render(shot.captured, caption: caption, background: scene?.background ?? recipe.background,
                               recipe: recipe, to: target)
        if lines > recipe.caption.maxLines { report.overflowing.append("\(shot.locale)/\(shot.name)") }
        report.rendered += 1
      } catch {
        report.succeeded = false
        report.lines.append("\(shot.locale)/\(shot.name): \(error.localizedDescription)")
      }
    }
    report.lines.append("Rendered \(report.rendered) pictures at \(recipe.width) × \(recipe.height) into build/screenshots")
    for item in report.overflowing { report.lines.append("Caption too long: \(item)") }
    saveReport(report, in: root)
    return report
  }

  struct RenderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// Draws one picture and answers how many lines its caption took.
  @discardableResult
  static func render(
    _ capture: URL, caption: String?, background: String, recipe: ScreenshotRecipe, to target: URL
  ) throws -> Int {
    guard let source = CGImageSourceCreateWithURL(capture as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw RenderError(message: "cannot read the capture") }
    let width = recipe.width, height = recipe.height
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw RenderError(message: "cannot make a drawing context") }

    context.setFillColor(cgColor(background))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // The caption, centred near the top.
    var captionBottom = CGFloat(height) * (1 - CGFloat(recipe.caption.top))
    var lineCount = 0
    if let caption, !caption.isEmpty {
      let system = CTFontCreateUIFontForLanguage(.system, recipe.caption.fontSize, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, recipe.caption.fontSize, nil)
      let font = recipe.caption.bold
        ? (CTFontCreateCopyWithSymbolicTraits(system, 0, nil, .traitBold, .traitBold) ?? system) : system
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .center
      paragraph.lineBreakMode = .byWordWrapping
      let text = NSAttributedString(string: caption, attributes: [
        .font: font as NSFont, .foregroundColor: NSColor(cgColor: cgColor(recipe.caption.color)) ?? .white,
        .paragraphStyle: paragraph,
      ])
      let framesetter = CTFramesetterCreateWithAttributedString(text)
      let maxWidth = CGFloat(width) * 0.84
      let fit = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter, CFRange(location: 0, length: 0), nil,
        CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
      let top = CGFloat(height) * (1 - CGFloat(recipe.caption.top))
      let rect = CGRect(x: (CGFloat(width) - maxWidth) / 2, y: top - fit.height, width: maxWidth, height: fit.height)
      let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
      lineCount = (CTFrameGetLines(frame) as? [CTLine])?.count ?? 0
      CTFrameDraw(frame, context)
      captionBottom = rect.minY
    }

    // The window: scaled to the recipe's width, under the caption.
    let scale = CGFloat(recipe.window.scale) * CGFloat(width) / CGFloat(image.width)
    let drawWidth = CGFloat(image.width) * scale
    let drawHeight = CGFloat(image.height) * scale
    let gap = CGFloat(height) * 0.04
    var y: CGFloat
    if recipe.window.align == "center" {
      y = (captionBottom - gap - drawHeight) / 2
    } else {
      y = captionBottom - gap - drawHeight
    }
    y = min(y, captionBottom - gap - drawHeight)
    let rect = CGRect(x: (CGFloat(width) - drawWidth) / 2, y: y, width: drawWidth, height: drawHeight)
    let radius = CGFloat(recipe.window.cornerRadius) * scale * 2
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if recipe.window.shadow {
      context.saveGState()
      context.setShadow(offset: CGSize(width: 0, height: -CGFloat(height) * 0.01),
                        blur: CGFloat(height) * 0.03, color: CGColor(gray: 0, alpha: 0.45))
      context.addPath(path)
      context.setFillColor(CGColor(gray: 0, alpha: 1))
      context.fillPath()
      context.restoreGState()
    }
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    context.restoreGState()

    guard let output = context.makeImage() else { throw RenderError(message: "cannot finish the picture") }
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw RenderError(message: "cannot write \(target.lastPathComponent)") }
    CGImageDestinationAddImage(destination, output, nil)
    guard CGImageDestinationFinalize(destination) else { throw RenderError(message: "cannot write \(target.lastPathComponent)") }
    return lineCount
  }

  /// `#RRGGBB` → sRGB; anything else is black.
  static func cgColor(_ hex: String) -> CGColor {
    var value: UInt64 = 0
    let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else {
      return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    }
    return CGColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  // MARK: - report

  /// The last processing's findings, read by the Screenshots tab's checks.
  struct SavedReport: Codable, Sendable {
    var date: Date
    var rendered: Int
    var overflowing: [String]
    var errors: [String]
  }

  static func reportURL(in root: URL) -> URL {
    ScreenshotLibrary.finalFolder(in: root).appendingPathComponent("report.json")
  }

  private static func saveReport(_ report: Report, in root: URL) {
    let saved = SavedReport(date: Date(), rendered: report.rendered, overflowing: report.overflowing,
                            errors: report.succeeded ? [] : report.lines)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try? encoder.encode(saved).write(to: reportURL(in: root), options: .atomic)
  }

  static func loadReport(in root: URL) -> SavedReport? {
    guard let data = try? Data(contentsOf: reportURL(in: root)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SavedReport.self, from: data)
  }
}
