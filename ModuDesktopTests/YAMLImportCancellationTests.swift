import Foundation
import Testing
@testable import ModuCore

struct YAMLImportCancellationTests {
    @Test(arguments: ["Saving…", "Added", "completed"])
    func lateCancellationAfterLastRepositoryKeepsSuccess(_ phase: String) async throws {
        let f = try await Fixture(); defer { f.remove() }
        let other = try await prepare(f)
        let (result, cancelled) = await Task {
            let result = await f.service.importRepositoryYAML("repos: [\(f.remoteURL), \(other)]", at: f.root) { value in
                if (value.target == "other" && value.phase == phase) || (phase == "completed" && value.completed == value.total) {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            return (result, Task.isCancelled)
        }.value
        #expect(cancelled)
        #expect(result.status == "success" && result.exitCode == 0)
        #expect(result.reasonCode == nil && result.message == nil)
        #expect(result.items.map(\.resource.repo) == ["repo", "other"])
        #expect(result.items.allSatisfy { $0.status == "success" && $0.reasonCode == nil && $0.data?["disposition"] == "added" })
        #expect(result.items.allSatisfy { $0.effects.contains { $0.action == "save-configuration" } && $0.effects.contains { $0.action == "commit-workspace-files" } })
        let record = try f.service.store.load(f.root)
        #expect(record.repositories.map(\.id) == ["repo", "other"])
        for repo in record.repositories { try await f.service.git.checkRepository(record.repositoryURL(repo.id), origin: repo.url, main: true) }
        let committedIgnore = try await f.service.git.run(["show", "HEAD:.gitignore"], at: f.root).text
        #expect(committedIgnore.contains("/repo/") && committedIgnore.contains("/other/"))
        #expect(try await f.service.git.changes(at: f.root).isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationWithPendingRepositoriesKeepsCompletedItems(_ beforeFirst: Bool) async throws {
        let f = try await Fixture(); defer { f.remove() }
        let other = try await prepare(f)
        let result = await Task {
            if beforeFirst { withUnsafeCurrentTask { $0?.cancel() } }
            return await f.service.importRepositoryYAML("repos: [\(f.remoteURL), \(other)]", at: f.root) { value in
                if value.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }.value
        #expect(result.status == "cancelled" && result.reasonCode == "cancelled" && result.exitCode == 130)
        #expect(result.items.count == 2)
        if beforeFirst { #expect(result.items.allSatisfy { $0.reasonCode == "not-processed" && $0.effects.isEmpty }) }
        else { #expect(result.items.first?.status == "success" && result.items.first?.data?["disposition"] == "added") }
        #expect(result.items.last?.reasonCode == "not-processed" && result.items.last?.effects.isEmpty == true)
        let record = try f.service.store.load(f.root)
        #expect(record.repositories.map(\.id) == (beforeFirst ? [] : ["repo"]))
        #expect(PathSafety.exists(record.repositoryURL("repo")) == !beforeFirst)
        #expect(!PathSafety.exists(record.repositoryURL("other")))
        let committedIgnore = try await f.service.git.run(["show", "HEAD:.gitignore"], at: f.root).text
        #expect(committedIgnore.contains("/repo/") == !beforeFirst)
        #expect(!committedIgnore.contains("/other/"))
        let lease = try f.service.store.lock(f.root); lease.unlock()
    }

    @Test(arguments: [false, true])
    func lateCancellationPreservesCompletedSkipResults(_ alreadyExists: Bool) async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == "success")
        if alreadyExists { #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == "success") }
        let (result, cancelled) = await Task {
            let result = await f.service.importRepositoryYAML("repos: [\(f.remoteURL), \(f.remoteURL)]", at: f.root) { value in
                if value.completed == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return (result, Task.isCancelled)
        }.value
        #expect(cancelled)
        #expect(result.status == (alreadyExists ? "skipped" : "partial-success") && result.exitCode == 1)
        #expect(result.reasonCode == nil)
        #expect(result.items.map(\.status) == [alreadyExists ? "skipped" : "success", "skipped"])
        #expect(result.items.map(\.reasonCode) == [alreadyExists ? "already-exists" : nil, "duplicate-url"])
        #expect(try f.service.store.load(f.root).repositories.map(\.id) == ["repo"])
    }

    @Test(arguments: [false, true])
    func lateCancellationDoesNotHideRepositoryFailures(_ completedFirst: Bool) async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == "success")
        let urls = (completedFirst ? [f.remoteURL] : []) + ["https://first.invalid/conflict.git", "https://second.invalid/conflict.git"]
        let (result, cancelled) = await Task {
            let result = await f.service.importRepositoryYAML("repos: [\(urls.joined(separator: ", "))]", at: f.root) { value in
                if value.completed == urls.count { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return (result, Task.isCancelled)
        }.value
        #expect(cancelled)
        #expect(result.status == (completedFirst ? "partial-success" : "failed") && result.exitCode == 1)
        #expect(result.reasonCode == nil)
        #expect(result.items.count == urls.count)
        let failures = result.items.filter { $0.status == "failed" }
        #expect(failures.count == 2 && failures.allSatisfy { $0.reasonCode == "repository-conflict" && $0.effects.isEmpty })
        #expect(!result.items.contains { $0.status == "cancelled" || $0.reasonCode == "not-processed" })
        #expect(try f.service.store.load(f.root).repositories.map(\.id) == (completedFirst ? ["repo"] : []))
        #expect(!PathSafety.exists(f.root.appending(path: "repositories/conflict")))
    }

    private func prepare(_ fixture: Fixture) async throws -> String {
        #expect(await fixture.service.openWorkspace(fixture.root).status == "success")
        let other = "https://modu-test.invalid/other.git"
        _ = try await fixture.service.git.run(["config", "--global", "--add", "url.\(fixture.directory.appending(path: "repo.git").path).insteadOf", other], at: fixture.root)
        return other
    }
}
