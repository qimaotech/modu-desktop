import Foundation

public enum InspectionPolicy: Sendable {
    case localOnly, refreshMissingBase, refreshBase
}

extension WorkspaceService {
    public func snapshot(_ resource: Resource, in record: WorkspaceRecord, policy: InspectionPolicy = .refreshMissingBase, publish: @Sendable (ResourceSnapshot) async -> Void = { _ in }) async throws -> ResourceSnapshot {
        let reader = inspectionService(for: policy)
        let path = try await reader.checked(resource, in: record)
        let origin = record.repositories.first(where: { $0.id == resource.repo })?.url
        let refreshBase: (@Sendable (String?) async throws -> Void)?
        switch policy {
        case .localOnly: refreshBase = nil
        case .refreshMissingBase, .refreshBase:
            refreshBase = { base in
                if case .refreshMissingBase = policy, base != nil { return }
                let remote = try await reader.git.run(["config", "--get", "remote.origin.url"], at: path).text
                try await reader.checkRemoteBoundary(remote, at: path)
                var arguments = ["fetch", "--no-recurse-submodules", "origin"]
                if let base {
                    let branch = base.dropFirst("refs/remotes/origin/".count)
                    arguments.append("+refs/heads/\(branch):\(base)")
                }
                _ = try await reader.git.run(arguments, at: path)
            }
        }
        async let changes = snapshotRead { try await reader.git.changes(at: path) }
        async let summary = snapshotRead {
            try await reader.git.summary(at: path, origin: origin, refreshBase: refreshBase)
        }
        var snapshot = ResourceSnapshot(resource: resource)
        switch await changes {
        case .success(let value): snapshot.changes = value
        case .failure(let error): snapshot.changesError = error
        }
        try checkCancellation()
        await publish(snapshot)
        switch await summary {
        case .success(let value): snapshot.summary = value
        case .failure(let error): snapshot.summaryError = error
        }
        try checkCancellation()
        return snapshot
    }

    func inspectionService(for policy: InspectionPolicy) -> WorkspaceService {
        switch policy {
        case .refreshMissingBase, .refreshBase: return self
        case .localOnly:
            var reader = git
            reader.runner.environment["GIT_OPTIONAL_LOCKS"] = "0"
            return WorkspaceService(store: store, git: reader, trash: trashDirectory)
        }
    }
}

private func snapshotRead<Value: Sendable>(_ body: @Sendable () async throws -> Value) async -> Result<Value, ModuError> {
    do { return .success(try await body()) }
    catch { return .failure(.wrap(error)) }
}
