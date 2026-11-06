import Foundation
import Testing
@testable import MonoDeckCore

struct CLIContractTests {
    @Test(arguments: [false, true])
    func additiveGroupCommandsValidateOnceAndReuseRepositoryInspection(_ addingMembers: Bool) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        if addingMembers { try await f.prepareEmptyGroup("feature") }
        let command = addingMembers ? ["group", "member", "add", "feature", "repo"] : ["group", "create", "feature", "--repo", "repo"]
        let trace = f.directory.appending(path: "group-creation-trace")
        let output = try await f.runCLI(command + ["--json", "--workspace", f.root.path], environment: ["GIT_TRACE": trace.path])
        let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
        #expect(output.status == 0 && result.status == .success && !result.dryRun, "\(output.text)")
        #expect(result.command == (addingMembers ? "group.member.add" : "group.create"))
        #expect(result.items.count == (addingMembers ? 1 : 2) && result.plan == nil)
        #expect(try f.service.store.load(f.root).groups["feature"]?.repositoryIDs == ["repo"])
        let commands = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
        #expect(commands.filter { $0.contains("built-in: git check-ref-format refs/heads/feature") }.count == 1)
        #expect(commands.filter { $0.contains("built-in: git ls-tree -r -z ") }.count == 1)
        #expect(commands.filter { $0.contains("built-in: git worktree list --porcelain -z") }.count == 2)
        #expect(!commands.contains { $0.contains("built-in: git rev-parse --path-format=absolute --git-common-dir") })
    }

    @Test(arguments: [false, true])
    func additiveGroupCommandsReportEarlierEffectsWhenALaterMemberHasNoStartingCommit(_ addingMembers: Bool) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let other = try await addOtherRepository(f)
        if addingMembers { try await f.prepareEmptyGroup("feature") }
        let record = try f.service.store.load(f.root)
        _ = try await f.service.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], at: record.repositoryURL(other.id))
        let command = addingMembers
            ? ["group", "member", "add", "feature", "repo", other.id]
            : ["group", "create", "feature", "--repo", "repo", "--repo", other.id]
        let arguments = command + ["--json", "--workspace", f.root.path]
        let before = try Data(contentsOf: f.service.store.recordURL(f.root))
        let previewOutput = try await f.runCLI(arguments + ["--dry-run"])
        let preview = try JSONDecoder().decode(OperationResult.self, from: previewOutput.stdout)
        #expect(previewOutput.status == 1 && preview.status == .failed && preview.dryRun && preview.reasonCode == "base-unavailable")
        #expect(try Data(contentsOf: f.service.store.recordURL(f.root)) == before)

        let output = try await f.runCLI(arguments)
        let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
        #expect(output.status == 1 && result.status == .partialSuccess && !result.dryRun, "\(output.text)")
        #expect(result.plan == nil && result.items.count == (addingMembers ? 2 : 3))
        #expect(result.items.dropLast().allSatisfy { $0.status == .success && $0.effects.contains { $0.action == "create-worktree" && $0.state == "applied" } })
        #expect(result.items.last?.resource == .member(groupName: "feature", repositoryID: other.id))
        #expect(result.items.last?.status == .failed && result.items.last?.reasonCode == "base-unavailable")
        #expect(try f.service.store.load(f.root).groups["feature"]?.repositoryIDs == ["repo"])
        #expect(PathSafety.exists(record.memberURL("feature", "repo")) && !PathSafety.exists(record.memberURL("feature", other.id)))
    }

    @Test func confirmedGroupDeletionSkipsRiskScansWithoutChangingPreviewAuthorization() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        try await f.prepareGroup("feature", repositoryIDs: ["repo"])
        let record = try f.service.store.load(f.root)
        let member = record.memberURL("feature", "repo")
        let index = try await f.service.git.run(["rev-parse", "--path-format=absolute", "--git-path", "index"], at: member).text
        try Data("invalid index".utf8).write(to: URL(fileURLWithPath: index))
        _ = try await f.service.git.run(["config", "remote.origin.url", "https://mono-deck-test.invalid/renamed.git"], at: record.repositoryURL("repo"))
        let command = ["group", "delete", "feature", "--json", "--workspace", f.root.path]

        let pending = try await f.runCLI(command)
        let preview = try JSONDecoder().decode(OperationResult.self, from: pending.stdout)
        #expect(pending.status == 1 && preview.status == .confirmationRequired)
        #expect(preview.plan?.deletions.first?.dirty == nil)
        #expect(try f.service.store.load(f.root) == record && PathSafety.exists(member))

        let trace = f.directory.appending(path: "confirmed-deletion-trace")
        let applied = try await f.runCLI(command + ["--yes"], environment: ["GIT_TRACE": trace.path])
        let result = try JSONDecoder().decode(OperationResult.self, from: applied.stdout)
        #expect(applied.status == 0 && result.status == .success, "\(applied.text)")
        #expect(!PathSafety.exists(record.groupURL("feature")))
        #expect(try f.service.store.load(f.root).groups["feature"] == nil)
        let commands = try String(contentsOf: trace, encoding: .utf8)
        #expect(!commands.contains("built-in: git status "))
        #expect(!commands.contains("built-in: git config --get remote.origin.url"))
        #expect(!commands.contains("built-in: git show-ref "))
    }

    @Test func everyMutationCanBePreviewedWithoutChangingResourcesOrTakingTheWorkspaceLock() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let other = try await addOtherRepository(f)
        try await f.prepareGroup("existing", repositoryIDs: ["repo"])
        let record = try f.service.store.load(f.root)
        let before = try Data(contentsOf: f.service.store.recordURL(f.root))
        let ignore = try Data(contentsOf: f.root.appending(path: ".gitignore"))
        let paths = [f.root, record.repositoryURL("repo"), record.repositoryURL(other.id)]
        var references: [URL: Data] = [:]
        for path in paths { references[path] = try await f.service.git.run(["show-ref"], at: path).stdout }
        let trace = f.directory.appending(path: "dry-run-trace")
        let lease = try f.service.store.tryLock(f.root); defer { lease.unlock() }
        let commands = [
            ["repo", "add", "https://mono-deck-test.invalid/third.git", "--display-name", "Third"],
            ["repo", "add", f.remoteURL],
            ["group", "create", "new", "--repo", "repo"],
            ["group", "edit", "existing", "--repo", other.id],
            ["group", "member", "add", "existing", other.id],
            ["group", "member", "delete", "existing", "repo"],
            ["group", "delete", "existing"],
            ["repo", "delete", "repo"]
        ]
        for command in commands {
            let output = try await f.runCLI(command + ["--dry-run", "--yes", "--json", "--workspace", f.root.path], environment: ["GIT_TRACE": trace.path])
            let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
            #expect(output.status == 0 && result.status == .success && result.dryRun, "\(command): \(output.text)")
            #expect(result.plan?.actions.isEmpty == false)
            if command[0] == "repo", command[1] == "add" { #expect(result.plan?.actions.contains { $0.action == "maintain-workspace-ignore" } == true) }
            #expect(result.items.allSatisfy { $0.effects.isEmpty })
            #expect(try Data(contentsOf: f.service.store.recordURL(f.root)) == before)
            #expect(try Data(contentsOf: f.root.appending(path: ".gitignore")) == ignore)
            #expect(!PathSafety.exists(record.groupURL("new")) && !PathSafety.exists(record.memberURL("existing", other.id)))
        }
        for path in paths { #expect(try await f.service.git.run(["show-ref"], at: path).stdout == references[path]) }
        let commandsRun = try String(contentsOf: trace, encoding: .utf8)
        #expect(!commandsRun.contains("built-in: git clone ") && !commandsRun.contains("built-in: git fetch ") && !commandsRun.contains("built-in: git worktree add "))
    }

    @Test func membershipReplacementRequiresAuthorizationAndSupportsKeepingAnEmptyGroup() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let other = try await addOtherRepository(f)
        try await f.prepareGroup("existing", repositoryIDs: ["repo"])
        let before = try Data(contentsOf: f.service.store.recordURL(f.root))
        let edit = ["group", "edit", "existing", "--repo", other.id, "--json", "--workspace", f.root.path]
        let pending = try await f.runCLI(edit)
        let plan = try JSONDecoder().decode(OperationResult.self, from: pending.stdout)
        #expect(pending.status == 1 && plan.status == .confirmationRequired && !plan.dryRun)
        #expect(plan.plan?.deletions.map(\.resource) == [.member(groupName: "existing", repositoryID: "repo")])
        #expect(try Data(contentsOf: f.service.store.recordURL(f.root)) == before)
        #expect(!PathSafety.exists(f.root.appending(path: "worktrees/existing/other")))

        let applied = try await f.runCLI(edit + ["--yes"])
        #expect(applied.status == 0, "\(applied.text)")
        #expect(try f.service.store.load(f.root).groups["existing"]?.repositoryIDs == [other.id])
        let clear = try await f.runCLI(["group", "edit", "existing", "--clear-members", "--yes", "--json", "--workspace", f.root.path])
        #expect(clear.status == 0, "\(clear.text)")
        let record = try f.service.store.load(f.root)
        #expect(record.groups["existing"]?.repositoryIDs == [] && PathSafety.exists(record.groupURL("existing")))

        let added = try await f.runCLI(["group", "member", "add", "existing", "repo", other.id, "--json", "--workspace", f.root.path])
        #expect(added.status == 0, "\(added.text)")
        let deleted = try await f.runCLI(["group", "member", "delete", "existing", "repo", other.id, "--yes", "--json", "--workspace", f.root.path])
        let result = try JSONDecoder().decode(OperationResult.self, from: deleted.stdout)
        #expect(deleted.status == 0 && result.command == "group.member.delete" && result.items.count == 2)
        #expect(try f.service.store.load(f.root).groups["existing"]?.repositoryIDs == [])
        #expect(PathSafety.exists(record.groupURL("existing")))
    }

    @Test func groupCreationRejectsExistingNamesAndDisplayNamesDoNotChangeRepositoryIDs() async throws {
        let f = try await Fixture(); defer { f.remove() }
        try await f.prepareWorkspace()
        let added = try await f.runCLI(["repo", "add", f.remoteURL, "--display-name", "Service", "--json", "--workspace", f.root.path])
        #expect(added.status == 0, "\(added.text)")
        let repository = try #require(f.service.store.load(f.root).repositories.first)
        #expect(repository.id == "repo" && repository.displayName == "Service")
        let command = ["group", "create", "feature", "--repo", "repo", "--json", "--workspace", f.root.path]
        #expect(try await f.runCLI(command).status == 0)
        let before = try Data(contentsOf: f.service.store.recordURL(f.root))
        let repeated = try await f.runCLI(command)
        let result = try JSONDecoder().decode(OperationResult.self, from: repeated.stdout)
        #expect(repeated.status == 1 && result.reasonCode == "group-already-exists")
        #expect(try Data(contentsOf: f.service.store.recordURL(f.root)) == before)
    }

    @Test func removedCommandsAndFlagsAreRejectedWithoutMutation() async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        let before = try Data(contentsOf: f.service.store.recordURL(f.root))
        for command in [["worktree", "list"], ["workspace", "inspect"], ["repo", "remove", "repo"],
                        ["repo", "add", f.remoteURL, "--name", "Label"], ["repo", "delete", "repo", "--execute"],
                        ["group", "edit", "feature", "--clear-members", "--repo", "repo"]] {
            let output = try await f.runCLI(command + ["--json", "--workspace", f.root.path])
            let result = try JSONDecoder().decode(OperationResult.self, from: output.stdout)
            #expect(output.status == 2 && result.schemaVersion == 2 && result.reasonCode == "invalid-input")
            #expect(result.items.isEmpty && result.data == nil && result.plan == nil)
            #expect(try Data(contentsOf: f.service.store.recordURL(f.root)) == before)
        }
    }

    private func addOtherRepository(_ f: Fixture) async throws -> Repository {
        let repository = Repository(url: "https://mono-deck-test.invalid/other.git")
        _ = try await f.service.git.run(["config", "--global", "--add", "url.\(f.directory.appending(path: "repo.git").path).insteadOf", repository.url], at: f.root)
        try #require(await f.service.addRepository(repository, at: f.root).status == .success)
        return repository
    }
}
