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
/// `apple`, `ollama` and `commandcode` are RETIRED: their adapters are gone
/// and nothing produces new values with them (Apple and Ollama could only
/// pre-empt the hosted model, never improve on it; Command Code's account
/// was replaced by OpenCode Go). The cases stay so historical records and
/// stored payloads still decode; do not reuse them.
nonisolated enum BackendID: String, Codable, CaseIterable, Sendable {
  /// Retired: Apple Translation framework (on-device, context-blind).
  case apple
  /// Retired: local Ollama (translategemma).
  case ollama
  /// Retired: the Command Code API. Translation moved to OpenCode Go; the
  /// case stays so historical payloads still decode.
  case commandcode
  /// The OpenCode Go API — the live backend.
  case opencode

  /// Human-readable name for UI lists and logs.
  var displayName: String {
    switch self {
    case .apple:
      return "Apple Translation"
    case .ollama:
      return "Ollama"
    case .commandcode:
      return "Command Code"
    case .opencode:
      return "OpenCode Go"
    }
  }
}
