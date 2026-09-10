//
//  BackendID.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation

// MARK: - BackendID

/// Stable identity of a translation backend. Raw values are persisted on
/// translation records and sent over the board — do not rename.
///
/// `apple` and `ollama` are RETIRED: their adapters are gone and nothing
/// produces new values with them (their output could only pre-empt the
/// hosted model, never improve on it). The cases stay so historical records
/// and stored payloads still decode; do not reuse them.
nonisolated enum BackendID: String, Codable, CaseIterable, Sendable {
  /// Retired: Apple Translation framework (on-device, context-blind).
  case apple
  /// Retired: local Ollama (translategemma).
  case ollama
  /// The hosted Command Code API — the only live backend.
  case commandcode

  /// Human-readable name for UI lists and logs.
  var displayName: String {
    switch self {
    case .apple:
      return "Apple Translation"
    case .ollama:
      return "Ollama"
    case .commandcode:
      return "Command Code"
    }
  }
}
