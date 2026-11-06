import Foundation
import Testing
@testable import MonoDeckCore

struct CoreModelTests {
    @Test func legacyWorkspaceFieldsAndVersionsAreRejected() throws {
        for configuration in [
            "version: 2\nrepositories: [{url: https://example.test/repo.git, name: Label}]\ngroups: {}",
            "version: 2\nrepositories: []\ngroups: {feature: {created-at: '2026-11-05T00:00:00Z', repositories: []}}",
            "version: 2\nrepositories: ["
        ] {
            do { try WorkspaceDocumentValidation.validateConfigurationDocument(configuration); Issue.record("Expected configuration validation to fail.") }
            catch { #expect((error as? MonoDeckError)?.code == "invalid-workspace-configuration") }
        }
        var record = WorkspaceRecord(root: "/tmp/workspace")
        record.version = 1
        #expect(throws: MonoDeckError.self) { try WorkspaceStore().validate(record) }
    }

    @Test func workspaceStructureUsesCanonicalFieldNames() throws {
        let json = #"{"version":2,"root":"/tmp/workspace","repositories":[{"url":"https://example.test/service.git","display-name":"Service"}],"groups":{"feature":{"created-at":"2026-11-05T00:00:00Z","repository-ids":["service"]}}}"#
        let record = try JSONDecoder().decode(WorkspaceRecord.self, from: Data(json.utf8))
        let repository = try #require(record.repositories.first)
        #expect(repository.id == "service" && repository.displayNameOverride == "Service" && repository.displayName == "Service")
        #expect(Repository(url: repository.url).displayName == "service")
        #expect(record.groups["feature"]?.repositoryIDs == ["service"])

        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? NSDictionary)
        let expected = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        #expect(encoded == expected)
    }

    @Test func workspaceValidationPreservesDateFormatsAndRepositoryIDCaseRules() throws {
        let store = WorkspaceStore()
        var record = WorkspaceRecord(root: PathSafety.canonical(URL(fileURLWithPath: "/tmp/workspace")).path)
        record.repositories = [Repository(url: "https://example.test/Service.git")]
        record.groups = [
            "whole-seconds": .init(createdAt: "2026-11-05T00:00:00Z", repositoryIDs: ["Service"]),
            "fractional-seconds": .init(createdAt: "2026-11-05T00:00:00.123Z", repositoryIDs: ["Service"])
        ]
        try store.validate(record)

        record.groups["fractional-seconds"]?.repositoryIDs = ["service"]
        do { try store.validate(record); Issue.record("Expected a differently cased member ID to fail validation.") }
        catch {
            #expect((error as? MonoDeckError)?.code == "invalid-workspace-record")
            #expect((error as? MonoDeckError)?.userMessage == .invalidGroup("fractional-seconds"))
        }

        record.repositories.append(Repository(url: "https://example.test/service.git"))
        do { try store.validate(record); Issue.record("Expected differently cased repository IDs to conflict before group validation.") }
        catch {
            #expect((error as? MonoDeckError)?.code == "repository-conflict")
            #expect((error as? MonoDeckError)?.userMessage == .duplicateRepositoryID("service"))
        }
    }

    @Test func resourceEncodingUsesCanonicalIdentityFields() throws {
        let cases: [(Resource, String)] = [
            (.workspace(), #"{"kind":"workspace","path":"."}"#),
            (.cli(path: "/tmp/mono-deck"), #"{"kind":"cli","path":"/tmp/mono-deck"}"#),
            (.repository("repo"), #"{"kind":"repository","repository-id":"repo","path":"repositories/repo"}"#),
            (.group("feature"), #"{"kind":"group","group-name":"feature","path":"worktrees/feature"}"#),
            (.member(groupName: "feature", repositoryID: "repo"), #"{"kind":"member","group-name":"feature","repository-id":"repo","path":"worktrees/feature/repo"}"#)
        ]
        for (resource, json) in cases {
            let data = try JSONEncoder().encode(resource)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
            let expected = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
            #expect(object == expected)
            #expect(try JSONDecoder().decode(Resource.self, from: Data(json.utf8)) == resource)
        }
    }

    @Test(arguments: [
        #"{"kind":"member","repository-id":"repo","path":"worktrees/feature/repo"}"#,
        #"{"kind":"group","group-name":"feature","path":"worktrees/other"}"#,
        #"{"kind":"repository","repository-id":"repo","group-name":"feature","path":"repositories/repo"}"#,
        #"{"kind":"unknown","path":"."}"#
    ])
    func inconsistentResourceFieldsAreRejected(_ json: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Resource.self, from: Data(json.utf8)) }
    }

    @Test func operationStatesKeepTheirWireValuesAndExitCodes() throws {
        for (status, expected) in [(OperationStatus.success, "success"), (.partialSuccess, "partial-success"), (.confirmationRequired, "confirmation-required"), (.cancelled, "cancelled")] {
            let result = OperationResult(command: "test", workspace: nil, status: status)
            let data = try JSONEncoder().encode(result)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["status"] as? String == expected)
            #expect(try JSONDecoder().decode(OperationResult.self, from: data).status == status)
            #expect(result.exitCode == (status == .success ? 0 : status == .cancelled ? 130 : 1))
        }
    }

    @Test func operationEncodingKeepsTheCLIContractIndependentOfLocalizedMessages() throws {
        let path = "/tmp/含空格 %@/repo"
        let message = UserMessage.joined([.context(path, .operationCancelledCompletedResourcesWereKept), .cleanupFailed(.workingTreeHasChanges)], separator: "\n")
        let error = MonoDeckError("cleanup-failed", message)
        let item = ItemResult(.repository("repo"), status: .failed, error: error)
        let result = OperationResult(command: "repo.delete", workspace: path, status: .failed, items: [item], error: error)
        let data = try JSONEncoder().encode(result)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema-version"] as? Int == 2 && object["userMessage"] == nil && object["user-message"] == nil)
        #expect(object["message"] as? String == message.englishDescription)
        let encodedItem = try #require((object["items"] as? [[String: Any]])?.first)
        #expect(encodedItem["userMessage"] == nil && encodedItem["message"] as? String == error.message)
        let decoded = try JSONDecoder().decode(OperationResult.self, from: data)
        #expect(decoded.userMessage == nil && decoded.items.first?.userMessage == nil)

        let emptyItem = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ItemResult(.repository("repo")))) as? [String: Any])
        #expect(emptyItem["reason-code"] is NSNull && emptyItem["message"] is NSNull)

        let risk = UserMessage.changedPathsWillBePermanentlyDeleted(1)
        let target = DeletionTarget(resource: .member(groupName: "feature", repositoryID: "repo"), path: path, branch: "feature", detached: false,
                                    gitRegistered: true, exists: true, risks: [risk.englishDescription], riskMessages: [risk])
        let targetData = try JSONEncoder().encode(target)
        let targetObject = try #require(JSONSerialization.jsonObject(with: targetData) as? [String: Any])
        #expect(targetObject["git-registered"] as? Bool == true && targetObject["registered"] == nil)
        #expect(targetObject["riskMessages"] == nil && targetObject["risks"] as? [String] == [risk.englishDescription])
        #expect(try JSONDecoder().decode(DeletionTarget.self, from: targetData) == target)
    }
}
