import Foundation
import Testing
@testable import ModuCore

struct ResourceReadSessionTests {
    @Test func unchangedResourcesAndIndexChangesReuseRepositoryPreparation() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        let trace = f.directory.appending(path: "read-session-trace")
        let service = tracedService(f, trace: trace)
        let session = ResourceReadSession(service: service)
        let resource = Resource.repository("repo")
        let first = try await session.prepare(resource, in: record)
        try Data().write(to: trace)
        var unrelated = record
        unrelated.groups["unrelated"] = WorktreeGroup()
        let reused = try await session.prepare(resource, in: unrelated)
        #expect(reused.workspace == unrelated && reused.isValid(in: unrelated))
        #expect(try String(contentsOf: trace, encoding: .utf8).isEmpty)
        try Data("indexed".utf8).write(to: first.path.appending(path: "new.txt"))
        _ = try await service.git.run(["add", "new.txt"], at: first.path)
        try Data().write(to: trace)
        let changedIndex = try await session.prepare(resource, in: unrelated)
        #expect(changedIndex.isValid(in: unrelated))
        let commands = try String(contentsOf: trace, encoding: .utf8)
        #expect(commands.contains("ls-files --stage"))
        #expect(!commands.contains("worktree list") && !commands.contains("rev-parse --absolute-git-dir"))
        try Data("[submodule \"new\"]\n    path = new\n    url = https://modu-test.invalid/new.git\n".utf8).write(to: first.path.appending(path: ".gitmodules"))
        try Data().write(to: trace)
        _ = try await session.prepare(resource, in: unrelated)
        let submoduleConfigurationCommands = try String(contentsOf: trace, encoding: .utf8)
        #expect(submoduleConfigurationCommands.contains("ls-files --stage") && !submoduleConfigurationCommands.contains("worktree list"))
    }

    @Test func includedConfigurationChangesAndExplicitRevalidationCannotUseOldPreparation() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        let included = f.directory.appending(path: "included.gitconfig")
        try Data("[alias]\n    read-probe = first\n".utf8).write(to: included)
        let global = f.directory.appending(path: "gitconfig")
        var configuration = try Data(contentsOf: global)
        configuration.append(Data("\n[include]\n    path = \(included.path)\n".utf8))
        try configuration.write(to: global)
        let trace = f.directory.appending(path: "configuration-trace")
        let service = tracedService(f, trace: trace)
        let session = ResourceReadSession(service: service)
        _ = try await session.prepare(.repository("repo"), in: record)
        let initialCommands = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
        #expect(initialCommands.filter { $0.contains("config --null --show-origin --includes --list") }.count == 1)
        #expect(initialCommands.filter { $0.contains("config --null --show-origin --includes --type=path --get-regexp") }.count == 1)
        try Data().write(to: trace)
        _ = try await session.prepare(.repository("repo"), in: record)
        #expect(try String(contentsOf: trace, encoding: .utf8).isEmpty)
        try Data("[alias]\n    read-probe = changed\n".utf8).write(to: included)
        try Data().write(to: trace)
        _ = try await session.prepare(.repository("repo"), in: record)
        #expect(try String(contentsOf: trace, encoding: .utf8).contains("worktree list"))
        try Data().write(to: trace)
        _ = try await session.prepare(.repository("repo"), in: record, revalidateConfiguration: true)
        let commands = try String(contentsOf: trace, encoding: .utf8)
        #expect(commands.split(separator: "\n").filter { $0.contains("config --null --show-origin --includes --list") }.count == 1)
        #expect(commands.split(separator: "\n").filter { $0.contains("config --null --show-origin --includes --type=path --get-regexp") }.count == 1)
        #expect(!commands.contains("worktree list") && !commands.contains("rev-parse --absolute-git-dir"))
    }

    @Test(arguments: [false, true])
    func creatingOrFillingAnIncludedConfigurationRechecksTheOrigin(_ initiallyEmpty: Bool) async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        let directory = f.directory.appending(path: "configuration")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parent = directory.appending(path: "parent.gitconfig")
        let included = directory.appending(path: "new.gitconfig")
        try Data("[include]\n    path = new.gitconfig\n".utf8).write(to: parent)
        if initiallyEmpty { try Data().write(to: included) }
        _ = try await f.service.git.run(["config", "--add", "include.path", parent.path], at: record.repositoryURL("repo"))
        let session = ResourceReadSession(service: f.service)
        _ = try await session.prepare(.repository("repo"), in: record)

        try writeDifferentOrigin(to: included)
        await expectPreparationFailure(session, resource: .repository("repo"), in: record, code: "origin-mismatch")
    }

    @Test func retargetingAnIncludedConfigurationSymlinkRechecksTheOrigin() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        let first = f.directory.appending(path: "first.gitconfig")
        let second = f.directory.appending(path: "second.gitconfig")
        let link = f.directory.appending(path: "included.gitconfig")
        try Data("[alias]\n    read-probe = first\n".utf8).write(to: first)
        try writeDifferentOrigin(to: second)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        _ = try await f.service.git.run(["config", "--add", "include.path", link.path], at: record.repositoryURL("repo"))
        let session = ResourceReadSession(service: f.service)
        _ = try await session.prepare(.repository("repo"), in: record)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        await expectPreparationFailure(session, resource: .repository("repo"), in: record, code: "origin-mismatch")
    }

    @Test func creatingADefaultConfigurationInvalidatesRepositoryPreparation() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        let home = f.directory.appending(path: "home")
        let trace = f.directory.appending(path: "default-configuration-trace")
        var runner = f.service.git.runner
        runner.environment["HOME"] = home.path
        runner.environment["XDG_CONFIG_HOME"] = f.directory.appending(path: "xdg").path
        runner.environment["GIT_TRACE"] = trace.path
        runner.environment.removeValue(forKey: "GIT_CONFIG_GLOBAL")
        let configuration = home.appending(path: ".gitconfig")
        let service = WorkspaceService(store: f.service.store, git: Git(runner: runner))
        let session = ResourceReadSession(service: service)
        _ = try await session.prepare(.repository("repo"), in: record)
        try Data().write(to: trace)
        _ = try await session.prepare(.repository("repo"), in: record)
        #expect(try String(contentsOf: trace, encoding: .utf8).isEmpty)

        try FileManager.default.createDirectory(at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await service.git.run(["config", "--file", configuration.path, "alias.read-probe", "created"], at: record.repositoryURL("repo"))
        #expect(try await service.git.run(["config", "--get", "alias.read-probe"], at: record.repositoryURL("repo")).text == "created")
        try Data().write(to: trace)
        let context = try await session.prepare(.repository("repo"), in: record)
        #expect(context.isValid(in: record))
        #expect(try String(contentsOf: trace, encoding: .utf8).contains("worktree list"))
    }

    @Test func reftableWorktreeBranchChangesReevaluateConditionalConfiguration() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let initial = try await prepare(f)
        let main = initial.repositoryURL("repo")
        _ = try await f.service.git.run(["refs", "migrate", "--ref-format=reftable"], at: main)
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == .success)
        let record = try f.service.store.load(f.root)
        let resource = Resource.member("feature", "repo")
        let path = record.memberURL("feature", "repo")
        let included = f.directory.appending(path: "conditional.gitconfig")
        try writeDifferentOrigin(to: included)
        _ = try await f.service.git.run(["config", "--add", "includeIf.onbranch:blocked.path", included.path], at: main)
        let session = ResourceReadSession(service: f.service)
        let context = try await session.prepare(resource, in: record)
        let head = context.gitDirectory.appending(path: "HEAD")
        let previousHEAD = try? Data(contentsOf: head)

        _ = try await f.service.git.run(["branch", "blocked"], at: main)
        _ = try await f.service.git.run(["symbolic-ref", "HEAD", "refs/heads/blocked"], at: path)
        #expect((try? Data(contentsOf: head)) == previousHEAD)
        await expectPreparationFailure(session, resource: resource, in: record, code: "origin-mismatch")
    }

    @Test func replacingGitDirectoryDiscardsPreparedIdentity() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        let session = ResourceReadSession(service: f.service)
        let resource = Resource.repository("repo")
        let first = try await session.prepare(resource, in: record)
        let identity = try RepositoryCacheIdentity(context: first)
        let previous = f.directory.appending(path: "previous-repository-git")
        try FileManager.default.moveItem(at: first.gitDirectory, to: previous)
        try FileManager.default.copyItem(at: previous, to: first.gitDirectory)
        let replaced = try await session.prepare(resource, in: record)
        #expect(try RepositoryCacheIdentity(context: replaced) != identity)
    }

    @Test func lightweightStatusUsesTheSameVisibilityWithoutExpandingUntrackedDirectories() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        let path = record.repositoryURL("repo")
        _ = try await f.service.git.run(["mv", "README", "renamed\nfile"], at: path)
        try FileManager.default.createDirectory(at: path.appending(path: "new-directory"), withIntermediateDirectories: false)
        for index in 0..<12 { try Data("new".utf8).write(to: path.appending(path: "new-directory/\(index).txt")) }
        let trace = f.directory.appending(path: "states-trace")
        let service = tracedService(f, trace: trace)
        let received = StateCollection()
        let result = await service.inspectStates(record, including: [.repository("repo")]) { state in await received.append(state) }
        #expect(result.status == .success && result.items.count == 1)
        let states = await received.values
        #expect(states.count == 1 && states.first?.available == true && states.first?.dirty == true)
        let light = try await service.git.hasVisibleChanges(at: path)
        let complete = try await service.git.workingState(at: path, visibility: .application)
        #expect(light == !complete.changes.isEmpty)
        let commands = try String(contentsOf: trace, encoding: .utf8)
        #expect(commands.contains("--untracked-files=normal"))
        #expect(!commands.contains("ls-files --stage") && !commands.contains("built-in: git log ") && !commands.contains("built-in: git fetch "))
    }

    private func prepare(_ f: Fixture) async throws -> WorkspaceRecord {
        #expect(await f.service.openWorkspace(f.root).status == .success)
        #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == .success)
        return try f.service.store.load(f.root)
    }

    private func expectPreparationFailure(_ session: ResourceReadSession, resource: Resource, in record: WorkspaceRecord, code: String) async {
        do {
            _ = try await session.prepare(resource, in: record)
            Issue.record("Expected changed configuration to invalidate repository preparation.")
        } catch { #expect((error as? ModuError)?.code == code) }
    }

    private func writeDifferentOrigin(to url: URL) throws {
        try Data("[remote \"origin\"]\n    url = https://modu-test.invalid/other.git\n".utf8).write(to: url)
    }

    private func tracedService(_ f: Fixture, trace: URL) -> WorkspaceService {
        var runner = f.service.git.runner
        runner.environment["GIT_TRACE"] = trace.path
        return WorkspaceService(store: f.service.store, git: Git(runner: runner))
    }
}

private actor StateCollection {
    private(set) var values: [ResourceState] = []
    func append(_ value: ResourceState) { values.append(value) }
}
