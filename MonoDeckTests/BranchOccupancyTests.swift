import Foundation
import Testing
@testable import MonoDeckCore

struct BranchOccupancyTests {
    @Test(arguments: ["root", "member"], [false, true])
    func creationChecksBranchCaseAliasesBeforeCreatingAnyWorktree(_ kind: String, _ packed: Bool) async throws {
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        let record = try f.service.store.load(f.root)
        if kind == "member" { _ = try await f.service.git.run(["branch", "-m", "workspace"], at: f.root) }
        let repository = kind == "root" ? f.root : record.repositoryURL("repo")
        if packed { _ = try await f.service.git.run(["pack-refs", "--all"], at: repository) }
        let volume = try repository.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard let caseSensitive = volume.volumeSupportsCaseSensitiveNames else {
            Issue.record("Volume case sensitivity is unavailable.")
            return
        }
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
        let f = try await Fixture(template: .singleRepository); defer { f.remove() }
        try await f.prepareGroup("feature", repositories: ["repo"])
        let record = try f.service.store.load(f.root)
        let repository = kind == "root" ? f.root : record.repositoryURL("repo")
        let worktree = kind == "root" ? record.groupURL("feature") : record.memberURL("feature", "repo")
        let volume = try repository.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard let caseSensitive = volume.volumeSupportsCaseSensitiveNames else {
            Issue.record("Volume case sensitivity is unavailable.")
            return
        }
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
            } catch { #expect((error as? MonoDeckError)?.code == "branch-in-use") }
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
}
