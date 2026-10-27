import DevScreenshots
import Foundation

#if os(macOS)
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
#endif

/// Draws an App Store picture with a config's `framing`: the background, the scene's caption on top, the capture
/// scaled with rounded corners and a shadow. Core Graphics and Core Text on the Mac, so it runs off the main actor and
/// in the MCP server alike; elsewhere `isAvailable` is false and `render` throws.
public nonisolated enum ScreenshotFramer {
  #if os(macOS)
  public static let isAvailable = true

  public struct RenderError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
  }

  /// Draws one picture and answers how many lines its caption took.
  @discardableResult
  public static func render(
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
  public static func cgColor(_ hex: String) -> CGColor {
    var value: UInt64 = 0
    let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else {
      return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    }
    return CGColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }
  #else
  public static let isAvailable = false

  public struct RenderError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
  }

  @discardableResult
  public static func render(
    _ capture: URL, caption: String?, background: String, framing: ScreenshotConfig.Framing, to target: URL
  ) throws -> Int {
    throw RenderError(message: "framing draws with Core Text, on macOS")
  }
  #endif
}
