import Foundation
import SwiftUI

#if canImport(CoreGraphics)
  import CoreGraphics
#endif

extension Image {
  /// A picture from RGBA pixels (8 bits a channel, premultiplied, sRGB, rows top to bottom without padding), such as
  /// PlatformImage's bitmaps; nil when the bytes don't make `width` × `height`.
  public init?(rgba: [UInt8], width: Int, height: Int) {
    guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
    #if canImport(Darwin)
      guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    #else
      guard let provider = CGDataProvider(data: Data(rgba)) else { return nil }
    #endif
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    self.init(decorative: image, scale: 1)
  }
}
