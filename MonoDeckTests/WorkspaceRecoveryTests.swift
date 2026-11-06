import Foundation
import Testing
@testable import MonoDeckCore

struct WorkspaceRecoveryTests {
    @MainActor @Test(arguments: [false, true])
    func recoveryBoundsConcurrencyAndKeepsOrderOrCancelsWithoutSaving(_ cancel: Bool) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let original = try f.service.store.load(f.root)
        let names = ["repo", "repo-1", "repo-2", "repo-3", "repo-4"]
        for name in names.dropFirst() {
            let path = original.repositoryURL(name)
            try FileManager.default.copyItem(at: original.repositoryURL("repo"), to: path)
            _ = try await f.service.git.run(["config", "remote.origin.url", "https://mono-deck-test.invalid/\(name).git"], at: path)
        }
        let file = f.service.store.recordURL(f.root)
        try FileManager.default.removeItem(at: file)
        var gates: [ReloadValidationGate] = []
        defer { for index in gates.indices { try? gates[index].resume() } }
        for name in names { gates.append(try ReloadValidationGate(original.repositoryURL(name))) }
        let opening = Task { await f.service.openWorkspaceWithRecord(f.root, recoverUnregisteredResources: true) }
        do {
            for index in 0..<4 { try await gates[index].waitUntilStarted() }
            let fifthStarted = gates[4].connectIfStarted()
            #expect(!fifthStarted)
            try gates[3].resume()
            try await gates[4].waitUntilStarted()
            #expect(!PathSafety.exists(file))
            if cancel {
                opening.cancel()
            } else {
                for index in [4, 2, 1, 0] { try gates[index].resume() }
            }
            let opened = await opening.value
            if cancel {
                #expect(opened.result.status == .cancelled && opened.result.items.allSatisfy { $0.effects.isEmpty })
                #expect(!PathSafety.exists(file))
            } else {
                #expect(opened.result.status == .success, "\(opened.result.items)")
                #expect(opened.record?.repositories.map(\.id) == names)
            }
            let lease = try f.service.store.tryLock(f.root); lease.unlock()
        } catch {
            opening.cancel()
            for index in gates.indices { try? gates[index].resume() }
            _ = await opening.value
            throw error
        }
    }

    @Test func recoveryAvoidsDuplicateReadsAndValidatesWorktreeOrigin() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        try await f.prepareGroup("feature", repositoryIDs: ["repo"])
        let record = try f.service.store.load(f.root)
        let main = record.repositoryURL("repo")
        _ = try await f.service.git.run(["switch", "-c", "external/root"], at: record.groupURL("feature"))
        _ = try await f.service.git.run(["switch", "-c", "external/member"], at: record.memberURL("feature", "repo"))
        _ = try await f.service.git.run(["config", "extensions.worktreeConfig", "true"], at: main)
        _ = try await f.service.git.run(["config", "--worktree", "remote.origin.url", "https://mono-deck-test.invalid/other.git"], at: record.memberURL("feature", "repo"))
        let file = f.service.store.recordURL(f.root)
        try FileManager.default.removeItem(at: file)
        let trace = f.directory.appending(path: "recovery-trace")
        var git = f.service.git
        git.runner.environment["GIT_TRACE"] = trace.path
        let service = WorkspaceService(store: f.service.store, git: git)
        #expect(try await service.candidate(f.root, recoverUnregisteredResources: true) == PathSafety.canonical(f.root))
        #expect(!PathSafety.exists(file))
        let commands = try String(contentsOf: trace, encoding: .utf8).components(separatedBy: "\n")
        #expect(commands.filter { $0.contains("built-in: git config --get remote.origin.url") }.count == 2)
        #expect(commands.filter { $0.contains("built-in: git rev-parse --show-toplevel") }.count == 4)
        #expect(commands.filter { $0.contains("built-in: git worktree list") }.count == 2)
        let opened = await service.openWorkspaceWithRecord(f.root, recoverUnregisteredResources: true)
        #expect(opened.result.status == .success && opened.record?.repositories.map(\.id) == ["repo"])
        #expect(opened.record?.groups["feature"]?.repositoryIDs == [])
        #expect(opened.record?.groups["feature"]?.branchName == "external/root")
    }

    @Test func recoveryPreservesGitStateAndRunsWorkspaceMaintenance() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        var initial = try f.service.store.load(f.root)
        let other = Repository(url: "https://mono-deck-test.invalid/other.git")
        try FileManager.default.copyItem(at: initial.repositoryURL("repo"), to: initial.repositoryURL(other.id))
        _ = try await f.service.git.run(["config", "remote.origin.url", other.url], at: initial.repositoryURL(other.id))
        initial.repositories.append(other)
        try f.service.store.save(initial)
        _ = try await f.service.git.ensureIgnore([other.id], at: f.root)
        try await f.commitWorkspace()
        try await f.prepareGroup("feature", repositoryIDs: ["repo", "other"])
        try await f.prepareGroup("review", repositoryIDs: ["repo"])
        try await f.prepareEmptyGroup("empty")
        var previous = try f.service.store.load(f.root)
        previous.repositories[0].displayNameOverride = "Custom"
        previous.groups["feature"]?.createdAt = "2001-01-01T00:00:00Z"
        try f.service.store.save(previous)
        let main = previous.repositoryURL("repo")
        _ = try await f.service.git.run(["checkout", "-b", "external/task"], at: previous.groupURL("feature"))
        _ = try await f.service.git.run(["checkout", "--detach"], at: previous.memberURL("feature", "repo"))
        _ = try await f.service.git.run(["checkout", "--detach"], at: previous.groupURL("review"))
        _ = try await f.service.git.run(["worktree", "lock", previous.memberURL("feature", "repo").path], at: main)
        var files = Dictionary(uniqueKeysWithValues: previous.repositories.map { (previous.repositoryURL($0.id), "README") })
        for name in previous.groups.keys {
            files[previous.groupURL(name)] = ".gitignore"
            for repo in previous.groups[name]!.repositoryIDs { files[previous.memberURL(name, repo)] = "README" }
        }
        var before: [URL: [Data]] = [:]
        for (path, file) in files {
            let tracked = path.appending(path: file)
            var staged = try Data(contentsOf: tracked); staged.append(Data("\n# staged\n".utf8))
            try staged.write(to: tracked)
            _ = try await f.service.git.run(["add", "--", file], at: path)
            staged.append(Data("\n# unstaged\n".utf8))
            try staged.write(to: tracked)
            try Data("untracked".utf8).write(to: path.appending(path: "untracked.txt"))
            before[path] = try await gitState(at: path, file: file, git: f.service.git)
        }
        let notes = f.root.appending(path: "notes.txt")
        try Data("staged notes".utf8).write(to: notes)
        _ = try await f.service.git.run(["add", "notes.txt"], at: f.root)
        try Data("unstaged notes".utf8).write(to: notes)
        let skill = f.directory.appending(path: "SKILL.md")
        try Data("# Updated workflow\n".utf8).write(to: skill)
        let recordURL = f.service.store.recordURL(f.root)
        try FileManager.default.removeItem(at: recordURL)
        let refs = try await f.service.git.run(["for-each-ref", "--format=%(refname) %(objectname)"], at: main).stdout
        let started = Date().addingTimeInterval(-1)
        #expect(try await f.service.candidate(f.root, recoverUnregisteredResources: true) == PathSafety.canonical(f.root))
        #expect(!PathSafety.exists(recordURL))
        let opened = await f.service.openWorkspaceWithRecord(f.root, skill: skill, recoverUnregisteredResources: true)
        #expect(opened.result.status == .success && opened.skillError == nil, "\(opened.result.items)")
        let restored = try #require(opened.record)
        #expect(restored.repositories == [other, Repository(url: f.remoteURL)])
        #expect(Set(restored.groups.keys) == Set(previous.groups.keys))
        for (name, group) in restored.groups {
            #expect(Set(group.repositoryIDs) == Set(previous.groups[name]!.repositoryIDs))
            #expect(try #require(ISO8601DateFormatter().date(from: group.createdAt)) >= started)
        }
        #expect(restored.groups["feature"]?.branchName == "external/task")
        #expect(restored.groups["review"]?.branchName == "review")
        #expect(try f.service.store.load(f.root) == restored)
        for (path, file) in files { #expect(try await gitState(at: path, file: file, git: f.service.git) == before[path]) }
        #expect(try await f.service.git.run(["for-each-ref", "--format=%(refname) %(objectname)"], at: main).stdout == refs)
        #expect(try await f.service.git.registrations(at: main).contains {
            PathSafety.identity(URL(fileURLWithPath: $0.path)) == PathSafety.identity(previous.memberURL("feature", "repo")) && $0.locked
        })
        #expect(try Data(contentsOf: f.root.appending(path: ".agents/skills/mono-deck-workflow/SKILL.md")) == Data(contentsOf: skill))
        #expect(opened.result.items.flatMap(\.effects).contains { $0.action == "commit-workspace-files" })
        #expect(try await f.service.git.run(["show", ":notes.txt"], at: f.root).stdout == Data("staged notes".utf8))
        #expect(try Data(contentsOf: notes) == Data("unstaged notes".utf8))
    }

    @Test func recoverySkipsInvalidResourcesAndKeepsTheirFilesAndRegistrations() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        try await f.prepareGroup("valid", repositoryIDs: ["repo"])
        try await f.prepareGroup("broken-member", repositoryIDs: ["repo"])
        try await f.prepareGroup("foreign-root", repositoryIDs: ["repo"])
        let previous = try f.service.store.load(f.root)
        let broken = previous.memberURL("broken-member", "repo").appending(path: ".git")
        let foreign = previous.groupURL("foreign-root").appending(path: ".git")
        let rootLink = try Data(contentsOf: previous.groupURL("valid").appending(path: ".git"))
        let memberLink = try Data(contentsOf: previous.memberURL("valid", "repo").appending(path: ".git"))
        try rootLink.write(to: broken)
        try memberLink.write(to: foreign)
        let mismatch = previous.repositoryURL("mismatch")
        try FileManager.default.copyItem(at: previous.repositoryURL("repo"), to: mismatch)
        let invalidOrigin = previous.repositoryURL("invalid-origin")
        try FileManager.default.copyItem(at: previous.repositoryURL("repo"), to: invalidOrigin)
        _ = try await f.service.git.run(["config", "remote.origin.url", "file:///unsupported/repository.git"], at: invalidOrigin)
        let symlink = previous.repositoryURL("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: previous.repositoryURL("repo"))
        let docs = previous.groupURL("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false)
        try Data("user document".utf8).write(to: docs.appending(path: "README"))
        let external = f.directory.appending(path: "external-worktree")
        _ = try await f.service.git.run(["worktree", "add", "--detach", external.path], at: previous.repositoryURL("repo"))
        let registrations = try await f.service.git.run(["worktree", "list", "--porcelain", "-z"], at: previous.repositoryURL("repo")).stdout
        try FileManager.default.removeItem(at: f.service.store.recordURL(f.root))
        let opened = await f.service.openWorkspaceWithRecord(f.root, recoverUnregisteredResources: true)
        #expect(opened.result.status == .success, "\(opened.result.items)")
        let restored = try #require(opened.record)
        #expect(restored.repositories.map(\.id) == ["repo"])
        #expect(restored.groups.mapValues(\.repositoryIDs) == ["valid": ["repo"], "broken-member": []])
        #expect(try Data(contentsOf: broken) == rootLink && Data(contentsOf: foreign) == memberLink)
        #expect(try Data(contentsOf: docs.appending(path: "README")) == Data("user document".utf8))
        #expect(PathSafety.exists(mismatch) && PathSafety.exists(invalidOrigin) && PathSafety.exists(symlink) && PathSafety.exists(external))
        #expect(try await f.service.git.run(["worktree", "list", "--porcelain", "-z"], at: previous.repositoryURL("repo")).stdout == registrations)
    }

    @Test(arguments: ["saved", "corrupt", "unsupported", "required", "ordinary"])
    func recoveryDoesNotOverrideRegistrationOrOtherOpeningPolicies(_ kind: String) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        try await f.prepareGroup("feature", repositoryIDs: ["repo"])
        let file = f.service.store.recordURL(f.root)
        switch kind {
        case "saved": try f.service.store.save(WorkspaceRecord(root: PathSafety.canonical(f.root).path))
        case "corrupt": try Data("invalid".utf8).write(to: file)
        case "unsupported":
            var record = try f.service.store.load(f.root); record.version = 1
            try JSONEncoder().encode(record).write(to: file)
        default: try FileManager.default.removeItem(at: file)
        }
        let before = PathSafety.exists(file) ? try Data(contentsOf: file) : nil
        let opened = await f.service.openWorkspaceWithRecord(f.root, requireExistingRecord: kind == "required", recoverUnregisteredResources: kind != "ordinary")
        if kind == "saved" {
            #expect(opened.result.status == .success)
            #expect(opened.record?.repositories.isEmpty == true && opened.record?.groups.isEmpty == true)
        } else {
            let code = kind == "ordinary" ? "workspace-not-empty" : (kind == "required" ? "workspace-record-missing" : "invalid-workspace-record")
            #expect(opened.result.status == .failed && opened.result.items.first?.reasonCode == code)
            #expect(opened.result.items.allSatisfy { $0.effects.isEmpty })
            do {
                _ = try await f.service.candidate(f.root, requireExistingRecord: kind == "required", recoverUnregisteredResources: kind != "ordinary")
                Issue.record("Expected workspace selection to preserve the existing registration policy.")
            } catch { #expect((error as? MonoDeckError)?.code == code) }
        }
        #expect((PathSafety.exists(file) ? try Data(contentsOf: file) : nil) == before)
    }

    @Test(arguments: ["no-resources", "repositories", "worktrees", "missing-git"])
    func recoveryRejectsUnusableWorkspacesWithoutWrites(_ kind: String) async throws {
        let f = try await Fixture(template: .emptyWorkspace); defer { f.remove() }
        let marker = f.root.appending(path: "repositories/user-data")
        try Data("keep me".utf8).write(to: marker)
        if kind == "repositories" || kind == "worktrees" {
            let container = f.root.appending(path: kind)
            let target = f.directory.appending(path: "original-container")
            try FileManager.default.moveItem(at: container, to: target)
            try FileManager.default.createSymbolicLink(at: container, withDestinationURL: target)
        }
        if kind == "missing-git" { try FileManager.default.removeItem(at: f.root.appending(path: ".git")) }
        let file = f.service.store.recordURL(f.root)
        try FileManager.default.removeItem(at: file)
        let opened = await f.service.openWorkspaceWithRecord(f.root, recoverUnregisteredResources: true)
        #expect(opened.result.status == .failed && opened.result.items.allSatisfy { $0.effects.isEmpty })
        #expect(!PathSafety.exists(file))
        #expect(try Data(contentsOf: marker) == Data("keep me".utf8))
        if kind == "missing-git" { #expect(!PathSafety.exists(f.root.appending(path: ".git"))) }
    }

    @Test(arguments: [false, true])
    func recoveryVerifiesUncertainSavesAndCanRetryWithoutChangingResources(_ wrote: Bool) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        try await f.prepareGroup("feature", repositoryIDs: ["repo"])
        let record = try f.service.store.load(f.root)
        let path = record.memberURL("feature", "repo")
        let before = try await gitState(at: path, file: "README", git: f.service.git)
        let file = f.service.store.recordURL(f.root)
        try FileManager.default.removeItem(at: file)
        let store = WorkspaceStore(support: f.service.store.support) { data, url in
            if wrote { try data.write(to: url, options: .atomic) }
            throw MonoDeckError("injected", "Injected save failure")
        }
        let opened = await WorkspaceService(store: store, git: f.service.git).openWorkspaceWithRecord(f.root, recoverUnregisteredResources: true)
        #expect(opened.result.status == (wrote ? .success : .failed))
        if !wrote {
            #expect(opened.result.items.first?.reasonCode == "save-outcome-unknown")
            #expect(!PathSafety.exists(file))
        }
        let retried = await f.service.openWorkspaceWithRecord(f.root, recoverUnregisteredResources: true)
        #expect(retried.result.status == .success && retried.record?.groups["feature"]?.repositoryIDs == ["repo"])
        #expect(try await gitState(at: path, file: "README", git: f.service.git) == before)
    }

    @Test func recoveryKeepsSavedConfigurationWhenMaintenanceFails() async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        try await f.prepareGroup("feature", repositoryIDs: ["repo"])
        let previous = try f.service.store.load(f.root)
        let ignore = f.root.appending(path: ".gitignore")
        let original = try Data(contentsOf: ignore)
        try FileManager.default.removeItem(at: ignore)
        try FileManager.default.createDirectory(at: ignore, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: f.service.store.recordURL(f.root))
        let opened = await f.service.openWorkspaceWithRecord(f.root, recoverUnregisteredResources: true)
        #expect(opened.result.status == .failed && opened.result.items.first?.reasonCode == "ignore-unavailable")
        #expect(opened.result.items.flatMap(\.effects).contains { $0.action == "save-workspace-record" })
        #expect(try f.service.store.load(f.root).groups.mapValues(\.repositoryIDs) == previous.groups.mapValues(\.repositoryIDs))
        try FileManager.default.removeItem(at: ignore)
        try original.write(to: ignore)
        #expect(await f.service.openWorkspace(f.root).status == .success)
    }

    private func gitState(at path: URL, file: String, git: Git) async throws -> [Data] {
        var values: [Data] = []
        for arguments in [["rev-parse", "HEAD"], ["symbolic-ref", "--quiet", "HEAD"],
                          ["ls-files", "--stage", "-z"],
                          ["status", "--porcelain=v1", "-z", "--untracked-files=all"]] {
            values.append(try await git.run(arguments, at: path, allowFailure: arguments.first == "symbolic-ref").stdout)
        }
        values.append(try Data(contentsOf: path.appending(path: file)))
        if PathSafety.exists(path.appending(path: "untracked.txt")) { values.append(try Data(contentsOf: path.appending(path: "untracked.txt"))) }
        return values
    }
}
