//
//  ScreenshotProcessor.swift
//  Dev
//

import AppKit
import CoreText
import DevScreenshots
import DevScreenshotsCapture
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Library

/// The screenshots a project has on disk: what `dev-screenshots` captured for the scenes in `.dev/screenshots.json`
/// (`<output>/manifest.json`, `.build/screenshots/` by default) and what `framing` made of them
/// (`<output>/framed/`), with each scene's status against the current commit.
nonisolated struct ScreenshotLibrary: Sendable {
  struct Shot: Identifiable, Hashable, Sendable {
    /// The scene's id.
    let name: String
    let locale: String
    let platform: ScreenshotConfig.Platform
    /// The simulator's name; nil on the Mac.
    let device: String?
    let appearance: ScreenshotConfig.Appearance
    /// The manifest's path, relative to the output folder (`mac/en-US/01-history.png`).
    let file: String
    let captured: URL
    /// The framed picture, when it was rendered after this capture.
    let final: URL?
    let pixelWidth: Int
    let pixelHeight: Int
    /// The framed picture's size: the framing's.
    let framedWidth: Int
    let framedHeight: Int
    let taken: ScreenshotManifest.Taken
    /// The scene's state against the current commit and config.
    let state: ScreenshotStatus.State

    var id: String { file }
    var target: String { device ?? "Mac" }
    var needsCapture: Bool { !state.isCurrent }
    var title: String { appearance == .dark ? "\(name) (Dark)" : name }

    /// The picture to show and its pixel size.
    func picture(framed: Bool) -> (url: URL, width: Int, height: Int) {
      if framed, let final { return (final, framedWidth, framedHeight) }
      return (captured, pixelWidth, pixelHeight)
    }
  }

  let root: URL
  /// nil when the project has no `.dev/screenshots.json`.
  let config: ScreenshotConfig?
  /// Why the file didn't parse.
  let configError: String?
  let status: ScreenshotStatus?
  let locales: [String]
  /// "Mac" and the simulators' names, in the config's order.
  let targets: [String]
  let shots: [Shot]

  var capturedAt: Date? { shots.map(\.taken.date).max() }
  var build: Int? { shots.compactMap(\.taken.build).max() }
  /// The scenes the commits or the config have moved past since their pictures.
  var outdated: [ScreenshotStatus.Scene] { status?.scenes.filter { !$0.state.isCurrent } ?? [] }

  func shots(in locale: String, on target: String? = nil) -> [Shot] {
    shots.filter { $0.locale == locale && (target == nil || $0.target == target) }
  }

  /// The pictures App Store Connect gets, per locale: the framed ones of the first appearance and device.
  func uploadFiles() -> [String: [URL]] {
    let appearance = config?.appearances.first ?? .light
    let framed = shots.filter { $0.final != nil && $0.appearance == appearance }
    let target = framed.first?.target
    return Dictionary(grouping: framed.filter { $0.target == target }, by: \.locale)
      .mapValues { $0.compactMap(\.final) }
  }

  /// Reads what is on disk now: the config, the manifest and git, so off the main actor.
  static func scan(_ root: URL) -> ScreenshotLibrary {
    let config: ScreenshotConfig?
    var configError: String?
    do {
      config = try ScreenshotConfig.load(in: root)
    } catch {
      config = nil
      configError = "\(ScreenshotConfig.path) doesn't read: \(error.localizedDescription)"
    }
    guard let config else {
      return ScreenshotLibrary(
        root: root, config: nil, configError: configError, status: nil, locales: [], targets: [], shots: [])
    }
    let fm = FileManager.default
    let output = config.outputURL(in: root)
    let manifest = ScreenshotManifest.load(in: output) ?? ScreenshotManifest()
    let status = ScreenshotStatus.check(config: config, manifest: manifest, root: root)
    let states = Dictionary(status.scenes.map { ($0.id, $0.state) }) { first, _ in first }
    let order = Dictionary(config.scenes.enumerated().map { ($1.id, $0) }) { first, _ in first }

    let framing = config.framing ?? config.framedPlatform.map(ScreenshotConfig.Framing.starter(for:))
    var shots: [Shot] = []
    // The manifest's pictures of the config's scenes, in its order; removed scenes and deleted files drop out.
    for shot in manifest.shots where order[shot.scene] != nil {
      let captured = output.appendingPathComponent(shot.file)
      guard fm.fileExists(atPath: captured.path) else { continue }
      let framed = config.framedURL(of: shot.file, in: root)
      let rendered = modified(framed).map { $0 >= (modified(captured) ?? .distantPast) } ?? false
      shots.append(Shot(
        name: shot.scene, locale: shot.locale, platform: shot.platform, device: shot.device,
        appearance: shot.appearance, file: shot.file, captured: captured, final: rendered ? framed : nil,
        pixelWidth: shot.width, pixelHeight: shot.height, framedWidth: framing?.width ?? 0,
        framedHeight: framing?.height ?? 0, taken: shot.taken, state: states[shot.scene] ?? .missing))
    }
    let targetOrder = ["Mac"] + (config.ios?.devices ?? [])
    func rank<T: Equatable>(_ value: T, in list: [T]) -> Int { list.firstIndex(of: value) ?? list.count }
    shots.sort {
      ($0.locale, rank($0.target, in: targetOrder), order[$0.name] ?? 0, $0.appearance == .dark ? 1 : 0)
        < ($1.locale, rank($1.target, in: targetOrder), order[$1.name] ?? 0, $1.appearance == .dark ? 1 : 0)
    }
    let present = Set(shots.map(\.locale))
    // The config's locales first, in its order (the development language leads), then any older ones.
    let locales = config.locales.filter(present.contains) + present.subtracting(config.locales).sorted()
    let targets = targetOrder.filter { target in shots.contains { $0.target == target } }
    return ScreenshotLibrary(
      root: root, config: config, configError: nil, status: status, locales: locales, targets: targets, shots: shots)
  }

  static func pixelSize(_ url: URL) -> (Int, Int) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return (0, 0) }
    return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
  }

  private static func modified(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
  }
}

extension ScreenshotStatus.State {
  /// Why the scene needs a new capture, for a tooltip; nil when it doesn't.
  var reason: String? {
    switch self {
    case .current: nil
    case .missing: "Not captured yet"
    case .incomplete(let missing): "\(missing) of its pictures are missing"
    case .changed: "Its arguments or the capture settings changed since"
    case .outdated(let commits?): commits == 1 ? "1 commit since its capture" : "\(commits) commits since its capture"
    case .outdated(nil): "Taken at a commit that is gone"
    }
  }
}

// MARK: - Processor

/// Renders the App Store pictures with the config's `framing`: the background, the scene's caption translated on top,
/// the capture scaled with rounded corners and a shadow. Pure Core Graphics, so it runs off the main actor and in the
/// MCP server alike.
nonisolated enum ScreenshotProcessor {
  struct Report: Sendable {
    var succeeded = true
    var lines: [String] = []
    /// Captions that need more lines than the framing allows: the pictures' manifest paths.
    var overflowing: [String] = []
    var rendered = 0
  }

  /// Frames the latest captures. Without a `framing` section it frames with a starter one, without writing it.
  static func processLatest(in root: URL) async -> Report {
    await Task.detached(priority: .userInitiated) { process(root) }.value
  }

  static func process(_ root: URL) -> Report {
    var report = Report()
    let library = ScreenshotLibrary.scan(root)
    guard let config = library.config else {
      report.succeeded = false
      report.lines.append(library.configError ?? "No \(ScreenshotConfig.path): describe the scenes there first.")
      return report
    }
    guard let platform = config.framedPlatform else {
      report.succeeded = false
      report.lines.append("The config captures on no platform to frame.")
      return report
    }
    let shots = library.shots.filter { $0.platform == platform }
    guard !shots.isEmpty else {
      report.succeeded = false
      report.lines.append("No captured \(platform.rawValue) screenshots: capture first.")
      return report
    }
    let framing = config.framing ?? .starter(for: platform)
    let catalog = CaptionCatalog.load(root.appendingPathComponent(framing.caption.catalog))
    let captions = Dictionary(config.scenes.map { ($0.id, $0.caption) }) { first, _ in first }
    for shot in shots {
      let caption = (captions[shot.name] ?? nil).map { CaptionCatalog.caption($0, locale: shot.locale, in: catalog) }
      do {
        let lines = try render(
          shot.captured, caption: caption, background: framing.background(of: shot.name), framing: framing,
          to: config.framedURL(of: shot.file, in: root))
        if lines > framing.caption.maxLines { report.overflowing.append(shot.file) }
        report.rendered += 1
      } catch {
        report.succeeded = false
        report.lines.append("\(shot.file): \(error.localizedDescription)")
      }
    }
    report.lines.append(
      "Rendered \(report.rendered) pictures at \(framing.width) × \(framing.height) into "
        + "\(config.output)/\(ScreenshotConfig.Framing.folder)")
    for item in report.overflowing { report.lines.append("Caption too long: \(item)") }
    saveReport(report, in: config.framedURL(of: "", in: root))
    return report
  }

  struct RenderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// Draws one picture and answers how many lines its caption took.
  @discardableResult
  static func render(
    _ capture: URL, caption: String?, background: String, framing: ScreenshotConfig.Framing, to target: URL
  ) throws -> Int {
    guard let source = CGImageSourceCreateWithURL(capture as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw RenderError(message: "cannot read the capture") }
    let width = framing.width, height = framing.height
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw RenderError(message: "cannot make a drawing context") }

    context.setFillColor(cgColor(background))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // The caption, centred near the top.
    var captionBottom = CGFloat(height) * (1 - CGFloat(framing.caption.top))
    var lineCount = 0
    if let caption, !caption.isEmpty {
      let system = CTFontCreateUIFontForLanguage(.system, framing.caption.fontSize, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, framing.caption.fontSize, nil)
      let font = framing.caption.bold
        ? (CTFontCreateCopyWithSymbolicTraits(system, 0, nil, .traitBold, .traitBold) ?? system) : system
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .center
      paragraph.lineBreakMode = .byWordWrapping
      let text = NSAttributedString(string: caption, attributes: [
        .font: font as NSFont, .foregroundColor: NSColor(cgColor: cgColor(framing.caption.color)) ?? .white,
        .paragraphStyle: paragraph,
      ])
      let framesetter = CTFramesetterCreateWithAttributedString(text)
      let maxWidth = CGFloat(width) * 0.84
      let fit = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter, CFRange(location: 0, length: 0), nil,
        CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
      let top = CGFloat(height) * (1 - CGFloat(framing.caption.top))
      let rect = CGRect(x: (CGFloat(width) - maxWidth) / 2, y: top - fit.height, width: maxWidth, height: fit.height)
      let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
      lineCount = (CTFrameGetLines(frame) as? [CTLine])?.count ?? 0
      CTFrameDraw(frame, context)
      captionBottom = rect.minY
    }

    // The window: scaled to the framing's width, under the caption.
    let scale = CGFloat(framing.window.scale) * CGFloat(width) / CGFloat(image.width)
    let drawWidth = CGFloat(image.width) * scale
    let drawHeight = CGFloat(image.height) * scale
    let gap = CGFloat(height) * 0.04
    var y: CGFloat
    if framing.window.align == .center {
      y = (captionBottom - gap - drawHeight) / 2
    } else {
      y = captionBottom - gap - drawHeight
    }
    y = min(y, captionBottom - gap - drawHeight)
    let rect = CGRect(x: (CGFloat(width) - drawWidth) / 2, y: y, width: drawWidth, height: drawHeight)
    let radius = CGFloat(framing.window.cornerRadius) * scale * 2
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if framing.window.shadow {
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

  /// The last framing's findings, read by the Screenshots tab's checks.
  struct SavedReport: Codable, Sendable {
    var date: Date
    var rendered: Int
    var overflowing: [String]
    var errors: [String]
  }

  private static func saveReport(_ report: Report, in folder: URL) {
    let saved = SavedReport(date: Date(), rendered: report.rendered, overflowing: report.overflowing,
                            errors: report.succeeded ? [] : report.lines)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? encoder.encode(saved).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
  }

  static func loadReport(in root: URL) -> SavedReport? {
    guard let config = try? ScreenshotConfig.load(in: root),
          let data = try? Data(contentsOf: config.framedURL(of: "report.json", in: root))
    else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SavedReport.self, from: data)
  }
}
