import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct DeletionCancellationTests {
    @Test(arguments: ["group", "repository", "edit", "member", "last"])
    func cancellationFinishesTheCurrentDeletionAndPreservesPendingResources(_ kind: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let current: Resource = kind == "last" ? .group("feature") : .member("feature", "repo")
        let repository = current.repo.map { record.repositoryURL($0) } ?? fixture.root
        let probe = try installDeletionHook(at: repository, fixture: fixture)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace.record = record
        if kind == "edit" {
            model.management.sheet = .edit
            model.management.edit("feature", members: [])
            await model.management.editPreviewTask?.value
        } else {
            let request: DeleteRequest = kind == "repository" ? .repository("repo") : kind == "member" ? .member(group: "feature", repo: "repo") : .group("feature")
            model.management.prepareDelete(request)
            await model.management.deletePreviewTask?.value
        }
        try #require(model.management.canConfirmDelete)
        model.management.confirmDelete()
        let operation = try #require(model.operation)
        do {
            try await waitFor(probe.started)
            #expect(model.busy && model.progress?.phase == .deleting && model.progress?.target == current.path)
            #expect(model.progress?.cancellable == false && model.operations.canCancel)
            model.cancel()
            #expect(model.cancelling && operation.isCancelled)
            for language in ["en", "zh"] {
                model.language = language
                #expect(model.presentation.operationProgressPhaseText == (language == "zh" ? "正在完成当前项，随后取消…" : "Finishing current item before cancellation…"))
            }
            #expect(model.busy && !PathSafety.exists(record.rootURL.appending(path: current.path)))
            #expect(try await fixture.service.git.oid("refs/heads/feature", at: repository) != nil)
            try Data().write(to: probe.release)
            await operation.value
            await model.workspace.detailPreloadTask?.value
        } catch {
            try? Data().write(to: probe.release)
            await operation.value
            await model.workspace.detailPreloadTask?.value
            throw error
        }
        #expect(!model.busy && !model.cancelling && model.management.sheet == nil)
        #expect(try await fixture.service.git.oid("refs/heads/feature", at: repository) == nil)
        #expect(!PathSafety.exists(record.memberURL("feature", "repo")))
        let saved = try fixture.service.store.load(fixture.root)
        #expect(model.workspace.record == saved && saved.repositories == record.repositories)
        #expect(PathSafety.exists(record.repositoryURL("repo")))
        #expect(PathSafety.exists(record.groupURL("feature")) == (kind != "last"))
        #expect(PathSafety.exists(record.memberURL("feature", "other")) == (kind != "last"))
        #expect((try await fixture.service.git.oid("refs/heads/feature", at: record.repositoryURL("other")) != nil) == (kind != "last"))
        if ["member", "last"].contains(kind) {
            #expect(model.presentation.result == nil)
        } else {
            let result = try #require(model.presentation.result)
            #expect(result.status == .cancelled && result.exitCode == 130)
            let completed = try #require(result.items.first { $0.resource == current })
            #expect(completed.status == .success)
            #expect(completed.effects.map(\.action) == ["remove-worktree", "remove-declaration", "delete-branch"])
            #expect(completed.effects.allSatisfy { $0.state == "applied" })
            #expect(result.items.dropFirst().allSatisfy { $0.effects.isEmpty && [.cancelled, .skipped].contains($0.status) })
        }
        if kind == "last" { #expect(saved.groups["feature"] == nil) }
        else { #expect(saved.groups["feature"]?.repositories == ["other"]) }
        let lease = try fixture.service.store.lock(fixture.root); lease.unlock()
    }

    @Test(arguments: ["group", "repository", "member"], [OperationPhase.deleting, .deleted])
    func cancellationAtTheFinalItemKeepsTheSuccessfulOutcome(_ kind: String, _ phase: OperationPhase) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let record = try await prepare(fixture)
        let resource: Resource = kind == "group" ? .group("feature") : kind == "repository" ? .repository("repo") : .member("feature", "repo")
        let request = try #require(DeleteRequest(resource))
        let (result, cancelled) = await Task {
            let result = await fixture.service.remove(request, at: fixture.root, execute: true) { progress in
                if progress.target == resource.path, progress.phase == phase { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return (result, Task.isCancelled)
        }.value
        #expect(cancelled && result.status == .success && result.exitCode == 0, "\(result.items)")
        #expect(result.items.allSatisfy { $0.status == .success && $0.effects.allSatisfy { $0.state == "applied" } })
        #expect(!PathSafety.exists(record.rootURL.appending(path: resource.path)))
        let saved = try fixture.service.store.load(fixture.root)
        if kind == "repository" {
            #expect(saved.repositories.map(\.id) == ["other"])
            let trash = try #require(result.items.last?.trashPath)
            #expect(PathSafety.exists(URL(fileURLWithPath: trash)))
        } else {
            let repository = resource.repo.map { record.repositoryURL($0) } ?? fixture.root
            #expect(try await fixture.service.git.oid("refs/heads/feature", at: repository) == nil)
            #expect(result.items.last?.effects.map(\.action) == ["remove-worktree", "remove-declaration", "delete-branch"])
        }
    }

    private func prepare(_ fixture: Fixture) async throws -> WorkspaceRecord {
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        #expect(await fixture.service.addRepository(.init(url: fixture.remoteURL), at: fixture.root).status == .success)
        let other = "https://modu-test.invalid/other.git"
        _ = try await fixture.service.git.run(["config", "--global", "--add", "url.\(fixture.directory.appending(path: "repo.git").path).insteadOf", other], at: fixture.root)
        #expect(await fixture.service.addRepository(.init(url: other), at: fixture.root).status == .success)
        #expect(await fixture.service.createGroup("feature", repositories: ["repo", "other"], at: fixture.root).status == .success)
        return try fixture.service.store.load(fixture.root)
    }

    private func installDeletionHook(at repository: URL, fixture: Fixture) throws -> (started: URL, release: URL) {
        let started = fixture.directory.appending(path: "deletion-started"), release = fixture.directory.appending(path: "deletion-release")
        let zero = String(repeating: "0", count: 40)
        let hook = repository.appending(path: ".git/hooks/reference-transaction")
        try Data("""
        #!/bin/sh
        read old new ref
        if [ "$1" = prepared ] && [ "$ref" = refs/heads/feature ] && [ "$new" = "\(zero)" ]; then
          : > "\(started.path)"
          trap 'exit 143' TERM INT
          while [ ! -e "\(release.path)" ]; do sleep 0.02; done
        fi
        """.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        return (started, release)
    }

    private func waitFor(_ path: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !PathSafety.exists(path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(PathSafety.exists(path))
    }
}
