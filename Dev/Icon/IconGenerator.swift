//
//  IconGenerator.swift
//  Dev
//
//  AppKit + ImageMagick icon pipeline ported from the standalone ../AppIcon
//  tool and generalized for the UI: configurable glyph scale, background
//  gradient colors, glyph color, and palette size.
//

import AppKit
import SwiftUI
import Foundation

enum IconError: Error, CustomStringConvertible {
  case symbolNotFound(String)
  case renderFailed(String)
  case emptyGlyph(String)
  case outputFailed(String)

  var description: String {
    switch self {
    case .symbolNotFound(let s): return "SF Symbol \"\(s)\" not found on this system"
    case .renderFailed(let s): return "Could not render SF Symbol \"\(s)\""
    case .emptyGlyph(let s): return "SF Symbol \"\(s)\" produced an empty glyph"
    case .outputFailed(let c): return "ImageMagick command failed: \(c)"
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

/// Composes the final icon: a gradient/solid colored background with the glyph
/// drawn centered at scale * 50% of the canvas, then quantized to a small flat
/// palette (`PalettePNG`) and written into an AppIcon.appiconset folder.
enum IconGenerator {

  static let glyphOpacity: Double = 0.8

  // MARK: - render (MainActor, AppKit drawing)

  static func renderMaster(
    symbol: String,
    scale: CGFloat,
    primary: Color,
    secondary: Color,
    glyphColor: Color,
    gradient: Bool
  ) throws -> NSBitmapImageRep {
    let canvas = 1024
    let rep = makeBitmap(canvas: canvas)

    // Size the glyph to the SAME point size the live view uses
    // (font(size: canvas*0.5*scale)), so preview matches live exactly.
    // Clamp only when the glyph would overflow the canvas (extreme high scale).
    var pointSize = Double(canvas) * 0.5 * Double(scale)
    var (symRep, glyph) = try SymbolRenderer.renderSized(
      symbol: symbol, canvas: canvas, pointSize: CGFloat(pointSize))
    let longest = max(glyph.w, glyph.h)
    if longest > canvas {
      let fit = Double(canvas) / Double(longest)
      pointSize *= fit
      (symRep, glyph) = try SymbolRenderer.renderSized(
        symbol: symbol, canvas: canvas, pointSize: CGFloat(pointSize))
    }

    let p = rgba(primary), s = rgba(secondary)
    let top = NSColor(deviceRed: p.r, green: p.g, blue: p.b, alpha: p.a)
    let bottom = NSColor(deviceRed: s.r, green: s.g, blue: s.b, alpha: s.a)

    // Background.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if gradient {
      NSGradient(starting: top, ending: bottom)?.draw(
        in: NSRect(x: 0, y: 0, width: canvas, height: canvas), angle: -90)
    } else {
      top.setFill()
      NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Glyph.
    let g = rgba(glyphColor)
    tint(symRep, r: g.r, g: g.g, b: g.b, alpha: glyphOpacity)
    composite(symRep, onto: rep)

    return rep
  }

  private static func rgba(_ color: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    let ns = NSColor(color)
    guard let cc = ns.usingColorSpace(.deviceRGB) else { return (1, 1, 1, 1) }
    return (cc.redComponent, cc.greenComponent, cc.blueComponent, cc.alphaComponent)
  }

  private static func makeBitmap(canvas: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
  }

  private static func composite(_ src: NSBitmapImageRep, onto dst: NSBitmapImageRep) {
    guard let sd = src.bitmapData, let dd = dst.bitmapData else { return }
    let w = src.pixelsWide, h = src.pixelsHigh
    let ss = src.bytesPerRow, ds = dst.bytesPerRow
    for y in 0..<h {
      for x in 0..<w {
        let si = y * ss + x * 4
        let di = y * ds + x * 4
        let a = Double(sd[si + 3]) / 255.0
        let sr = Double(sd[si]) / 255.0, sg = Double(sd[si + 1]) / 255.0, sb = Double(sd[si + 2]) / 255.0
        let dr = Double(dd[di]) / 255.0, dg = Double(dd[di + 1]) / 255.0, db = Double(dd[di + 2]) / 255.0
        let r = sr * a + dr * (1 - a)
        let g = sg * a + dg * (1 - a)
        let b = sb * a + db * (1 - a)
        dd[di] = UInt8(min(255, max(0, Int(r * 255))))
        dd[di + 1] = UInt8(min(255, max(0, Int(g * 255))))
        dd[di + 2] = UInt8(min(255, max(0, Int(b * 255))))
        dd[di + 3] = 255
      }
    }
  }

  private static func tint(_ rep: NSBitmapImageRep, r: CGFloat, g: CGFloat, b: CGFloat, alpha: Double = 1.0) {
    guard let d = rep.bitmapData else { return }
    let w = rep.pixelsWide, h = rep.pixelsHigh, s = rep.bytesPerRow
    for y in 0..<h {
      for x in 0..<w {
        let i = y * s + x * 4
        d[i] = UInt8(min(255, max(0, Int(r * 255))))
        d[i + 1] = UInt8(min(255, max(0, Int(g * 255))))
        d[i + 2] = UInt8(min(255, max(0, Int(b * 255))))
        d[i + 3] = UInt8(min(255, max(0, Int(Double(d[i + 3]) * alpha))))
      }
    }
  }

  // MARK: - icon set export

  /// Renders the icon once at 1024, scales it to every size the set needs, and
  /// writes each as a flat-palette PNG (`PalettePNG`) sharing the master's palette,
  /// so the small sizes keep exactly the master's colors. No external tools.
  static func exportIconSet(
    symbol: String, scale: CGFloat, primary: Color, secondary: Color,
    glyphColor: Color, gradient: Bool, palette: Int, to outDir: URL
  ) async throws {
    let fm = FileManager.default
    let icon = try renderMaster(
      symbol: symbol, scale: scale, primary: primary, secondary: secondary,
      glyphColor: glyphColor, gradient: gradient)
    let files = try await palettePNGs(of: icon, sizes: [1024, 16, 32, 64, 128, 256, 512], colors: palette)

    let assets = outDir.appendingPathComponent("Assets.xcassets", isDirectory: true)
    let set = assets.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
    try? fm.removeItem(at: set)
    try fm.createDirectory(at: set, withIntermediateDirectories: true)
    for (size, data) in files {
      try data.write(to: set.appendingPathComponent("\(size).png"))
    }
    try writeContents(to: set)
  }

  /// The icon as flat-palette PNGs, one per size, all with the palette taken from
  /// the first size. The quantizing runs off the main actor.
  static func palettePNGs(of icon: NSBitmapImageRep, sizes: [Int], colors: Int) async throws
    -> [(size: Int, data: Data)]
  {
    let scaled = sizes.map { (size: $0, pixels: rgbaPixels(of: icon, size: $0)) }
    return try await Task.detached(priority: .userInitiated) {
      let palette = PalettePNG.palette(rgba: scaled[0].pixels, count: colors)
      return try scaled.map { entry in
        let indices = PalettePNG.indices(rgba: entry.pixels, palette: palette)
        return (entry.size, try PalettePNG.encode(
          width: entry.size, height: entry.size, indices: indices, palette: palette))
      }
    }.value
  }

  /// The icon drawn at `size` x `size`, as straight (not premultiplied) RGBA8 rows.
  static func rgbaPixels(of icon: NSBitmapImageRep, size: Int) -> [UInt8] {
    let rep = makeBitmap(canvas: size)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)
    context?.imageInterpolation = .high
    NSGraphicsContext.current = context
    icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
              from: NSRect(x: 0, y: 0, width: icon.pixelsWide, height: icon.pixelsHigh),
              operation: .copy, fraction: 1.0, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.bitmapData else { return [] }
    let stride = rep.bytesPerRow
    let premultiplied = !rep.bitmapFormat.contains(.alphaNonpremultiplied)
    var out = [UInt8](repeating: 0, count: size * size * 4)
    for y in 0..<size {
      for x in 0..<size {
        let s = y * stride + x * 4, d = (y * size + x) * 4
        let a = data[s + 3]
        for c in 0..<3 {
          let v = Int(data[s + c])
          out[d + c] = premultiplied && a > 0 && a < 255
            ? UInt8(min(255, (v * 255 + Int(a) / 2) / Int(a))) : data[s + c]
        }
        out[d + 3] = a
      }
    }
    return out
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
