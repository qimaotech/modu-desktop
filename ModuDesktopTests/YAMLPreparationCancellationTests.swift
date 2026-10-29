import Foundation
import Testing
@testable import ModuCore

struct YAMLPreparationCancellationTests {
    @Test(arguments: ["cancelled", "git-failed", "workspace-not-empty"], [false, true])
    func unpublishedPreparationKeepsTheWorkspaceAndOriginalFailure(_ failure: String, _ cleanupFails: Bool) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let other = "https://modu-test.invalid/other.git"
        _ = try await fixture.service.git.run(["config", "--global", "--add", "url.\(fixture.directory.appending(path: "repo.git").path).insteadOf", other], at: fixture.root)
        let recordURL = fixture.service.store.recordURL(fixture.root)
        let originalRecord = try Data(contentsOf: recordURL)
        let ignore = fixture.root.appending(path: ".gitignore")
        let originalIgnore = try Data(contentsOf: ignore)
        let originalHEAD = try await fixture.service.git.oid("HEAD", at: fixture.root)
        let service = WorkspaceService(store: fixture.service.store, git: fixture.service.git, trash: { path in
            if cleanupFails, path.lastPathComponent == "repo" { throw ModuError("fixture-trash-failed", "Injected preparation cleanup failure.") }
            return try fixture.service.trashDirectory(path)
        })
        let foreign = fixture.root.appending(path: "repositories/user-notes")
        let foreignData = Data("User data".utf8)
        let yaml = """
        version: 1
        repositories:
          - url: \(fixture.remoteURL)
          - url: \(other)
        groups:
          feature:
            created-at: '2026-01-01T00:00:00Z'
            repositories: [repo, other]
        """
        let outcome = await Task {
            await service.importWorkspaceYAML(yaml, at: fixture.root) { progress in
                if progress.target == "other", progress.phase == .cloning {
                    let preparedRecord = try? fixture.service.store.load(fixture.root)
                    #expect(preparedRecord?.repositories.isEmpty == true && preparedRecord?.groups.isEmpty == true)
                    #expect(!PathSafety.exists(fixture.root.appending(path: "repositories/repo")))
                    #expect(!PathSafety.exists(fixture.root.appending(path: "repositories/other")))
                    if failure == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
                    else if failure == "git-failed" { try? FileManager.default.removeItem(at: fixture.directory.appending(path: "repo.git")) }
                    else { try? foreignData.write(to: foreign) }
                }
            }
        }.value

        let cancelled = failure == "cancelled" && !cleanupFails
        #expect(outcome.status == (cancelled ? .cancelled : .failed))
        #expect(outcome.exitCode == (cancelled ? 130 : 1))
        #expect(!outcome.items.contains { $0.status == .success })
        if failure != "workspace-not-empty" {
            let interrupted = try #require(outcome.items.first { $0.resource == .repository("other") })
            #expect(interrupted.reasonCode == failure && interrupted.status == (failure == "cancelled" ? .cancelled : .failed))
        }
        #expect(try Data(contentsOf: recordURL) == originalRecord)
        #expect(try Data(contentsOf: ignore) == originalIgnore)
        #expect(try await fixture.service.git.oid("HEAD", at: fixture.root) == originalHEAD)
        let record = try fixture.service.store.load(fixture.root)
        #expect(record.repositories.isEmpty && record.groups.isEmpty)
        #expect(!PathSafety.exists(record.repositoryURL("repo")))
        #expect(!PathSafety.exists(record.repositoryURL("other")))
        #expect(!PathSafety.exists(record.groupURL("feature")))
        let remaining = try FileManager.default.contentsOfDirectory(at: fixture.root.appending(path: "repositories"), includingPropertiesForKeys: nil)
        if cleanupFails {
            let failed = try #require(outcome.items.first { $0.reasonCode == "cleanup-failed" })
            #expect(failed.resource == .repository("repo") && failed.causeCode == failure)
            #expect(outcome.reasonCode != "cancelled")
            #expect(failed.effects.contains { $0.state == "unknown" && PathSafety.exists(URL(fileURLWithPath: $0.target)) })
            #expect(!remaining.isEmpty)
        } else {
            let unpublished = try #require(outcome.items.first { $0.resource == .repository("repo") })
            #expect(unpublished.reasonCode == "not-processed" && unpublished.effects.isEmpty)
            #expect(remaining.map(PathSafety.identity) == (failure == "workspace-not-empty" ? [PathSafety.identity(foreign)] : []))
            #expect(outcome.items.allSatisfy { $0.effects.isEmpty })
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "worktrees").path).isEmpty)
        }
        if failure == "workspace-not-empty" { #expect(try Data(contentsOf: foreign) == foreignData) }
        let lease = try fixture.service.store.tryLock(fixture.root); lease.unlock()
    }
}
