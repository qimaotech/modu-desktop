import Foundation
import Testing
@testable import ModuCore

struct RepositoryPreparationTests {
    @Test(arguments: [false, true])
    func concurrentPreparationsReleaseTheLockAndPublishAgainstCurrentRecords(_ sameRepository: Bool) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let other = "https://modu-test.invalid/other.git"
        let gate = try PreparationGate(fixture, blockedIDs: ["repo", "other"], aliases: [other])
        let first = Task { await gate.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root) }
        var second: Task<OperationResult, Never>?
        do {
            let firstStart = try #require(await gate.waitForStarts(1).first)
            let lease = try fixture.service.store.tryLock(fixture.root)
            lease.unlock()
            let next = Task { await gate.service.addRepository(.init(url: sameRepository ? fixture.remoteURL : other), at: fixture.root) }
            second = next
            let starts = try await gate.waitForStarts(2)
            let secondStart = try #require(starts.first { $0.token != firstStart.token })
            #expect(try fixture.service.store.load(fixture.root).repositories.isEmpty)

            try gate.release(firstStart)
            let firstResult = await first.value
            #expect(firstResult.status == .success && firstResult.items.first?.data?["disposition"] == "added")
            try gate.release(secondStart)
            let secondResult = await next.value
            #expect(secondResult.status == .success)
            #expect(secondResult.items.first?.data?["disposition"] == (sameRepository ? "already-exists" : "added"))
            #expect(try fixture.service.store.load(fixture.root).repositories.map(\.id) == (sameRepository ? ["repo"] : ["repo", "other"]))
            #expect(try stagingDirectories(in: fixture).isEmpty)
        } catch {
            first.cancel(); second?.cancel()
            try? gate.releaseAll()
            _ = await first.value
            _ = await second?.value
            throw error
        }
    }

    @Test func addingAnExistingRepositoryStillWorksWithoutItsRemote() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        try FileManager.default.removeItem(at: fixture.directory.appending(path: "repo.git"))
        let trace = fixture.directory.appending(path: "existing-repository-trace")
        var runner = fixture.service.git.runner
        runner.environment["GIT_TRACE"] = trace.path
        let service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner), trash: fixture.service.trashDirectory)
        let result = await service.addRepository(.init(url: fixture.remoteURL), at: fixture.root)
        #expect(result.status == .success && result.items.first?.data?["disposition"] == "already-exists")
        let commands = try String(contentsOf: trace, encoding: .utf8)
        #expect(!commands.contains("git clone ") && !commands.contains("ls-remote"))
        #expect(try stagingDirectories(in: fixture).isEmpty)
    }

    @Test(arguments: ["none", "directory", "file", "registered"])
    func workspacePublicationExcludesOnlyItsOwnStagingDirectory(_ foreign: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let gate = try PreparationGate(fixture, blockedIDs: ["repo"])
        let record = try fixture.service.store.load(fixture.root)
        let external = fixture.root.appending(path: "repositories/.modu-clone-external")
        let other = "https://modu-test.invalid/other.git"
        let data = Data("user data".utf8)
        let operation = Task { await gate.service.importWorkspaceYAML(workspaceYAML([fixture.remoteURL]), at: fixture.root) }
        do {
            let start = try #require(await gate.waitForStarts(1).first)
            let userFile: URL
            if foreign == "registered" {
                _ = try await fixture.service.git.run(["config", "--global", "--add", "url.\(fixture.directory.appending(path: "repo.git").path).insteadOf", other], at: fixture.root)
                #expect(await fixture.service.addRepository(.init(url: other), at: fixture.root).status == .success)
                userFile = record.repositoryURL("other").appending(path: "README")
            } else if foreign == "directory" {
                try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
                userFile = external.appending(path: "notes")
            } else { userFile = external }
            if foreign != "none", foreign != "registered" { try data.write(to: userFile) }
            try gate.release(start)
            let result = await operation.value
            if foreign == "none" {
                #expect(result.status == .success)
                #expect(try fixture.service.store.load(fixture.root).repositories.map(\.id) == ["repo"])
                #expect(try stagingDirectories(in: fixture).isEmpty)
            } else {
                let codes = [result.reasonCode].compactMap { $0 } + result.items.compactMap(\.reasonCode)
                #expect(result.status == .failed && codes.contains("workspace-not-empty"))
                #expect(!PathSafety.exists(record.repositoryURL("repo")))
                if foreign == "registered" {
                    #expect(try fixture.service.store.load(fixture.root).repositories.map(\.id) == ["other"])
                    #expect(try String(contentsOf: userFile, encoding: .utf8) == "hello\n")
                    #expect(try stagingDirectories(in: fixture).isEmpty)
                } else {
                    #expect(try fixture.service.store.load(fixture.root) == record)
                    #expect(try Data(contentsOf: userFile) == data)
                    let remaining = try stagingDirectories(in: fixture).map(PathSafety.identity)
                    let expected = [PathSafety.identity(external)]
                    #expect(remaining == expected)
                }
            }
        } catch {
            operation.cancel(); try? gate.releaseAll()
            _ = await operation.value
            throw error
        }
    }

    @Test func replacingTheOwnedStagingDirectoryDoesNotDeleteItsReplacement() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let gate = try PreparationGate(fixture, blockedIDs: ["repo"])
        let record = try fixture.service.store.load(fixture.root)
        let operation = Task { await gate.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root) }
        do {
            let start = try #require(await gate.waitForStarts(1).first)
            let staging = start.directory.deletingLastPathComponent()
            try #require(staging.lastPathComponent.hasPrefix(".modu-clone-"))
            let moved = fixture.directory.appending(path: "moved-owned-staging")
            try FileManager.default.moveItem(at: staging, to: moved)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            let userFile = staging.appending(path: "notes")
            let data = Data("replacement data".utf8)
            try data.write(to: userFile)
            operation.cancel()
            let result = await operation.value
            #expect(result.status == .failed && result.items.contains { $0.reasonCode == "cleanup-failed" })
            #expect(try Data(contentsOf: userFile) == data)
            #expect(PathSafety.exists(moved))
            #expect(try fixture.service.store.load(fixture.root) == record)
            #expect(!PathSafety.exists(record.repositoryURL("repo")))
        } catch {
            operation.cancel(); try? gate.releaseAll()
            _ = await operation.value
            throw error
        }
    }

    private func stagingDirectories(in fixture: Fixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixture.root.appending(path: "repositories"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".modu-clone-") }
            .sorted { $0.path < $1.path }
    }

    private func workspaceYAML(_ urls: [String]) -> String {
        "version: 1\nrepositories:\n" + urls.map { "  - url: \($0)\n" }.joined() + "groups: {}\n"
    }
}

private struct PreparationGate {
    struct Start {
        let token: String
        let directory: URL
    }

    let service: WorkspaceService
    private let probe: URL

    init(_ fixture: Fixture, blockedIDs: [String], aliases: [String] = []) throws {
        probe = fixture.directory.appending(path: "preparation-probe")
        for name in ["started", "release"] {
            try FileManager.default.createDirectory(at: probe.appending(path: name), withIntermediateDirectories: true)
        }
        let hooks = fixture.directory.appending(path: "preparation-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
        let hook = hooks.appending(path: "post-checkout")
        try Data("""
        #!/bin/sh
        origin=$(/usr/bin/git config --get remote.origin.url)
        name=${origin##*/}
        name=${name%.git}
        case "$MODU_PREPARATION_BLOCKED_IDS" in
          *"|$name|"*)
            printf '%s' "$PWD" > "$MODU_PREPARATION_PROBE/started/$$"
            trap 'exit 143' TERM INT
            while [ ! -e "$MODU_PREPARATION_PROBE/release/$$" ]; do sleep 0.02; done
            ;;
        esac
        """.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        var runner = fixture.service.git.runner
        runner.environment["MODU_PREPARATION_PROBE"] = probe.path
        runner.environment["MODU_PREPARATION_BLOCKED_IDS"] = "|" + blockedIDs.joined(separator: "|") + "|"
        let configuration = [("core.hooksPath", hooks.path)] + aliases.map {
            ("url.\(fixture.directory.appending(path: "repo.git").path).insteadOf", $0)
        }
        var index = Int(runner.environment["GIT_CONFIG_COUNT"] ?? "0") ?? 0
        for (key, value) in configuration {
            runner.environment["GIT_CONFIG_KEY_\(index)"] = key
            runner.environment["GIT_CONFIG_VALUE_\(index)"] = value
            index += 1
        }
        runner.environment["GIT_CONFIG_COUNT"] = String(index)
        service = WorkspaceService(store: fixture.service.store, git: Git(runner: runner), trash: fixture.service.trashDirectory)
    }

    func waitForStarts(_ count: Int) async throws -> [Start] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let values = try starts()
            if values.count >= count { return values }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ModuError("test-timeout", "Expected \(count) blocked repository preparations.")
    }

    func release(_ start: Start) throws {
        try Data().write(to: probe.appending(path: "release/\(start.token)"))
    }

    func releaseAll() throws {
        for value in try starts() { try release(value) }
    }

    private func starts() throws -> [Start] {
        try FileManager.default.contentsOfDirectory(at: probe.appending(path: "started"), includingPropertiesForKeys: nil).sorted { $0.path < $1.path }.compactMap { file in
            let path = try String(contentsOf: file, encoding: .utf8)
            guard !path.isEmpty else { return nil }
            return Start(token: file.lastPathComponent, directory: URL(fileURLWithPath: path))
        }
    }
}
