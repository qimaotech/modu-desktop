import Foundation

extension WorkspaceService {
    func recoverWorkspaceRecord(_ root: URL) async throws -> WorkspaceRecord {
        let started = ContinuousClock.now
        defer { git.runner.diagnostics?.record("recovery.scan", duration: started.duration(to: .now)) }
        var record = WorkspaceRecord(root: root.path)
        let workspace = try await inspectMainRepository(root)
        let candidates = try await recoverResources(recoveryEntries("repositories", at: root), phase: "repositories") { entry -> RecoveredRepository? in
            do {
                let path = try PathSafety.child("repositories/\(entry.lastPathComponent)", of: root, allowMissing: false)
                let origin = try await git.run(["config", "--get", "remote.origin.url"], at: path).text
                let identity = try RepositoryIdentity(origin)
                let expected = try PathSafety.child("repositories/\(identity.name)", of: root, allowMissing: false)
                guard PathSafety.identity(path) == PathSafety.identity(expected) else { return nil }
                var inspection = try await inspectMainRepository(path)
                inspection.origin = origin
                try await checkWorktree(.repository(identity.name), at: path, repository: inspection)
                return .init(repository: Repository(url: origin), inspection: inspection)
            } catch { try checkCancellation(); return nil }
        }
        var identities = Set<String>()
        let repositories = candidates.compactMap { $0 }.filter { identities.insert($0.repository.id.lowercased()).inserted }
        record.repositories = repositories.map(\.repository)
        git.runner.diagnostics?.record("recovery.repositories.accepted", count: repositories.count)
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let groupCandidates = try await recoverResources(recoveryEntries("worktrees", at: root), phase: "groups") { entry -> String? in
            let name = entry.lastPathComponent
            do {
                try await git.validateRef(name, at: root)
                let path = try PathSafety.child("worktrees/\(name)", of: root, allowMissing: false)
                try await checkWorktree(.group(name), at: path, repository: workspace)
                return name
            } catch { try checkCancellation(); return nil }
        }
        let groups = groupCandidates.compactMap { $0 }
        for name in groups { record.groups[name] = WorktreeGroup(createdAt: createdAt, repositories: []) }
        git.runner.diagnostics?.record("recovery.groups.accepted", count: groups.count)
        let memberCandidates = groups.flatMap { name in
            repositories.map { RecoveryMember(group: name, repository: $0.repository.id, inspection: $0.inspection) }
        }
        let members = try await recoverResources(memberCandidates, phase: "members") { member -> RecoveryMember? in
            do {
                let resource = Resource.member(member.group, member.repository)
                let path = try PathSafety.child(resource.path, of: root, allowMissing: false)
                try await checkWorktree(resource, at: path, repository: member.inspection)
                return member
            } catch { try checkCancellation(); return nil }
        }
        let acceptedMembers = members.compactMap { $0 }
        for member in acceptedMembers { record.groups[member.group]?.repositories.append(member.repository) }
        git.runner.diagnostics?.record("recovery.members.accepted", count: acceptedMembers.count)
        try checkCancellation()
        guard !record.repositories.isEmpty || !record.groups.isEmpty else { throw MonoDeckError("workspace-not-empty", .noRecoverableWorkspaceResources) }
        try store.validate(record)
        return record
    }

    private func recoverResources<Input: Sendable, Output: Sendable>(_ inputs: [Input], phase: String,
                                                                   check: @escaping @Sendable (Input) async throws -> Output) async throws -> [Output] {
        let started = ContinuousClock.now
        defer { git.runner.diagnostics?.record("recovery.\(phase)", duration: started.duration(to: .now), count: inputs.count) }
        try checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var results = [Output?](repeating: nil, count: inputs.count)
            var next = min(4, inputs.count)
            for index in 0..<next {
                group.addTask { try checkCancellation(); return (index, try await check(inputs[index])) }
            }
            while let (index, result) = try await group.next() {
                try checkCancellation()
                results[index] = .some(result)
                if next < inputs.count {
                    let index = next; next += 1
                    group.addTask { try checkCancellation(); return (index, try await check(inputs[index])) }
                }
            }
            try checkCancellation()
            return results.map { $0! }
        }
    }

    private func recoveryEntries(_ name: String, at root: URL) throws -> [URL] {
        let directory = try PathSafety.child(name, of: root)
        guard PathSafety.exists(directory) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

private struct RecoveredRepository: Sendable {
    let repository: Repository
    let inspection: RepositoryInspection
}

private struct RecoveryMember: Sendable {
    let group: String
    let repository: String
    let inspection: RepositoryInspection
}
