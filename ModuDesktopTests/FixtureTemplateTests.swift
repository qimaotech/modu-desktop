import Foundation
import Testing
@testable import ModuCore

struct FixtureTemplateTests {
    @Test(arguments: [FixtureTemplate.repositorySeed, .emptyWorkspace, .singleRepository])
    func concurrentCopiesKeepTheirFilesRecordsAndRemotesIndependent(_ template: FixtureTemplate) async throws {
        let results = await withTaskGroup(of: Result<Fixture, Error>.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { return .success(try await Fixture(template: template)) }
                    catch { return .failure(error) }
                }
            }
            var results: [Result<Fixture, Error>] = []
            for await result in group { results.append(result) }
            return results
        }
        defer { for result in results { if case let .success(fixture) = result { fixture.remove() } } }
        let first = try results[0].get(), second = try results[1].get()
        #expect(first.directory != second.directory)

        if template != .emptyWorkspace {
            let source = first.directory.appending(path: "source")
            let original = try #require(await first.service.git.oid("HEAD", at: source))
            try Data("first copy\n".utf8).write(to: source.appending(path: "README"))
            _ = try await first.service.git.run(["commit", "-am", "change first copy"], at: source)
            _ = try await first.service.git.run(["push", first.remoteURL, "HEAD:main"], at: source)
            #expect(try await second.service.git.oid("HEAD", at: second.directory.appending(path: "repo.git")) == original)
            #expect(try String(contentsOf: second.directory.appending(path: "source/README"), encoding: .utf8) == "hello\n")
            let fresh = try await Fixture(template: template); defer { fresh.remove() }
            #expect(try await fresh.service.git.oid("HEAD", at: fresh.directory.appending(path: "repo.git")) == original)
        }

        if template == .repositorySeed {
            #expect(!PathSafety.exists(first.root.appending(path: ".git")))
            #expect(!PathSafety.exists(first.service.store.recordURL(first.root)))
        } else {
            let firstRecord = try first.service.store.load(first.root)
            let secondRecord = try second.service.store.load(second.root)
            #expect(firstRecord.root == PathSafety.canonical(first.root).path)
            #expect(secondRecord.root == PathSafety.canonical(second.root).path)
            #expect(firstRecord.groups.isEmpty && secondRecord.groups.isEmpty)
            #expect(!PathSafety.exists(first.root.appending(path: ".agents")))
            #expect(firstRecord.repositories.map(\.id) == (template == .singleRepository ? ["repo"] : []))
            let original = try #require(await second.service.git.oid("HEAD", at: second.root))
            try Data("repositories/\nworktrees/\n# first copy\n".utf8).write(to: first.root.appending(path: ".gitignore"))
            _ = try await first.service.git.run(["commit", "-am", "change first workspace"], at: first.root)
            #expect(try await second.service.git.oid("HEAD", at: second.root) == original)
            #expect(try await second.service.git.run(["status", "--porcelain"], at: second.root).text.isEmpty)
            if template == .singleRepository {
                let repository = firstRecord.repositoryURL("repo"), other = secondRecord.repositoryURL("repo")
                try Data("first repository\n".utf8).write(to: repository.appending(path: "README"))
                #expect(try String(contentsOf: other.appending(path: "README"), encoding: .utf8) == "hello\n")
                #expect(try await second.service.git.run(["remote", "get-url", "origin"], at: other).text == second.directory.appending(path: "repo.git").path)
                #expect(try await second.service.git.run(["symbolic-ref", "refs/remotes/origin/HEAD"], at: other).text == "refs/remotes/origin/main")
            }
        }
    }

    @Test func cancelledCopyDoesNotInvalidateTheTemplate() async throws {
        let initial = try await Fixture(template: .singleRepository); defer { initial.remove() }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let fixture = try await Fixture(template: .singleRepository)
            fixture.remove()
        }
        do { try await cancelled.value; Issue.record("Expected fixture copying to be cancelled.") }
        catch { #expect(error is CancellationError) }
        let next = try await Fixture(template: .singleRepository); defer { next.remove() }
        #expect(try next.service.store.load(next.root).repositories.map(\.id) == ["repo"])
        #expect(try await next.service.git.run(["status", "--porcelain"], at: next.root).text.isEmpty)
    }
}
