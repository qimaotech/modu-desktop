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
                item ?? ItemResult(resources[index], status: .cancelled, error: MonoDeckError("cancelled", .operationCancelled))
            }
        }
        result.items = [workspace] + items
        result.summarize(cancelled: result.items.contains { $0.status == .cancelled })
        return result
    }

    public func inspectStates(_ record: WorkspaceRecord, including included: Set<Resource>, concurrency: Int = 2,
                              session: ResourceReadSession? = nil, revalidateConfiguration: Bool = false,
                              publish: @Sendable (ResourceState) async -> Void = { _ in }) async -> OperationResult {
        var result = OperationResult(command: "workspace.inspect", workspace: record.root)
        do { try store.checkBoundary(record.rootURL) }
        catch { return .init(command: result.command, workspace: record.root, status: .failed, error: .wrap(error)) }
        let reader = inspectionService()
        let configured = resources(record).filter(included.contains)
        let cycle = InspectionSession(service: reader, record: record)
        let items = await withTaskGroup(of: (Int, ResourceState, ItemResult).self) { group in
            var items = [ItemResult?](repeating: nil, count: configured.count)
            let limit = max(1, min(concurrency, 6))
            var next = min(limit, configured.count)
            for index in 0..<next {
                group.addTask { await reader.inspectState(configured[index], index: index, in: record, cycle: cycle, session: session, revalidateConfiguration: revalidateConfiguration) }
            }
            while let (index, state, item) = await group.next() {
                items[index] = item
                if !Task.isCancelled { await publish(state) }
                if next < configured.count, !Task.isCancelled {
                    let index = next; next += 1
                    group.addTask { await reader.inspectState(configured[index], index: index, in: record, cycle: cycle, session: session, revalidateConfiguration: revalidateConfiguration) }
                }
            }
            return items.enumerated().map { index, value in
                value ?? ItemResult(configured[index], status: .cancelled, error: MonoDeckError("cancelled", .operationCancelled))
            }
        }
        result.items = items
        result.summarize(cancelled: Task.isCancelled || items.contains { $0.status == .cancelled })
        return result
    }

    private func inspectState(_ resource: Resource, index: Int, in record: WorkspaceRecord, cycle: InspectionSession,
                              session: ResourceReadSession?, revalidateConfiguration: Bool) async -> (Int, ResourceState, ItemResult) {
        var item = ItemResult(resource)
        do {
            try checkCancellation()
            let context: ResourceReadContext
            if let session {
                context = try await session.prepareForInspection(resource, in: record, revalidateConfiguration: revalidateConfiguration) {
                    try await cycle.repository(for: resource)
                }
            } else {
                let repository = try await cycle.repository(for: resource)
                context = try await prepareResourceRead(resource, in: record, repository: repository)
            }
            guard context.isValid(in: record) else { throw MonoDeckError("resource-unavailable", .repositorySummaryIsUnavailable) }
            let dirty = try await git.hasVisibleChanges(at: context.path, visibility: .application)
            try checkCancellation()
            item.data = ["path": context.path.path, "working-tree": dirty ? "dirty" : "clean"]
            return (index, .init(resource: resource, available: true, dirty: dirty), item)
        } catch {
            fail(&item, error)
            let failure = MonoDeckError.wrap(error)
            return (index, .init(resource: resource, available: false, reason: failure.message, reasonMessage: failure.userMessage), item)
        }
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
