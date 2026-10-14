import Foundation

extension ScreenshotConfig {
  /// How the captured pictures become App Store pictures, in the config's `framing`: the capture scaled and shadowed on
  /// a background, under the scene's `caption` translated through a String Catalog, at one App Store size. Dev's
  /// Screenshots tool and its agents edit it; the captures don't depend on it.
  ///
  /// ```json
  /// "framing": {
  ///   "width": 2880, "height": 1800, "background": "#1D1D1F",
  ///   "backgrounds": { "01-history": "#0A5FC2" },
  ///   "caption": { "catalog": "Screenshots.xcstrings", "fontSize": 110 },
  ///   "window": { "scale": 0.82, "align": "bottom" }
  /// }
  /// ```
  ///
  /// Every key is optional. Framed pictures go to `<output>/framed/`, at the capture's own path.
  public struct Framing: Hashable, Sendable {
    /// The platform whose pictures are framed (one size fits one platform); nil frames the config's first one.
    public var platform: Platform?
    /// The framed picture's size in pixels: one of App Store Connect's sizes.
    public var width: Int
    public var height: Int
    /// The background when the scene has none in `backgrounds` (`#RRGGBB`).
    public var background: String
    /// Per scene `id`, its background.
    public var backgrounds: [String: String]
    public var caption: Caption
    public var window: Window
    /// Who changed the framing last ("you", "Claude through MCP") and when.
    public var updatedBy: String?
    public var updatedAt: Date?

    public static let folder = "framed"

    public init(
      platform: Platform? = nil, width: Int = 2880, height: Int = 1800, background: String = "#1D1D1F",
      backgrounds: [String: String] = [:], caption: Caption = Caption(), window: Window = Window(),
      updatedBy: String? = nil, updatedAt: Date? = nil
    ) {
      self.platform = platform
      self.width = width
      self.height = height
      self.background = background
      self.backgrounds = backgrounds
      self.caption = caption
      self.window = window
      self.updatedBy = updatedBy
      self.updatedAt = updatedAt
    }

    /// A first framing for a platform: its largest App Store size and the captures on a plain ground.
    public static func starter(for platform: Platform) -> Framing {
      var framing = Framing()
      switch platform {
      case .mac: break
      case .iphone:
        (framing.width, framing.height) = (1320, 2868)
        framing.caption.fontSize = 96
        framing.window.scale = 0.86
      case .ipad:
        (framing.width, framing.height) = (2064, 2752)
        framing.caption.fontSize = 96
        framing.window.scale = 0.86
      }
      return framing
    }

    public func background(of scene: String) -> String { backgrounds[scene] ?? background }

    public struct Caption: Hashable, Sendable {
      /// The String Catalog the captions are translated in, relative to the root; each scene's `caption` is a key.
      public var catalog: String
      /// Points at the framed size.
      public var fontSize: Double
      public var color: String
      public var bold: Bool
      /// A caption that needs more lines is reported as too long.
      public var maxLines: Int
      /// Space above the caption, as a fraction of the height.
      public var top: Double

      public init(
        catalog: String = "Screenshots.xcstrings", fontSize: Double = 110, color: String = "#FFFFFF", bold: Bool = true,
        maxLines: Int = 2, top: Double = 0.07
      ) {
        self.catalog = catalog
        self.fontSize = fontSize
        self.color = color
        self.bold = bold
        self.maxLines = maxLines
        self.top = top
      }
    }

    public struct Window: Hashable, Sendable {
      /// The capture's width as a fraction of the picture's.
      public var scale: Double
      public var shadow: Bool
      public var align: Align
      public var cornerRadius: Double

      public init(scale: Double = 0.82, shadow: Bool = true, align: Align = .bottom, cornerRadius: Double = 24) {
        self.scale = scale
        self.shadow = shadow
        self.align = align
        self.cornerRadius = cornerRadius
      }
    }

    public enum Align: String, Codable, Hashable, Sendable, CaseIterable {
      /// The window runs off the bottom edge.
      case bottom
      /// The window floats under the caption.
      case center
    }

    // MARK: - App Store sizes

    /// App Store Connect's screenshot sizes in pixels, landscape for the Mac and portrait for devices.
    public static let appStoreSizes: [Platform: [[Int]]] = [
      .mac: [[1280, 800], [1440, 900], [2560, 1600], [2880, 1800]],
      .iphone: [[1320, 2868], [1290, 2796], [1242, 2688], [1284, 2778], [1179, 2556], [1206, 2622]],
      .ipad: [[2064, 2752], [2048, 2732]],
    ]

    /// Whether App Store Connect takes this size, in either orientation.
    public static func isAppStoreSize(width: Int, height: Int) -> Bool {
      appStoreSizes.values.joined().contains { [width, height] == $0 || [height, width] == $0 }
    }

    /// Problems in the framing, worded for the reader.
    public func problems() -> [String] {
      var problems: [String] = []
      if !Self.isAppStoreSize(width: width, height: height) {
        problems.append("\(width) × \(height) is not an App Store Connect size.")
      }
      if !(0.1...1).contains(window.scale) { problems.append("framing.window.scale is between 0.1 and 1.") }
      return problems
    }
  }

  /// The platform `framing` frames: its own, else the Mac when the config captures it, else the first device's.
  public var framedPlatform: Platform? {
    if let platform = framing?.platform { return platform }
    if mac != nil { return .mac }
    return ios?.devices.first.map(Self.platform(ofDevice:))
  }

  /// From a simulator's name; a UDID counts as an iPhone.
  public static func platform(ofDevice name: String) -> Platform {
    name.localizedCaseInsensitiveContains("ipad") ? .ipad : .iphone
  }

  /// Where a captured picture's framed version goes.
  public func framedURL(of file: String, in root: URL) -> URL {
    outputURL(in: root).appendingPathComponent(Framing.folder, isDirectory: true).appendingPathComponent(file)
  }
}

// MARK: - Coding: every key optional, a bad value takes its default

extension ScreenshotConfig.Framing: Codable {
  private enum CodingKeys: String, CodingKey {
    case platform, width, height, background, backgrounds, caption, window, updatedBy, updatedAt
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self()
    platform = (try? c.decodeIfPresent(ScreenshotConfig.Platform.self, forKey: .platform)) ?? nil
    width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? d.width
    height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? d.height
    background = (try? c.decodeIfPresent(String.self, forKey: .background)) ?? d.background
    backgrounds = (try? c.decodeIfPresent([String: String].self, forKey: .backgrounds)) ?? [:]
    caption = (try? c.decodeIfPresent(Caption.self, forKey: .caption)) ?? d.caption
    window = (try? c.decodeIfPresent(Window.self, forKey: .window)) ?? d.window
    updatedBy = (try? c.decodeIfPresent(String.self, forKey: .updatedBy)) ?? nil
    // An ISO 8601 string whatever the decoder's date strategy.
    updatedAt = ((try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil)
      .flatMap { try? Date.ISO8601FormatStyle().parse($0) }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(platform, forKey: .platform)
    try c.encode(width, forKey: .width)
    try c.encode(height, forKey: .height)
    try c.encode(background, forKey: .background)
    if !backgrounds.isEmpty { try c.encode(backgrounds, forKey: .backgrounds) }
    try c.encode(caption, forKey: .caption)
    try c.encode(window, forKey: .window)
    try c.encodeIfPresent(updatedBy, forKey: .updatedBy)
    try c.encodeIfPresent(updatedAt.map { $0.formatted(.iso8601) }, forKey: .updatedAt)
  }
}

extension ScreenshotConfig.Framing.Caption: Codable {
  private enum CodingKeys: String, CodingKey { case catalog, fontSize, color, bold, maxLines, top }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self()
    catalog = (try? c.decodeIfPresent(String.self, forKey: .catalog)) ?? d.catalog
    fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? d.fontSize
    color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? d.color
    bold = (try? c.decodeIfPresent(Bool.self, forKey: .bold)) ?? d.bold
    maxLines = (try? c.decodeIfPresent(Int.self, forKey: .maxLines)) ?? d.maxLines
    top = (try? c.decodeIfPresent(Double.self, forKey: .top)) ?? d.top
  }
}

extension ScreenshotConfig.Framing.Window: Codable {
  private enum CodingKeys: String, CodingKey { case scale, shadow, align, cornerRadius }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self()
    scale = (try? c.decodeIfPresent(Double.self, forKey: .scale)) ?? d.scale
    shadow = (try? c.decodeIfPresent(Bool.self, forKey: .shadow)) ?? d.shadow
    align = (try? c.decodeIfPresent(ScreenshotConfig.Framing.Align.self, forKey: .align)) ?? d.align
    cornerRadius = (try? c.decodeIfPresent(Double.self, forKey: .cornerRadius)) ?? d.cornerRadius
  }
}
