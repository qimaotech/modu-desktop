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
}
