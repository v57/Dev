import Foundation

/// MIRRORED verbatim from ../Database/Sources/SQLite/SQLiteError.swift.
/// `nonisolated` for the same reason as SQLiteConnection (Dev's MainActor
/// default isolation).
nonisolated public enum SQLiteError: Error, LocalizedError, Sendable {
  case invalidConfig(String)
  case invalidQuery(String)
  case notConnected
  /// The configured file does not exist (connect never creates files).
  case fileNotFound(String)
  /// The path exists but is not a file (e.g. a directory).
  case notAFile(String)
  /// The file opened but is not a SQLite database.
  case notADatabase(String)
  /// An operation SQLite cannot express (e.g. switching databases).
  case unsupported(String)
  case server(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfig(let m): return "Invalid configuration: \(m)"
    case .invalidQuery(let m): return "Invalid query: \(m)"
    case .notConnected: return "Not connected to SQLite."
    case .fileNotFound(let p): return "SQLite database file not found: \(p)"
    case .notAFile(let p): return "Not a file: \(p)"
    case .notADatabase(let p): return "Not a SQLite database: \(p)"
    case .unsupported(let m): return "Unsupported: \(m)"
    case .server(let m): return "SQLite error: \(m)"
    }
  }
}
