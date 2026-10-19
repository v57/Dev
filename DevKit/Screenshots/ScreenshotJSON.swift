import Foundation

/// Writes `.dev/screenshots.json` the way people write it: keys in the order the docs use them, and an array or object
/// on one line when it fits, so a file saved by Dev diffs only where it changed.
enum ScreenshotJSON {
  static let width = 120

  /// The order of keys in any object of the file; each object uses the ones it has.
  static let keyOrder = [
    "id", "scheme", "project", "workspace", "configuration", "derivedData", "devices", "build", "output", "locales",
    "appearances", "variables", "watch", "platform", "width", "height", "background", "backgrounds", "arguments",
    "environment", "platforms", "delay", "catalog", "fontSize", "color", "bold", "maxLines", "top", "caption", "window",
    "scale", "shadow", "align", "cornerRadius", "activate", "app", "cleanStatusBar", "mac", "ios", "relaunch",
    "framing", "updatedBy", "updatedAt", "scenes",
  ]
  private static let rank = Dictionary(uniqueKeysWithValues: keyOrder.enumerated().map { ($1, $0) })

  static func data<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let object = try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    return Data((try format(object, indent: "", prefix: 0) + "\n").utf8)
  }

  /// `prefix` is how many characters precede the value on its line.
  static func format(_ value: Any, indent: String, prefix: Int) throws -> String {
    let flat = try inline(value)
    if indent.count + prefix + flat.count <= width && !indent.isEmpty { return flat }
    let inner = indent + "  "
    if let array = value as? [Any], !array.isEmpty {
      let items = try array.map { inner + (try format($0, indent: inner, prefix: 0)) }
      return "[\n" + items.joined(separator: ",\n") + "\n\(indent)]"
    }
    if let object = value as? [String: Any], !object.isEmpty {
      let items = try sortedKeys(object).map { key -> String in
        let name = try scalar(key) + ": "
        return inner + name + (try format(object[key]!, indent: inner, prefix: name.count))
      }
      return "{\n" + items.joined(separator: ",\n") + "\n\(indent)}"
    }
    return flat
  }

  static func inline(_ value: Any) throws -> String {
    if let array = value as? [Any] {
      return "[" + (try array.map(inline)).joined(separator: ", ") + "]"
    }
    if let object = value as? [String: Any] {
      if object.isEmpty { return "{}" }
      return "{ " + (try sortedKeys(object).map { try scalar($0) + ": " + (try inline(object[$0]!)) })
        .joined(separator: ", ") + " }"
    }
    return try scalar(value)
  }

  private static func scalar(_ value: Any) throws -> String {
    // JSONSerialization spells 0.07 as 0.070000000000000007; Swift's shortest form reads back the same.
    if let number = value as? NSNumber, isFloat(number) {
      let double = number.doubleValue
      if double.isFinite, double == double.rounded(), abs(double) < 1e15 { return String(Int64(double)) }
      return "\(double)"
    }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }

  /// A floating-point number (not a Bool or an integer).
  private static func isFloat(_ number: NSNumber) -> Bool {
    #if canImport(ObjectiveC)
      CFGetTypeID(number) != CFBooleanGetTypeID() && CFNumberIsFloatType(number)
    #else
      ["d", "f"].contains(String(cString: number.objCType))
    #endif
  }

  private static func sortedKeys(_ object: [String: Any]) -> [String] {
    object.keys.sorted { (rank[$0] ?? keyOrder.count, $0) < (rank[$1] ?? keyOrder.count, $1) }
  }
}
