import Foundation
import Yams

public enum WorkspaceDocumentValidation {
    public static func validateRecordDocument(_ text: String) throws {
        do {
            try validateDocument(text, rootFields: ["version", "root", "repositories", "groups"],
                                 invalidDocument: .expectedOneWorkspaceRecordDocument, invalidField: .unknownOrDuplicateWorkspaceRecordField)
        } catch { throw MonoDeckError.wrap(error, code: "invalid-workspace-record") }
    }

    public static func validateConfigurationDocument(_ text: String) throws {
        do {
            try validateDocument(text, rootFields: ["version", "repositories", "groups"], code: "invalid-workspace-configuration",
                                 invalidDocument: .expectedOneConfigurationDocument, invalidField: .unknownOrDuplicateConfigurationField)
        } catch { throw MonoDeckError.wrap(error, code: "invalid-workspace-configuration") }
    }

    private static func validateDocument(_ text: String, rootFields: Set<String>, code: String = "invalid-workspace-record", invalidDocument: UserMessage, invalidField: UserMessage) throws {
        guard let mapping = try Yams.compose(yaml: text)?.mapping else { throw MonoDeckError(code, invalidDocument) }
        try keys(mapping, allowed: rootFields, code: code, invalidField: invalidField)
        for pair in mapping {
            if pair.key.string == "repositories" {
                guard let sequence = pair.value.sequence else { throw MonoDeckError(code, .repositoriesMustBeList) }
                for repo in sequence {
                    guard let map = repo.mapping else { throw MonoDeckError(code, .repositoryMustBeMapping) }
                    try keys(map, allowed: ["url", "display-name"], code: code, invalidField: invalidField)
                }
            }
            if pair.key.string == "groups" {
                guard let groups = pair.value.mapping else { throw MonoDeckError(code, .groupsMustBeMapping) }
                try keys(groups, allowed: nil, code: code, invalidField: invalidField)
                for group in groups {
                    guard let map = group.value.mapping else { throw MonoDeckError(code, .groupMustBeMapping) }
                    try keys(map, allowed: ["branch-name", "created-at", "repository-ids"], code: code, invalidField: invalidField)
                }
            }
        }
    }
    private static func keys(_ map: Node.Mapping, allowed: Set<String>?, code: String, invalidField: UserMessage) throws {
        var seen = Set<String>()
        for pair in map {
            guard let key = pair.key.string, seen.insert(key).inserted, allowed?.contains(key) != false else { throw MonoDeckError(code, invalidField) }
        }
    }
}
