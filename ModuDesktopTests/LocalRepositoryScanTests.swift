import Foundation
import Testing
@testable import ModuCore

struct LocalRepositoryScanTests {
    @Test func discoveryStopsAtRepositoriesAndSkipsGeneratedDirectoriesAndLinks() async throws {
        let f = try await Fixture(); defer { f.remove() }
        for url in ["git@example.invalid:team/bravo.git", "https://example.invalid/dist.git", "https://example.invalid/nested.git", "https://example.invalid/deeper.git", "https://example.invalid/indirect.git", "https://example.invalid/dependency.git", "https://example.invalid/outside.git"] {
            try await mapRemote(url, fixture: f)
        }
        let projects = f.directory.appending(path: "projects")
        let alpha = try await repository("projects/alpha", url: f.remoteURL, fixture: f)
        _ = try await repository("projects/alpha/nested", url: "https://example.invalid/nested.git", fixture: f)
        _ = try await repository("projects/alpha/nested/deeper", url: "https://example.invalid/deeper.git", fixture: f)
        _ = try await repository("projects/alpha/container/indirect", url: "https://example.invalid/indirect.git", fixture: f)
        _ = try await repository("projects/packages/bravo", url: "git@example.invalid:team/bravo.git", fixture: f)
        _ = try await repository("projects/node_modules/dependency", url: "https://example.invalid/dependency.git", fixture: f)
        let dist = try await repository("projects/dist", url: "https://example.invalid/dist.git", fixture: f)
        let outside = try await repository("outside", url: "https://example.invalid/outside.git", fixture: f)
        try FileManager.default.createSymbolicLink(at: projects.appending(path: "linked"), withDestinationURL: outside)
        let scan = try await self.scan([projects, projects], fixture: f)
        #expect(scan.urls == [f.remoteURL, "git@example.invalid:team/bravo.git"])
        for selected in [[projects, alpha, projects], [alpha, projects]] {
            let nested = try await self.scan(selected, fixture: f)
            #expect(nested.urls == [f.remoteURL, "https://example.invalid/nested.git", "git@example.invalid:team/bravo.git"])
        }
        let explicit = try await self.scan([dist], fixture: f)
        #expect(explicit.urls == ["https://example.invalid/dist.git"])
        #expect(!PathSafety.exists(f.root.appending(path: "repositories")))
    }

    @Test func readsWorktreesBareRepositoriesAndRemoteAliases() async throws {
        let f = try await Fixture(); defer { f.remove() }
        try await mapRemote("https://example.invalid/alias.git", fixture: f)
        try await mapRemote("https://example.invalid/sole.git", fixture: f)
        try await mapRemote("https://example.invalid/secondary.git", fixture: f)
        try await mapRemote("https://example.invalid/last.git", fixture: f)
        let source = f.directory.appending(path: "source")
        _ = try await f.service.git.run(["remote", "add", "origin", f.remoteURL], at: source)
        let linked = f.directory.appending(path: "linked")
        _ = try await f.service.git.run(["worktree", "add", "-b", "linked", linked.path], at: source)
        let bare = f.directory.appending(path: "repo.git")
        _ = try await f.service.git.run(["remote", "set-url", "origin", f.remoteURL], at: bare)
        let aliased = try await repository("aliased", url: "example:alias.git", fixture: f)
        _ = try await f.service.git.run(["config", "url.https://example.invalid/.insteadOf", "example:"], at: aliased)
        let soleRemote = try await repository("sole", url: "https://example.invalid/sole.git", remote: "upstream.with.dots", fixture: f)
        _ = try await f.service.git.run(["remote", "add", "upstream", "https://example.invalid/secondary.git"], at: aliased)
        _ = try await f.service.git.run(["config", "--add", "remote.origin.url", "https://example.invalid/last.git"], at: aliased)
        let scan = try await self.scan([linked, source, bare, aliased, soleRemote], fixture: f)
        #expect(scan.urls == [f.remoteURL, "https://example.invalid/alias.git", "https://example.invalid/sole.git"])
    }

    @Test func filtersRepositoriesWithoutAUsableRemoteAndDefaultBranch() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let valid = try await repository("projects/valid", url: f.remoteURL, fixture: f)
        let noRemote = try await repository("projects/no-remote", fixture: f)
        let nestedURL = "https://example.invalid/nested.git"
        _ = try await repository("projects/no-remote/nested", url: nestedURL, fixture: f)
        try await mapRemote(nestedURL, fixture: f)
        let multipleURL = "https://example.invalid/multiple.git"
        let multiple = try await repository("projects/multiple", url: multipleURL, remote: "first", fixture: f)
        try await mapRemote(multipleURL, fixture: f)
        _ = try await f.service.git.run(["config", "remote.second.fetch", "+refs/heads/*:refs/remotes/second/*"], at: multiple)
        let unsupported = try await repository("projects/unsupported", url: "https://secret@example.invalid/repo.git", fixture: f)
        let multilineURL = "https://example.invalid/multiline.git"
        let multiline = try await repository("projects/multiline", url: multilineURL + "\ninvalid", fixture: f)
        try await mapRemote(multilineURL, fixture: f)
        let broken = f.directory.appending(path: "projects/broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("invalid gitfile\n".utf8).write(to: broken.appending(path: ".git"))
        let missing = f.directory.appending(path: "missing")
        let unavailableURL = "https://example.invalid/unavailable.git"
        let unavailable = try await repository("projects/unavailable", url: unavailableURL, fixture: f)
        try await mapRemote(unavailableURL, to: f.directory.appending(path: "missing.git"), fixture: f)
        let emptyRemote = f.directory.appending(path: "empty.git")
        _ = try await f.service.git.run(["init", "--bare", emptyRemote.path], at: f.directory)
        let emptyURL = "https://example.invalid/empty.git"
        let empty = try await repository("projects/empty", url: emptyURL, fixture: f)
        try await mapRemote(emptyURL, to: emptyRemote, fixture: f)
        let scan = try await self.scan([noRemote, multiple, unsupported, multiline, broken, missing, unavailable, empty, valid], fixture: f)
        #expect(scan.urls == [nestedURL, f.remoteURL])
    }

    @Test(arguments: ["before", "discovery", "remote"])
    func cancellationStopsDiscoveryAndRemoteValidation(_ phase: String) async throws {
        let f = try await Fixture(); defer { f.remove() }
        let directory = try await repository("project", url: f.remoteURL, fixture: f)
        let cancelled = await Task {
            if phase == "before" { withUnsafeCurrentTask { $0?.cancel() } }
            do {
                _ = try await scan([directory], fixture: f) { progress in
                    if (phase == "discovery" && progress.phase == .scanningRepositories) || (phase == "remote" && progress.phase == .checkingRepository) {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                return false
            } catch { return ModuError.wrap(error).code == "cancelled" }
        }.value
        #expect(cancelled)
        #expect(!PathSafety.exists(f.root.appending(path: "repositories")))
    }

    @Test func validatesAtMostEightAndRefillsSlotsWhilePreservingDiscoveryOrder() async throws {
        let batch = try await ScanBatch(); defer { batch.fixture.remove() }
        let operation = Task { try await batch.service.scanLocalRepositories(in: batch.directories, at: batch.fixture.root) }
        do {
            try await batch.waitForStarts(8)
            try await Task.sleep(for: .milliseconds(150))
            #expect(try batch.started() == Set((0..<8).map { "repo\($0)" }))
            try Data().write(to: batch.probe.appending(path: "fail/repo3"))
            try batch.release(3)
            try await batch.waitForStarts(9)
            #expect(try batch.active().count == 8)
            try batch.release(8)
            try await batch.waitForStarts(10)
            #expect(try batch.active().count == 8)
            for index in 0..<10 { try batch.release(index) }
            let result = try await operation.value
            #expect(result.urls == batch.urls.enumerated().compactMap { $0.offset == 3 ? nil : $0.element })
            #expect(try batch.active().isEmpty)
        } catch {
            operation.cancel(); _ = await operation.result
            throw error
        }
    }

    @Test func cancellationStopsActiveRemoteChecksWithoutStartingQueuedOnes() async throws {
        let batch = try await ScanBatch(); defer { batch.fixture.remove() }
        let operation = Task { try await batch.service.scanLocalRepositories(in: batch.directories, at: batch.fixture.root) }
        do {
            try await batch.waitForStarts(8)
            operation.cancel()
            let result = await operation.result
            switch result {
            case .success: Issue.record("A cancelled scan must not return a repository selection.")
            case .failure(let error): #expect(ModuError.wrap(error).code == "cancelled")
            }
            #expect(try batch.started() == Set((0..<8).map { "repo\($0)" }))
            #expect(try batch.active().isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: batch.probe.appending(path: "stopped").path).count == 8)
        } catch {
            operation.cancel(); _ = await operation.result
            throw error
        }
    }

    private func scan(_ directories: [URL], fixture: Fixture, progress: ProgressHandler = { _ in }) async throws -> LocalRepositoryScan {
        var git = fixture.service.git
        git.runner.environment["GIT_ALLOW_PROTOCOL"] = "file"
        let service = WorkspaceService(store: fixture.service.store, git: git, trash: fixture.service.trashDirectory)
        return try await service.scanLocalRepositories(in: directories, at: fixture.root, progress: progress)
    }

    private func mapRemote(_ url: String, to destination: URL? = nil, fixture: Fixture) async throws {
        let remote = destination ?? fixture.directory.appending(path: "repo.git")
        _ = try await fixture.service.git.run(["config", "--global", "--add", "url.\(remote.path).insteadOf", url], at: fixture.directory)
    }

    private func repository(_ relative: String, url: String? = nil, remote: String = "origin", fixture: Fixture) async throws -> URL {
        let directory = fixture.directory.appending(path: relative)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await fixture.service.git.run(["init", "-b", "main"], at: directory)
        if let url { _ = try await fixture.service.git.run(["remote", "add", remote, url], at: directory) }
        return directory
    }
}

private struct ScanBatch {
    let fixture: Fixture
    let service: WorkspaceService
    let directories: [URL]
    let urls: [String]
    let probe: URL

    init() async throws {
        let f = try await Fixture()
        fixture = f
        probe = f.directory.appending(path: "scan-probe")
        for name in ["started", "active", "release", "fail", "stopped"] {
            try FileManager.default.createDirectory(at: probe.appending(path: name), withIntermediateDirectories: true)
        }
        let ssh = f.directory.appending(path: "scan-ssh")
        try Data("""
        #!/bin/sh
        for argument; do
            case "$argument" in
                git@repo*.modu-scan.invalid) repo=${argument#git@}; repo=${repo%.modu-scan.invalid} ;;
            esac
        done
        [ -n "$repo" ] || exit 1
        trap 'rm -f "$MODU_SCAN_PROBE/active/$repo"; : > "$MODU_SCAN_PROBE/stopped/$repo"; exit 143' TERM INT
        : > "$MODU_SCAN_PROBE/active/$repo"
        : > "$MODU_SCAN_PROBE/started/$repo"
        while [ ! -e "$MODU_SCAN_PROBE/release/$repo" ]; do sleep 0.02; done
        if [ -e "$MODU_SCAN_PROBE/fail/$repo" ]; then
            status=1
        else
            /usr/bin/git-upload-pack "$MODU_SCAN_REMOTE"
            status=$?
        fi
        rm -f "$MODU_SCAN_PROBE/active/$repo"
        exit "$status"
        """.utf8).write(to: ssh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        var paths: [URL] = [], remotes: [String] = []
        for index in 0..<10 {
            let path = f.directory.appending(path: "project\(index)")
            let url = "ssh://git@repo\(index).modu-scan.invalid/repo\(index).git"
            try FileManager.default.copyItem(at: f.directory.appending(path: "source"), to: path)
            _ = try await f.service.git.run(["remote", "add", "origin", url], at: path)
            paths.append(path); remotes.append(url)
        }
        directories = paths; urls = remotes
        var runner = f.service.git.runner
        runner.environment["GIT_SSH_COMMAND"] = "'\(ssh.path)'"
        runner.environment["GIT_SSH_VARIANT"] = "ssh"
        runner.environment["GIT_ALLOW_PROTOCOL"] = "file:ssh"
        runner.environment["MODU_SCAN_PROBE"] = probe.path
        runner.environment["MODU_SCAN_REMOTE"] = f.directory.appending(path: "repo.git").path
        service = WorkspaceService(store: f.service.store, git: Git(runner: runner), trash: f.service.trashDirectory)
    }

    func started() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: probe.appending(path: "started").path))
    }
    func active() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: probe.appending(path: "active").path))
    }
    func release(_ index: Int) throws { try Data().write(to: probe.appending(path: "release/repo\(index)")) }
    func waitForStarts(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if try started().count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ModuError("test-timeout", "Expected \(count) remote checks to start; got \(try started()).")
    }
}
