//
//  PalettePNG.swift
//  Dev
//

import Compression
import Foundation

// MARK: - PalettePNG

/// Flat-palette PNGs without ImageMagick: a median-cut palette of at most 256
/// colors, nearest-color mapping without dithering, and an indexed (color type 3)
/// PNG with a `tRNS` chunk when any color is translucent. A flat icon quantized
/// this way is a fraction of its RGBA size, which is what the export used to call
/// `magick … +dither -colors N -type Palette` for.
nonisolated enum PalettePNG {
  struct Color: Hashable {
    var r, g, b, a: UInt8
  }

  /// A palette of at most `count` colors for RGBA8 `pixels` (premultiplication is
  /// irrelevant: the colors are only matched against the same pixels).
  static func palette(rgba pixels: [UInt8], count: Int) -> [Color] {
    // Unique colors with their weights. Dropping the lowest bit per channel keeps a
    // smooth gradient's color count small without a visible difference.
    var weights: [UInt32: Int] = [:]
    var index = 0
    while index + 3 < pixels.count {
      let key = UInt32(pixels[index] & 0xFE) << 24 | UInt32(pixels[index + 1] & 0xFE) << 16
        | UInt32(pixels[index + 2] & 0xFE) << 8 | UInt32(pixels[index + 3] & 0xFE)
      weights[key, default: 0] += 1
      index += 4
    }
    var boxes: [[(Color, Int)]] = [weights.map { (Self.color($0.key), $0.value) }]
    let target = max(1, min(256, count))
    while boxes.count < target {
      // Split the box with the widest channel range at its weighted median.
      guard let (boxIndex, channel) = widest(boxes) else { break }
      var box = boxes.remove(at: boxIndex)
      box.sort { value($0.0, channel) < value($1.0, channel) }
      let total = box.reduce(0) { $0 + $1.1 }
      var running = 0
      var cut = 1
      for (offset, entry) in box.enumerated() {
        running += entry.1
        if running * 2 >= total { cut = max(1, min(box.count - 1, offset + 1)); break }
      }
      boxes.append(Array(box[..<cut]))
      boxes.append(Array(box[cut...]))
    }
    return boxes.map(average)
  }

  /// Each pixel's palette index: the nearest color, no dithering (flat art stays flat).
  static func indices(rgba pixels: [UInt8], palette: [Color]) -> [UInt8] {
    var cache: [UInt32: UInt8] = [:]
    var out = [UInt8](repeating: 0, count: pixels.count / 4)
    for pixel in 0..<out.count {
      let i = pixel * 4
      let key = UInt32(pixels[i]) << 24 | UInt32(pixels[i + 1]) << 16 | UInt32(pixels[i + 2]) << 8
        | UInt32(pixels[i + 3])
      if let hit = cache[key] {
        out[pixel] = hit
        continue
      }
      var best = 0
      var bestDistance = Int.max
      for (n, c) in palette.enumerated() {
        let dr = Int(c.r) - Int(pixels[i]), dg = Int(c.g) - Int(pixels[i + 1])
        let db = Int(c.b) - Int(pixels[i + 2]), da = Int(c.a) - Int(pixels[i + 3])
        let distance = dr * dr + dg * dg + db * db + 2 * da * da
        if distance < bestDistance { bestDistance = distance; best = n }
      }
      cache[key] = UInt8(best)
      out[pixel] = UInt8(best)
    }
    return out
  }

  /// An indexed PNG of `width` x `height` pixels.
  static func encode(width: Int, height: Int, indices: [UInt8], palette: [Color]) throws -> Data {
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    var header = Data()
    header.append(bigEndian: UInt32(width))
    header.append(bigEndian: UInt32(height))
    // The fewest bits that hold an index: a 2-color icon is 1 bit per pixel.
    let depth = palette.count <= 2 ? 1 : palette.count <= 4 ? 2 : palette.count <= 16 ? 4 : 8
    header.append(contentsOf: [UInt8(depth), 3, 0, 0, 0])  // palette, deflate, no interlace
    png.append(chunk: "IHDR", header)
    png.append(chunk: "PLTE", Data(palette.flatMap { [$0.r, $0.g, $0.b] }))
    if palette.contains(where: { $0.a < 255 }) {
      png.append(chunk: "tRNS", Data(palette.map(\.a)))
    }
    let perByte = 8 / depth
    let rowBytes = (width + perByte - 1) / perByte
    var raw = Data(capacity: (rowBytes + 1) * height)
    var packed = [UInt8](repeating: 0, count: rowBytes)
    for row in 0..<height {
      raw.append(0)  // filter: none, which compresses best for flat indexed art
      for n in 0..<rowBytes { packed[n] = 0 }
      for x in 0..<width {
        let shift = 8 - depth * (x % perByte + 1)
        packed[x / perByte] |= indices[row * width + x] << shift
      }
      raw.append(contentsOf: packed)
    }
    png.append(chunk: "IDAT", try zlib(raw))
    png.append(chunk: "IEND", Data())
    return png
  }

  // MARK: - helpers

  private static func color(_ key: UInt32) -> Color {
    Color(r: UInt8(key >> 24 & 0xFF), g: UInt8(key >> 16 & 0xFF),
          b: UInt8(key >> 8 & 0xFF), a: UInt8(key & 0xFF))
  }

  private static func value(_ color: Color, _ channel: Int) -> UInt8 {
    switch channel {
    case 0: return color.r
    case 1: return color.g
    case 2: return color.b
    default: return color.a
    }
  }

  private static func widest(_ boxes: [[(Color, Int)]]) -> (Int, Int)? {
    var best: (Int, Int)?
    var bestRange = 0
    for (n, box) in boxes.enumerated() where box.count > 1 {
      for channel in 0..<4 {
        var low: UInt8 = 255, high: UInt8 = 0
        for (color, _) in box {
          let v = value(color, channel)
          low = min(low, v)
          high = max(high, v)
        }
        let range = Int(high) - Int(low)
        if range > bestRange { bestRange = range; best = (n, channel) }
      }
    }
    return best
  }

  private static func average(_ box: [(Color, Int)]) -> Color {
    var r = 0, g = 0, b = 0, a = 0, total = 0
    for (color, weight) in box {
      r += Int(color.r) * weight; g += Int(color.g) * weight
      b += Int(color.b) * weight; a += Int(color.a) * weight
      total += weight
    }
    guard total > 0 else { return Color(r: 0, g: 0, b: 0, a: 0) }
    // A channel at the top of the range came from 254 or 255; keep opaque opaque.
    let round = { (sum: Int) in UInt8(min(255, (sum + total / 2) / total)) }
    let alpha = round(a)
    return Color(r: round(r), g: round(g), b: round(b), a: alpha >= 254 ? 255 : alpha)
  }

  /// zlib = 2-byte header + raw DEFLATE (what COMPRESSION_ZLIB produces) + Adler-32.
  private static func zlib(_ data: Data) throws -> Data {
    let capacity = data.count + data.count / 10 + 1024
    var compressed = Data(count: capacity)
    let written = compressed.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { source in
        compression_encode_buffer(
          destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard written > 0 else { throw IconError.outputFailed("deflate") }
    var out = Data([0x78, 0x9C])
    out.append(compressed.prefix(written))
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in data {
      a = (a + UInt32(byte)) % 65521
      b = (b + a) % 65521
    }
    out.append(bigEndian: b << 16 | a)
    return out
  }

  fileprivate static let crcTable: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    return c
  }

  fileprivate static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
  }
}

nonisolated private extension Data {
  mutating func append(bigEndian value: UInt32) {
    append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
                        UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
  }

  mutating func append(chunk type: String, _ body: Data) {
    append(bigEndian: UInt32(body.count))
    var typed = Data(type.utf8)
    typed.append(body)
    append(typed)
    append(bigEndian: PalettePNG.crc32(typed))
  }
}
