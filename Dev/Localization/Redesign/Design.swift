//
//  Stages.swift
//  Dev
//
//  Created by Dmitry on 12.09.26.
//

import SwiftUI

enum Translation {
  @Observable @MainActor class Context: Identifiable {
    var id: String
    var context: String = ""
    var version: Int = 0
    var limit: Int
    init(id: String, limit: Int) async throws {
      self.id = id
      self.limit = limit
      try await loadContext()
    }
    private func loadContext() async throws {
      
    }
    func append(value: String) {
      version += 1
      if context.isEmpty {
        context = value
      } else {
        context += "\n\(value)"
      }
    }
    func compressIfNeeded() async throws {
      guard context.count > limit else { return }
    }
  }
  @Observable @MainActor class Global {
    var context: Context
    var projects: [String: Project] = [:]
    init() async throws {
      context = try await Context(id: "global", limit: 10_000)
    }
    func loadProject(id: String) async throws -> Project {
      if let project = projects[id] {
        return project
      } else {
        let project = try await Project(id: id, global: self)
        self.projects[id] = project
        return project
      }
    }
  }
  @Observable @MainActor class Project: Identifiable {
    unowned let global: Global
    let id: String
    var context: Context
    var languages: [String: Language] = [:]
    var data: [LocalizationKey] = []
    init(id: String, global: Global) async throws {
      self.id = id
      self.global = global
      context = try await Context(id: "project/\(id)", limit: 10_000)
      try await loadLanguages()
    }
    private func loadLanguages() async throws {
      
    }
    func loadData() async throws {
      guard data.isEmpty else { return }
    }
    func saveData() async throws {
      guard !data.isEmpty else { return }
    }
    func verticalPrelearn() async throws -> VerticalPrelearn {
      try await loadData()
      return VerticalPrelearn(project: self)
    }
    func verticalLearn() async throws -> VerticalLearn {
      try await loadData()
      return VerticalLearn(project: self)
    }
    func verticalTranslate() async throws -> VerticalTranslate {
      try await loadData()
      return VerticalTranslate(project: self)
    }
    func horizontalTranslate() async throws -> HorizontalTranslate {
      try await loadData()
      return HorizontalTranslate(project: self)
    }
  }
  @Observable @MainActor class Language {
    let id: String
    unowned let project: Project
    var context: Context
    var global: Global { project.global }
    init(id: String, project: Project) async throws {
      self.id = id
      self.project = project
      context = try await Context(id: "project/\(project)/language/\(id)", limit: 1_000)
    }
  }
  struct LocalizationKey: Hashable {
    let source: StringBody
    let comment: String
    let maxWidth: Int
    var targets: [LocalizationString]
    var needsMachineTranslate: Bool {
      targets.contains(where: { $0.needsMachineTranslate })
    }
  }
  struct LocalizationString: Hashable, Identifiable {
    var id: String { language }
    let language: String
    var machine: StringBody = .empty
    var target: StringBody = .empty
    var status: Status = .stale
    var contextVersion: Int = 0
    var reviewed: StringBody?
    var toLearn: StringBody? {
      guard status == .verified else { return nil }
      guard let reviewed else { return target }
      guard reviewed != target else { return nil }
      return target
    }
    var needsPrelearn: Bool {
      status == .verified && !target.isEmpty && machine.isEmpty
    }
    var needsMachineTranslate: Bool {
      status == .needsTranslate
    }
    enum Status {
      case stale // translation wasn't found in the project
      case ignore // marked as don't translate
      case needsTranslate // needs translate
      case translated // translated by ai
      case imported // imported from sqlite db of known translations
      case verified // verified by user
    }
  }
  enum StringBody: Hashable {
    case value(String)
    case plural(Plurals)
    static var empty: StringBody { .value("") }
    var characters: Int {
      switch self {
      case .value(let value): value.count
      case .plural(let value): value.count
      }
    }
    var isEmpty: Bool {
      switch self {
      case .value(let value): value.isEmpty
      case .plural(let value): value.isEmpty
      }
    }
  }
  
  struct FullRow {
    var languages: [String: Language]
  }
  protocol VerticalOperation {
    var source: StringBody { get }
    var target: StringBody { get }
  }
}
extension Translation.VerticalOperation {
  var characters: Int {
    source.characters + target.characters
  }
}
