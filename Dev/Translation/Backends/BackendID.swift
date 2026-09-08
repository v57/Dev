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
nonisolated enum BackendID: String, Codable, CaseIterable, Sendable {
  case apple
  case ollama
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
