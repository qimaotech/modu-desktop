import Foundation
import Yams

public enum ConfigValidation {
    public static func validateDocument(_ text: String, workspace: Bool) throws {
        guard let mapping = try Yams.compose(yaml: text)?.mapping else { throw ModuError("invalid-configuration", "Expected one configuration document.") }
        try keys(mapping, allowed: workspace ? ["version", "root", "repositories", "groups"] : ["version", "repositories", "groups"])
        for pair in mapping {
            if pair.key.string == "repositories" {
                guard let sequence = pair.value.sequence else { throw ModuError("invalid-configuration", "repositories must be a list.") }
                for repo in sequence {
                    guard let map = repo.mapping else { throw ModuError("invalid-configuration", "Repository must be a mapping.") }
                    try keys(map, allowed: ["url", "name"])
                }
            }
            if pair.key.string == "groups" {
                guard let groups = pair.value.mapping else { throw ModuError("invalid-configuration", "groups must be a mapping.") }
                try keys(groups, allowed: nil)
                for group in groups {
                    guard let map = group.value.mapping else { throw ModuError("invalid-configuration", "Group must be a mapping.") }
                    try keys(map, allowed: ["created-at", "repositories"])
                }
            }
        }
    }
    private static func keys(_ map: Node.Mapping, allowed: Set<String>?) throws {
        var seen = Set<String>()
        for pair in map {
            guard let key = pair.key.string, seen.insert(key).inserted, allowed?.contains(key) != false else { throw ModuError("invalid-configuration", "Unknown or duplicate configuration field.") }
        }
    }
}
