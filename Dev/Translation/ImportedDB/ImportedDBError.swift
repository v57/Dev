import Foundation

/// Why the imported translation database couldn't be read.
enum ImportedDBError: Error, LocalizedError {
  case invalidQuery(String)
  case notConnected
  /// The remembered file does not exist (reading never creates one).
  case fileNotFound(String)
  /// The file opened but is not a translation database.
  case notADatabase(String)
  case server(String)

  var errorDescription: String? {
    switch self {
    case .invalidQuery(let m): "Invalid query: \(m)"
    case .notConnected: "The translation database isn't open."
    case .fileNotFound(let p): "SQLite database file not found: \(p)"
    case .notADatabase(let p): "Not a SQLite database: \(p)"
    case .server(let m): "SQLite error: \(m)"
    }
  }
}
