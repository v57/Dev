//
//  SQLite.swift
//  Dev
//

import Foundation
import SQLite3

/// What SQLite reported, with the statement it was about.
nonisolated struct SQLiteFailure: Error, LocalizedError, Sendable {
  let code: Int32
  let message: String

  var errorDescription: String? { "SQLite \(code): \(message)" }
}

/// One SQLite connection and the statements prepared on it. Not thread-safe: its owner
/// (`TranslationDatabase`, used from one serial queue) is what keeps it on one thread at a
/// time.
nonisolated final class SQLiteConnection {
  private var handle: OpaquePointer?
  private var statements: [String: OpaquePointer] = [:]

  init(path: String, readOnly: Bool = false) throws {
    let flags = readOnly
      ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
      : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
    var db: OpaquePointer?
    let code = sqlite3_open_v2(path, &db, flags, nil)
    guard code == SQLITE_OK, let db else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
      sqlite3_close(db)
      throw SQLiteFailure(code: code, message: message)
    }
    handle = db
    sqlite3_busy_timeout(db, 5_000)
  }

  deinit {
    for statement in statements.values { sqlite3_finalize(statement) }
    sqlite3_close(handle)
  }

  /// Runs one or more statements that return nothing.
  func execute(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(handle, sql, nil, nil, &error)
    guard code == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? "error"
      sqlite3_free(error)
      throw SQLiteFailure(code: code, message: "\(message) — \(sql.prefix(200))")
    }
  }

  /// Runs `body` in one transaction: committed when it returns, rolled back when it throws.
  func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  /// The prepared statement for `sql`, reset and ready to bind: statements are cached per
  /// connection, so a write that runs a hundred thousand times prepares once.
  func statement(_ sql: String) throws -> SQLiteStatement {
    if let cached = statements[sql] {
      sqlite3_reset(cached)
      sqlite3_clear_bindings(cached)
      return SQLiteStatement(handle: cached, connection: self)
    }
    var prepared: OpaquePointer?
    let code = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil)
    guard code == SQLITE_OK, let prepared else { throw failure(code, sql) }
    statements[sql] = prepared
    return SQLiteStatement(handle: prepared, connection: self)
  }

  /// Rows `sql` returns, each read by `row`.
  func query<T>(_ sql: String, _ binds: [SQLiteValue] = [], row: (SQLiteRow) throws -> T) throws -> [T] {
    let statement = try statement(sql)
    try statement.bind(binds)
    var rows: [T] = []
    while try statement.step() {
      rows.append(try row(SQLiteRow(handle: statement.handle)))
    }
    return rows
  }

  /// Runs one statement that returns nothing, with its parameters.
  func run(_ sql: String, _ binds: [SQLiteValue] = []) throws {
    let statement = try statement(sql)
    try statement.bind(binds)
    while try statement.step() {}
  }

  /// The value of a one-column, one-row query.
  func scalar(_ sql: String, _ binds: [SQLiteValue] = []) throws -> Int64? {
    try query(sql, binds) { $0.int64Optional(0) }.first ?? nil
  }

  var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

  fileprivate func failure(_ code: Int32, _ sql: String) -> SQLiteFailure {
    SQLiteFailure(code: code, message: "\(String(cString: sqlite3_errmsg(handle))) — \(sql.prefix(200))")
  }
}

/// A value bound to a statement parameter.
nonisolated enum SQLiteValue: Sendable {
  case null
  case int(Int64)
  case double(Double)
  case text(String)

  static func text(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
  static func int(_ value: Int?) -> SQLiteValue { value.map { .int(Int64($0)) } ?? .null }
  static func bool(_ value: Bool) -> SQLiteValue { .int(value ? 1 : 0) }
  static func double(_ value: Double?) -> SQLiteValue { value.map { .double($0) } ?? .null }
  /// Dates are stored as seconds since the reference date (what SwiftData wrote, too).
  static func date(_ value: Date?) -> SQLiteValue {
    value.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null
  }
}

/// A prepared statement, borrowed from its connection's cache.
nonisolated struct SQLiteStatement {
  let handle: OpaquePointer
  unowned let connection: SQLiteConnection

  func bind(_ values: [SQLiteValue]) throws {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let code: Int32
      switch value {
      case .null: code = sqlite3_bind_null(handle, index)
      case .int(let int): code = sqlite3_bind_int64(handle, index, int)
      case .double(let double): code = sqlite3_bind_double(handle, index, double)
      case .text(let text): code = sqlite3_bind_text(handle, index, text, -1, SQLITE_TRANSIENT)
      }
      guard code == SQLITE_OK else { throw connection.failure(code, "bind \(index)") }
    }
  }

  /// Advances one row: true while there is a row to read.
  func step() throws -> Bool {
    let code = sqlite3_step(handle)
    switch code {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    default: throw connection.failure(code, String(cString: sqlite3_sql(handle)))
    }
  }

  /// Runs it once with `values`, for a write repeated over many rows.
  func run(_ values: [SQLiteValue]) throws {
    sqlite3_reset(handle)
    sqlite3_clear_bindings(handle)
    try bind(values)
    while try step() {}
  }
}

/// The current row of a statement, read by column index.
nonisolated struct SQLiteRow {
  let handle: OpaquePointer

  func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }

  func string(_ column: Int32) -> String {
    guard let text = sqlite3_column_text(handle, column) else { return "" }
    return String(cString: text)
  }

  func stringOptional(_ column: Int32) -> String? {
    isNull(column) ? nil : string(column)
  }

  func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
  func int64Optional(_ column: Int32) -> Int64? { isNull(column) ? nil : int64(column) }
  func int(_ column: Int32) -> Int { Int(int64(column)) }
  func intOptional(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }
  func bool(_ column: Int32) -> Bool { int64(column) != 0 }
  func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
  func doubleOptional(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
  func date(_ column: Int32) -> Date { Date(timeIntervalSinceReferenceDate: double(column)) }
  func dateOptional(_ column: Int32) -> Date? { isNull(column) ? nil : date(column) }
}

/// SQLite copies the text it is handed (the Swift string's buffer is gone after the call).
private nonisolated let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
