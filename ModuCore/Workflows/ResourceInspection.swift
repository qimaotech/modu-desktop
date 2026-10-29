import Foundation

public enum InspectionPolicy: Sendable {
    case localOnly, refreshMissingBase
}

extension WorkspaceService {
    public func snapshot(_ resource: Resource, in record: WorkspaceRecord, policy: InspectionPolicy = .refreshMissingBase, publish: @Sendable (ResourceSnapshot) async -> Void = { _ in }) async throws -> ResourceSnapshot {
        let reader = inspectionService(for: policy)
        let path = try await reader.checked(resource, in: record)
        let origin = record.repositories.first(where: { $0.id == resource.repo })?.url
        let fetchMissingBase: (@Sendable () async throws -> Void)?
        switch policy {
        case .localOnly: fetchMissingBase = nil
        case .refreshMissingBase:
            fetchMissingBase = {
                let remote = try await reader.git.run(["config", "--get", "remote.origin.url"], at: path).text
                try await reader.checkRemoteBoundary(remote, at: path)
                _ = try await reader.git.run(["fetch", "--no-recurse-submodules", "origin"], at: path)
            }
        }
        async let changes = snapshotRead { try await reader.git.changes(at: path) }
        async let summary = snapshotRead {
            try await reader.git.summary(at: path, origin: origin, fetchMissingBase: fetchMissingBase)
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
        case .refreshMissingBase: return self
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
