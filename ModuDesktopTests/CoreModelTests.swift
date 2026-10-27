import Foundation
import Testing
@testable import ModuCore

struct CoreModelTests {
    @Test func resourceEncodingPreservesTheExistingJSONContract() throws {
        let cases: [(Resource, String)] = [
            (.workspace(), #"{"kind":"workspace","path":"."}"#),
            (.cli(path: "/tmp/modu-cli"), #"{"kind":"cli","path":"/tmp/modu-cli"}"#),
            (.repository("repo"), #"{"kind":"repository","repo":"repo","path":"repositories/repo"}"#),
            (.group("feature"), #"{"kind":"group","group":"feature","path":"worktrees/feature"}"#),
            (.member("feature", "repo"), #"{"kind":"member","group":"feature","repo":"repo","path":"worktrees/feature/repo"}"#)
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
        #"{"kind":"member","repo":"repo","path":"worktrees/feature/repo"}"#,
        #"{"kind":"group","group":"feature","path":"worktrees/other"}"#,
        #"{"kind":"repository","repo":"repo","group":"feature","path":"repositories/repo"}"#,
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
        let error = ModuError("cleanup-failed", message)
        let item = ItemResult(.repository("repo"), status: .failed, error: error)
        let result = OperationResult(command: "repo.remove", workspace: path, status: .failed, items: [item], error: error)
        let data = try JSONEncoder().encode(result)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema-version"] as? Int == 1 && object["userMessage"] == nil && object["user-message"] == nil)
        #expect(object["message"] as? String == message.englishDescription)
        let encodedItem = try #require((object["items"] as? [[String: Any]])?.first)
        #expect(encodedItem["userMessage"] == nil && encodedItem["message"] as? String == error.message)
        let decoded = try JSONDecoder().decode(OperationResult.self, from: data)
        #expect(decoded.userMessage == nil && decoded.items.first?.userMessage == nil)

        let emptyItem = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ItemResult(.repository("repo")))) as? [String: Any])
        #expect(emptyItem["reason-code"] is NSNull && emptyItem["message"] is NSNull)

        let risk = UserMessage.changedPathsWillBePermanentlyDeleted(1)
        let target = DeletionTarget(resource: .member("feature", "repo"), path: path, branch: "feature", detached: false,
                                    registered: true, exists: true, risks: [risk.englishDescription], riskMessages: [risk])
        let targetData = try JSONEncoder().encode(target)
        let targetObject = try #require(JSONSerialization.jsonObject(with: targetData) as? [String: Any])
        #expect(targetObject["riskMessages"] == nil && targetObject["risks"] as? [String] == [risk.englishDescription])
        #expect(try JSONDecoder().decode(DeletionTarget.self, from: targetData) == target)
    }
}
