//
//  IconGenerator.swift
//  Dev
//
//  An app icon from flat sources (one background color, one glyph color, opacity allowed) in the style Icon
//  Composer gives them: the export is an `AppIcon.icon` with Liquid Glass (top light, translucent glyph, shadow,
//  specular edge), and actool's render of it is the preview and the AppIcon set for older systems.
//

import AppKit
import SwiftUI
import Foundation

enum IconError: Error, CustomStringConvertible {
  case symbolNotFound(String)
  case renderFailed(String)
  case emptyGlyph(String)
  case outputFailed(String)
  case actoolFailed(String)

  var description: String {
    switch self {
    case .symbolNotFound(let s): return "SF Symbol \"\(s)\" not found on this system"
    case .renderFailed(let s): return "Could not render SF Symbol \"\(s)\""
    case .emptyGlyph(let s): return "SF Symbol \"\(s)\" produced an empty glyph"
    case .outputFailed(let c): return "Could not write the \(c)"
    case .actoolFailed(let output): return "actool could not render the icon (Xcode 26 or later is needed): \(output)"
    }
  }
}

/// Renders an SF Symbol glyph (centered, sized to the longest painted edge)
/// into a square, transparent bitmap. Ported from ../AppIcon SymbolRenderer.
enum SymbolRenderer {

  /// Draw `symbol` into a `canvas × canvas` bitmap with the glyph's longest side
  /// equal to `glyphPixels`, centered on both axes. Returns RGBA8 bitmap bytes
  /// plus the measured glyph box (for diagnostics). (Original target-fit path.)
  static func renderOld(
    symbol: String,
    canvas: Int,
    glyphPixels: Int,
    weight: NSFont.Weight = .regular
  ) throws -> (bitmap: NSBitmapImageRep, glyph: (w: Int, h: Int, cx: Int, cy: Int)) {
    guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
      throw IconError.symbolNotFound(symbol)
    }

    let refPointSize: CGFloat = 400
    let cfg = NSImage.SymbolConfiguration(pointSize: refPointSize, weight: weight)
    guard let sym = base.withSymbolConfiguration(cfg) else {
      throw IconError.renderFailed(symbol)
    }

    let symSize = sym.size
    let probeCanvas = Int(ceil(max(symSize.width, symSize.height))) * 2
    let probe = makeBitmap(canvas: probeCanvas)
    draw(sym, in: probe, canvas: probeCanvas)

    let glyph = measureOpaque(probe)
    guard glyph.w > 0, glyph.h > 0 else {
      throw IconError.emptyGlyph(symbol)
    }
    let longest = max(glyph.w, glyph.h)
    let scale = Double(glyphPixels) / Double(longest)

    let final = makeBitmap(canvas: canvas)
    let targetPoint = CGFloat(Double(refPointSize) * scale)
    let cfg2 = NSImage.SymbolConfiguration(pointSize: targetPoint, weight: weight)
    if let sym2 = base.withSymbolConfiguration(cfg2) {
      draw(sym2, in: final, canvas: canvas)
    }
    let finalGlyph = measureOpaque(final)
    return (final, finalGlyph)
  }

  /// Draw `symbol` centered on a `canvas × canvas` bitmap at the given POINT SIZE
  /// (same semantics as SwiftUI `Image.font(.system(size:))`). This keeps the
  /// preview and export glyphs at exactly the size the live view shows, instead
  /// of shrink-to-fitting the longest painted edge (which can read smaller).
  static func renderSized(
    symbol: String,
    canvas: Int,
    pointSize: CGFloat,
    weight: NSFont.Weight = .regular
  ) throws -> (bitmap: NSBitmapImageRep, glyph: (w: Int, h: Int, cx: Int, cy: Int)) {
    guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
      throw IconError.symbolNotFound(symbol)
    }
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let sym = base.withSymbolConfiguration(cfg) else {
      throw IconError.renderFailed(symbol)
    }

    let final = makeBitmap(canvas: canvas)
    draw(sym, in: final, canvas: canvas)
    let finalGlyph = measureOpaque(final)
    return (final, finalGlyph)
  }

  private static func makeBitmap(canvas: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: canvas,
      pixelsHigh: canvas,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )!
  }

  private static func draw(_ image: NSImage, in rep: NSBitmapImageRep, canvas: Int) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = image.size
    let rect = NSRect(
      x: (Double(canvas) - Double(s.width)) / 2,
      y: (Double(canvas) - Double(s.height)) / 2,
      width: Double(s.width),
      height: Double(s.height)
    )
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
  }

  private static func measureOpaque(_ rep: NSBitmapImageRep) -> (w: Int, h: Int, cx: Int, cy: Int) {
    guard let data = rep.bitmapData else { return (0, 0, 0, 0) }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    let stride = rep.bytesPerRow
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in Swift.stride(from: 0, to: h, by: 2) {
      let row = y * stride
      for x in Swift.stride(from: 0, to: w, by: 2) {
        let a = data[row + x * 4 + 3]
        if a > 8 {
          if x < minX { minX = x }
          if y < minY { minY = y }
          if x > maxX { maxX = x }
          if y > maxY { maxY = y }
        }
      }
    }
    guard maxX >= minX, maxY >= minY else { return (0, 0, 0, 0) }
    return (maxX - minX + 1, maxY - minY + 1, (minX + maxX) / 2, (minY + maxY) / 2)
  }
}

/// The icon's two flat colors as Icon Composer writes them.
nonisolated struct IconColor: Hashable, Sendable {
  var r, g, b, a: Double

  init(_ color: Color) {
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
    (r, g, b, a) = (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
  }

  /// `srgb:r,g,b,a`, the form of a fill in `icon.json`.
  var iconComposer: String { String(format: "srgb:%.5f,%.5f,%.5f,%.5f", r, g, b, a) }
}

/// Builds an icon from flat sources: an Icon Composer `AppIcon.icon` (the background color as its automatic
/// gradient, the glyph as one glass layer filled with the glyph color, Hub's shadow, specular and translucency), and
/// an AppIcon set of actool's flattened render of it, so the icon looks the same on systems before macOS 26.
enum IconGenerator {

  /// The glyph's mask on a transparent 1024 canvas, white: the icon's layer, which its fill colors.
  static func renderGlyph(symbol: String, scale: CGFloat) throws -> NSBitmapImageRep {
    let canvas = 1024
    // The point size the live view uses (font(size: canvas * 0.5 * scale)); clamped only when the glyph would
    // overflow the canvas.
    var pointSize = Double(canvas) * 0.5 * Double(scale)
    var (symRep, glyph) = try SymbolRenderer.renderSized(
      symbol: symbol, canvas: canvas, pointSize: CGFloat(pointSize))
    let longest = max(glyph.w, glyph.h)
    if longest > canvas {
      pointSize *= Double(canvas) / Double(longest)
      (symRep, glyph) = try SymbolRenderer.renderSized(
        symbol: symbol, canvas: canvas, pointSize: CGFloat(pointSize))
    }
    whiten(symRep)
    return symRep
  }

  // MARK: - Icon Composer

  /// Writes `<outDir>/AppIcon.icon`.
  static func writeIconComposer(
    symbol: String, scale: CGFloat, background: IconColor, glyph: IconColor, to outDir: URL
  ) throws -> URL {
    let bundle = outDir.appendingPathComponent("AppIcon.icon", isDirectory: true)
    let assets = bundle.appendingPathComponent("Assets", isDirectory: true)
    let fm = FileManager.default
    try? fm.removeItem(at: bundle)
    try fm.createDirectory(at: assets, withIntermediateDirectories: true)
    // The mask is white with up to 256 alpha levels: an indexed PNG holds it exactly, at half the size.
    let mask = try renderGlyph(symbol: symbol, scale: scale)
    let pixels = rgbaPixels(of: mask, size: 1024)
    let palette = PalettePNG.palette(rgba: pixels, count: 256)
    let png = try PalettePNG.encode(
      width: 1024, height: 1024, indices: PalettePNG.indices(rgba: pixels, palette: palette), palette: palette)
    try png.write(to: assets.appendingPathComponent("glyph.png"))
    let json = iconComposerJSON(background: background, glyph: glyph, name: symbol)
    try Data(json.utf8).write(to: bundle.appendingPathComponent("icon.json"))
    return bundle
  }

  /// `icon.json` in the shape of Hub's icon: the background's automatic gradient (Icon Composer's top light),
  /// one group of glass (neutral shadow, specular edge, half translucency) holding the glyph filled with its color.
  nonisolated static func iconComposerJSON(background: IconColor, glyph: IconColor, name: String) -> String {
    let name = name.replacingOccurrences(of: "\"", with: "")
    return #"""
    {"fill":{"automatic-gradient":"\#(background.iconComposer)"},"groups":[{"layers":[{"fill":{"solid":"\#(glyph.iconComposer)"},"hidden":false,"image-name":"glyph.png","name":"\#(name)","position":{"scale":1,"translation-in-points":[0,0]}}],"shadow":{"kind":"neutral","opacity":0.5},"specular":true,"translucency":{"enabled":true,"value":0.5}}],"supported-platforms":{"circles":["watchOS"],"squares":"shared"}}
    """#
  }

  // MARK: - render

  /// Icon Composer's look of an icon, as actool renders it for systems before macOS 26: straight RGBA pixels by
  /// size (32, 64, 256, 512 and 1024), and the size of the compiled Assets.car.
  nonisolated struct Render: Sendable {
    var pixels: [Int: [UInt8]]
    var catalogBytes: Int

    /// The largest render scaled to `size`, unless actool drew that size itself.
    func pixels(size: Int) -> [UInt8] {
      if let exact = pixels[size] { return exact }
      let source = pixels.keys.filter { $0 >= size }.min() ?? pixels.keys.max() ?? 0
      return IconGenerator.scaled(pixels[source] ?? [], from: source, to: size)
    }

    var image: NSImage? {
      guard let size = pixels.keys.max(), let data = pixels[size] else { return nil }
      return IconGenerator.image(data, size: size)
    }
  }

  /// Writes the icon to a temporary `AppIcon.icon` and compiles it with actool.
  static func render(symbol: String, scale: CGFloat, background: IconColor, glyph: IconColor) async throws -> Render {
    let work = FileManager.default.temporaryDirectory
      .appendingPathComponent("dev-icon-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let icon = try writeIconComposer(symbol: symbol, scale: scale, background: background, glyph: glyph, to: work)
    return try await Task.detached(priority: .userInitiated) { try compile(icon, in: work) }.value
  }

  /// actool's catalog of `icon`, opened as a bundle so AppKit decodes the app icon's renditions.
  nonisolated private static func compile(_ icon: URL, in work: URL) throws -> Render {
    let app = work.appendingPathComponent("Render.app/Contents", isDirectory: true)
    let resources = app.appendingPathComponent("Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
      "actool", icon.path, "--compile", resources.path, "--platform", "macosx",
      "--minimum-deployment-target", "15.0", "--app-icon", "AppIcon", "--target-device", "mac",
      "--output-partial-info-plist", work.appendingPathComponent("partial.plist").path,
      "--output-format", "human-readable-text",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    let catalog = resources.appendingPathComponent("Assets.car")
    guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: catalog.path) else {
      throw IconError.actoolFailed(log.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    // A bundle identifier of its own, so no cached bundle answers for this one.
    let info = #"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.v57.dev.icon.\#(UUID().uuidString)</string></dict></plist>"#
    try Data(info.utf8).write(to: app.appendingPathComponent("Info.plist"))
    guard let image = Bundle(url: work.appendingPathComponent("Render.app"))?.image(forResource: "AppIcon") else {
      throw IconError.actoolFailed("no AppIcon in the compiled catalog")
    }
    var pixels: [Int: [UInt8]] = [:]
    for rep in image.representations where rep.pixelsWide > 0 {
      guard let cg = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
      pixels[rep.pixelsWide] = straightRGBA(cg, size: rep.pixelsWide)
    }
    guard !pixels.isEmpty else { throw IconError.actoolFailed("the app icon has no pictures") }
    let bytes = (try? FileManager.default.attributesOfItem(atPath: catalog.path)[.size] as? Int) ?? 0
    return Render(pixels: pixels, catalogBytes: bytes)
  }

  // MARK: - export

  /// Writes the project's `AppIcon.icon` and `Assets.xcassets/AppIcon.appiconset` (actool's render as lossless PNGs:
  /// a palette bands the glass and rings the shadow; actool compiles the set only where there is no `.icon`), both
  /// into `outDir`.
  static func export(symbol: String, scale: CGFloat, background: IconColor, glyph: IconColor, to outDir: URL)
    async throws
  {
    let render = try await render(symbol: symbol, scale: scale, background: background, glyph: glyph)
    _ = try writeIconComposer(symbol: symbol, scale: scale, background: background, glyph: glyph, to: outDir)
    let sizes = [1024, 16, 32, 64, 128, 256, 512]
    let files = try await Task.detached(priority: .userInitiated) {
      try sizes.map { size in (size, try png(render.pixels(size: size), size: size)) }
    }.value
    let fm = FileManager.default
    let set = outDir.appendingPathComponent("Assets.xcassets/AppIcon.appiconset", isDirectory: true)
    try? fm.removeItem(at: set)
    try fm.createDirectory(at: set, withIntermediateDirectories: true)
    for (size, data) in files {
      try data.write(to: set.appendingPathComponent("\(size).png"))
    }
    try writeContents(to: set)
  }

  // MARK: - pixels

  private static func whiten(_ rep: NSBitmapImageRep) {
    guard let d = rep.bitmapData else { return }
    let w = rep.pixelsWide, h = rep.pixelsHigh, s = rep.bytesPerRow
    let premultiplied = !rep.bitmapFormat.contains(.alphaNonpremultiplied)
    for y in 0..<h {
      for x in 0..<w {
        let i = y * s + x * 4
        let white = premultiplied ? d[i + 3] : 255
        d[i] = white; d[i + 1] = white; d[i + 2] = white
      }
    }
  }

  /// The bitmap drawn at `size` x `size`, as straight (not premultiplied) RGBA8 rows.
  static func rgbaPixels(of icon: NSBitmapImageRep, size: Int) -> [UInt8] {
    guard let cg = icon.cgImage else { return [] }
    return straightRGBA(cg, size: size)
  }

  /// `image` drawn at `size` x `size` (high-quality scaling), as straight RGBA8 rows.
  nonisolated static func straightRGBA(_ image: CGImage, size: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: size * size * 4)
    out.withUnsafeMutableBytes { buffer in
      guard let context = CGContext(
        data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      context.interpolationQuality = .high
      context.setBlendMode(.copy)
      context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    for i in stride(from: 0, to: out.count, by: 4) {
      let a = Int(out[i + 3])
      guard a > 0, a < 255 else { continue }
      for c in 0..<3 { out[i + c] = UInt8(min(255, (Int(out[i + c]) * 255 + a / 2) / a)) }
    }
    return out
  }

  /// Straight RGBA8 rows of `from` x `from` pixels, scaled to `to` x `to`.
  nonisolated static func scaled(_ pixels: [UInt8], from: Int, to: Int) -> [UInt8] {
    guard from > 0, let image = cgImage(pixels, size: from) else { return [] }
    return straightRGBA(image, size: to)
  }

  nonisolated static func png(_ pixels: [UInt8], size: Int) throws -> Data {
    let data = NSMutableData()
    guard let image = cgImage(pixels, size: size),
      let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { throw IconError.outputFailed("\(size) px PNG") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.outputFailed("\(size) px PNG") }
    return data as Data
  }

  nonisolated static func image(_ pixels: [UInt8], size: Int) -> NSImage? {
    guard let cg = cgImage(pixels, size: size) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
  }

  nonisolated private static func cgImage(_ pixels: [UInt8], size: Int) -> CGImage? {
    guard pixels.count == size * size * 4, let provider = CGDataProvider(data: Data(pixels) as CFData) else {
      return nil
    }
    return CGImage(
      width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  static func writeContents(to dir: URL) throws {
    let json = """
    {
      "images" : [
        { "filename" : "1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
        { "filename" : "16.png",  "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
        { "filename" : "32.png",  "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
        { "filename" : "32.png",  "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
        { "filename" : "64.png",  "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
        { "filename" : "128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
        { "filename" : "256.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
        { "filename" : "256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
        { "filename" : "512.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
        { "filename" : "512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
        { "filename" : "1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
    try Data(json.utf8).write(to: dir.appendingPathComponent("Contents.json"))
  }
}
