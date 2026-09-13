//
//  TemplateStore.swift
//  ServerMaster
//
//  The built-in templates plus whatever the user saved or imported. Exported
//  files are plain JSON so they can be sent to a colleague, put in a repository
//  next to the project, or kept in a course handout.
//
//  An exported template never carries a path, a certificate or a database
//  password — only the shape of the profile. Someone else's folder layout is
//  their business, and a template that dragged private paths around would be a
//  quiet way to leak them.
//

import Foundation
import Observation

@Observable
final class TemplateStore {

    private(set) var userTemplates: [ProfileTemplate] = []
    /// The saved file could not be read. Shown once, in the gallery.
    private(set) var loadFailed = false

    /// Everything the gallery shows, built-in first.
    var all: [ProfileTemplate] { ProfileTemplate.builtIn + userTemplates }

    func templates(in category: TemplateCategory) -> [ProfileTemplate] {
        all.filter { $0.category == category }
    }

    /// Categories that actually have something in them, in display order.
    var categories: [TemplateCategory] {
        TemplateCategory.allCases.filter { category in
            all.contains { $0.category == category }
        }
    }

    private var storeURL: URL {
        AppPaths.support.appendingPathComponent("templates.json")
    }

    // MARK: - Loading and saving

    func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        // A broken file must not take the built-in catalogue down with it: the
        // gallery still works, the user's own templates are simply absent.
        guard let list = try? JSONDecoder().decode([ProfileTemplate].self, from: data) else {
            loadFailed = true
            return
        }
        loadFailed = false
        userTemplates = list.map { template in
            var copy = template
            copy.isUserDefined = true
            return copy
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(userTemplates) else { return }
        AppPaths.ensure(AppPaths.support)
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - Changing the list

    @discardableResult
    func add(_ template: ProfileTemplate) -> ProfileTemplate {
        var copy = template
        copy.isUserDefined = true
        // Two templates with the same id would make the gallery ambiguous.
        if all.contains(where: { $0.id == copy.id }) {
            copy.id = copy.id + "." + UUID().uuidString.prefix(4).lowercased()
        }
        userTemplates.append(copy)
        save()
        return copy
    }

    func remove(_ template: ProfileTemplate) {
        guard template.isUserDefined else { return }
        userTemplates.removeAll { $0.id == template.id }
        save()
    }

    func rename(_ template: ProfileTemplate, to title: String) {
        guard let index = userTemplates.firstIndex(where: { $0.id == template.id }) else { return }
        userTemplates[index].title = title
        save()
    }

    // MARK: - Files

    enum TemplateError: LocalizedError {
        case unreadable
        case wrongContents

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return String(localized: "The file could not be read.")
            case .wrongContents:
                return String(localized: "This file does not contain a ServerMaster template.")
            }
        }
    }

    /// Writes one or more templates to a file the user picked.
    func export(_ templates: [ProfileTemplate], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Exported templates arrive somewhere else as new, not as “mine”.
        let cleaned = templates.map { template -> ProfileTemplate in
            var copy = template
            copy.isUserDefined = false
            return copy
        }
        try encoder.encode(cleaned).write(to: url, options: .atomic)
    }

    /// Reads a file that holds either a single template or a list of them.
    @discardableResult
    func importTemplates(from url: URL) throws -> [ProfileTemplate] {
        guard let data = try? Data(contentsOf: url) else { throw TemplateError.unreadable }
        let decoder = JSONDecoder()

        let incoming: [ProfileTemplate]
        if let list = try? decoder.decode([ProfileTemplate].self, from: data) {
            incoming = list
        } else if let single = try? decoder.decode(ProfileTemplate.self, from: data) {
            incoming = [single]
        } else {
            throw TemplateError.wrongContents
        }
        guard !incoming.isEmpty else { throw TemplateError.wrongContents }

        return incoming.map { add($0) }
    }

    static let fileExtension = "smtemplate"
}
