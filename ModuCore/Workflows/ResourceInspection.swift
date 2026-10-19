import Foundation

extension WorkspaceService {
    public func snapshot(_ resource: Resource, in record: WorkspaceRecord, publish: @Sendable (ResourceSnapshot) async -> Void = { _ in }) async throws -> ResourceSnapshot {
        let path = try await checked(resource, in: record)
        let origin = record.repositories.first(where: { $0.id == resource.repo })?.url
        async let changes = snapshotRead { try await git.changes(at: path) }
        async let summary = snapshotRead { try await git.summary(at: path, origin: origin) }
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
}

private func snapshotRead<Value: Sendable>(_ body: @Sendable () async throws -> Value) async -> Result<Value, ModuError> {
    do { return .success(try await body()) }
    catch { return .failure(.wrap(error)) }
}
