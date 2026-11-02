import Foundation

extension WorkspaceService {
    func inspectConcurrent(_ record: WorkspaceRecord, scope: InspectionScope, excluding excluded: Resource?, content: InspectionContent, visibility: GitChangeVisibility, concurrency: Int, including included: Set<Resource>?, publish: @Sendable (ResourceSnapshot) async -> Void) async -> OperationResult {
        var result = OperationResult(command: "workspace.inspect", workspace: record.root)
        do { try store.checkBoundary(record.rootURL) }
        catch { return .init(command: "workspace.inspect", workspace: record.root, status: .failed, error: .wrap(error)) }
        let reader = inspectionService()
        var workspace = ItemResult(.workspace())
        do { try await reader.git.checkRepository(record.rootURL, main: true); workspace.data = ["root": record.root] }
        catch { fail(&workspace, error) }
        let resources = resources(record).filter { $0 != excluded && scope.includes($0) && (included?.contains($0) ?? true) }
        let session = InspectionSession(service: reader, record: record)
        let items = await withTaskGroup(of: (Int, ResourceSnapshot, ItemResult).self) { group in
            var items = [ItemResult?](repeating: nil, count: resources.count)
            var next = min(concurrency, resources.count)
            for index in 0..<next { group.addTask { await reader.inspectResource(resources[index], index: index, in: record, session: session, content: content, visibility: visibility) } }
            while let (index, snapshot, item) = await group.next() {
                items[index] = item
                if !Task.isCancelled { await publish(snapshot) }
                if next < resources.count, !Task.isCancelled {
                    let index = next; next += 1
                    group.addTask { await reader.inspectResource(resources[index], index: index, in: record, session: session, content: content, visibility: visibility) }
                }
            }
            return items.enumerated().map { index, item in
                item ?? ItemResult(resources[index], status: .cancelled, error: ModuError("cancelled", .operationCancelled))
            }
        }
        result.items = [workspace] + items
        result.summarize(cancelled: result.items.contains { $0.status == .cancelled })
        return result
    }

    private func inspectResource(_ resource: Resource, index: Int, in record: WorkspaceRecord, session: InspectionSession, content: InspectionContent, visibility: GitChangeVisibility) async -> (Int, ResourceSnapshot, ItemResult) {
        var item = ItemResult(resource)
        var snapshot = ResourceSnapshot(resource: resource)
        do {
            try checkCancellation()
            let repository = try await session.repository(for: resource)
            let context = try await prepareResourceRead(resource, in: record, repository: repository)
            snapshot = try await localSnapshot(context, content: content, visibility: visibility)
            try applyInspectionSnapshot(snapshot, content: content, to: &item, at: context.path)
        } catch {
            fail(&item, error)
            if snapshot.changes == nil { snapshot.changesError = .wrap(error) }
            if case .withSummary = content, snapshot.summary == nil { snapshot.summaryError = .wrap(error) }
        }
        return (index, snapshot, item)
    }
}

private actor InspectionSession {
    let service: WorkspaceService
    let record: WorkspaceRecord
    var repositories: [String: Task<RepositoryInspection, Error>] = [:]

    init(service: WorkspaceService, record: WorkspaceRecord) { self.service = service; self.record = record }

    func repository(for resource: Resource) async throws -> RepositoryInspection {
        try Task.checkCancellation()
        let key = resource.repo ?? ""
        let task: Task<RepositoryInspection, Error>
        if let existing = repositories[key] { task = existing }
        else {
            task = Task { try await service.checkedRepository(for: resource, in: record) }
            repositories[key] = task
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
