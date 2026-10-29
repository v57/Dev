#!/usr/bin/env python3
"""Regenerates App/Sources/DevApp/Translation/Providers/ModelRecommendations.swift from recommendations.json.

    python3 Tools/model-recommendations/generate.py Tools/model-recommendations/recommendations.json \
      > App/Sources/DevApp/Translation/Providers/ModelRecommendations.swift

recommendations.json holds, per provider, up to three models tagged best/value/free with their
price per 1M tokens, a one-line reason and the page each was checked on.
"""
import json, sys
d = json.load(open(sys.argv[1]))
def lit(x):
    return json.dumps(x, ensure_ascii=False)
def num(x):
    return "nil" if x is None else (repr(float(x)).rstrip('0').rstrip('.') if float(x) != int(x) else str(int(x)))
out = ['''//
//  ModelRecommendations.swift
//  Dev
//

import Foundation

// MARK: - ModelRecommendations

/// The models each preset suggests for translating UI strings, with list prices in USD
/// per million tokens. Checked on providers' own pricing and model pages on
/// ''' + d["checked"] + ''' (generated from that research; prices and ids move, so the Settings
/// pane shows them as a guide and the model field stays free text).
nonisolated enum ModelRecommendations {
  /// By preset id. A regional twin (`alibaba-cn`) reads its sibling's list.
  static func forPreset(_ id: String) -> [ModelRecommendation] {
    byProvider[id] ?? byProvider[aliases[id] ?? ""] ?? []
  }

  private static let aliases = [
    "alibaba-cn": "alibaba", "kimi-coding-cn": "kimi-coding", "minimax-cn": "minimax",
  ]

  private static let byProvider: [String: [ModelRecommendation]] = [''']
for p in d["providers"]:
    out.append(f'    {lit(p["id"])}: [')
    for m in p["models"]:
        out.append(f'      .init(model: {lit(m["id"])}, role: .{m["role"]}, input: {num(m["input"])}, output: {num(m["output"])},')
        out.append(f'            reason: {lit(m["reason"])}),')
    out.append('    ],')
out.append('  ]\n}\n')
print("\n".join(out))
