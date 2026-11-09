import Foundation

nonisolated struct ProfileRequirement: Identifiable, Equatable, Sendable {
    var command: String
    var phpVersion: String = ""
    var id: String { command + (phpVersion.isEmpty ? "" : "@" + phpVersion) }
    var title: String {
        phpVersion.isEmpty ? (Dependency.byCommand(command)?.title ?? command) : "\(command) \(phpVersion)"
    }

    static func list(for profile: ServerProfile, template: ProfileTemplate? = nil) -> [Self] {
        var commands = profile.requiredTools
        if template?.packageKind == "printshopcrm", !commands.contains("npm") { commands.append("npm") }
        let version = profile.phpVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return commands.map { Self(command: $0, phpVersion: ["php", "php-fpm"].contains($0) ? version : "") }
    }
}
