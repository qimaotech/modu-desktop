import Foundation
import Testing
@testable import ModuCore

struct BranchOccupancyTests {
    @Test(arguments: ["root", "member"], [false, true])
    func creationChecksBranchCaseAliasesBeforeCreatingAnyWorktree(_ kind: String, _ packed: Bool) async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await prepare(f)
        if kind == "member" { _ = try await f.service.git.run(["branch", "-m", "workspace"], at: f.root) }
        let repository = kind == "root" ? f.root : record.repositoryURL("repo")
        if packed { _ = try await f.service.git.run(["pack-refs", "--all"], at: repository) }
        let caseSensitive = try #require(repository.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
        let rootHead = try #require(try await f.service.git.oid("HEAD", at: f.root))
        let repositoryHead = try #require(try await f.service.git.oid("HEAD", at: record.repositoryURL("repo")))
        let result = await f.service.createGroup("Main", repositories: ["repo"], at: f.root)

        if caseSensitive {
            #expect(result.status == .success, "\(result.message ?? "") \(result.items)")
            #expect(await f.service.remove(.group("Main"), at: f.root, execute: true).status == .success)
        } else {
            #expect(result.status == .failed && result.reasonCode == "branch-in-use", "\(result.message ?? "") \(result.items)")
            #expect(result.items.allSatisfy { $0.effects.isEmpty })
            #expect(!PathSafety.exists(record.groupURL("Main")))
        }
        #expect(try f.service.store.load(f.root) == record)
        #expect(try await f.service.git.oid("HEAD", at: f.root) == rootHead)
        #expect(try await f.service.git.oid("HEAD", at: record.repositoryURL("repo")) == repositoryHead)
        #expect(try await f.service.git.registrations(at: f.root).count == 1)
        #expect(try await f.service.git.registrations(at: record.repositoryURL("repo")).count == 1)
    }

    @Test(arguments: ["root", "member"], [false, true])
    func deletionProtectsBranchesCheckedOutUnderCaseAliases(_ kind: String, _ confirmed: Bool) async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await prepare(f)
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == .success)
        let record = try f.service.store.load(f.root)
        let repository = kind == "root" ? f.root : record.repositoryURL("repo")
        let worktree = kind == "root" ? record.groupURL("feature") : record.memberURL("feature", "repo")
        let caseSensitive = try #require(repository.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
        let rootHead = try #require(try await f.service.git.oid("HEAD", at: f.root))
        let repositoryHead = try #require(try await f.service.git.oid("HEAD", at: record.repositoryURL("repo")))
        if caseSensitive {
            let oid = try #require(try await f.service.git.oid("HEAD", at: worktree))
            _ = try await f.service.git.run(["update-ref", "refs/heads/Main", oid], at: repository)
        }
        if confirmed { _ = try await f.service.git.run(["switch", "--detach"], at: repository) }
        _ = try await f.service.git.run(["symbolic-ref", "HEAD", "refs/heads/Main"], at: worktree)
        var authorization: [DeletionTarget]?
        if confirmed {
            authorization = try await f.service.previewDelete(.group("feature"), at: f.root)
            _ = try await f.service.git.run(["symbolic-ref", "HEAD", "refs/heads/main"], at: repository)
        }

        if !caseSensitive {
            do {
                _ = try await f.service.previewDelete(.group("feature"), at: f.root)
                Issue.record("Expected the occupied branch to block the deletion preview.")
            } catch { #expect((error as? ModuError)?.code == "branch-in-use") }
        }
        let result = await f.service.remove(.group("feature"), at: f.root, authorization: authorization, execute: !confirmed)
        if caseSensitive {
            #expect(result.status == .success, "\(result.message ?? "") \(result.items)")
            #expect(try f.service.store.load(f.root).groups.isEmpty)
        } else {
            #expect(result.status == .failed && result.reasonCode == "branch-in-use", "\(result.message ?? "") \(result.items)")
            #expect(result.items.allSatisfy { $0.effects.isEmpty })
            #expect(try f.service.store.load(f.root) == record)
            #expect(PathSafety.exists(record.groupURL("feature")))
            #expect(PathSafety.exists(record.memberURL("feature", "repo")))
        }
        #expect(try await f.service.git.oid("refs/heads/main", at: f.root) == rootHead)
        #expect(try await f.service.git.oid("HEAD", at: f.root) == rootHead)
        #expect(try await f.service.git.oid("refs/heads/main", at: record.repositoryURL("repo")) == repositoryHead)
        #expect(try await f.service.git.oid("HEAD", at: record.repositoryURL("repo")) == repositoryHead)
    }

    private func prepare(_ f: Fixture) async throws -> WorkspaceRecord {
        #expect(await f.service.openWorkspace(f.root).status == .success)
        #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == .success)
        return try f.service.store.load(f.root)
    }
}
