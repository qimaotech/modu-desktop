import Foundation

public enum InspectionPolicy: Sendable {
    case localOnly, refreshMissingBase, refreshBase
}

extension WorkspaceService {
    public func snapshot(_ resource: Resource, in record: WorkspaceRecord, policy: InspectionPolicy = .refreshMissingBase, visibility: GitChangeVisibility = .all, publish: @Sendable (ResourceSnapshot) async -> Void = { _ in }) async throws -> ResourceSnapshot {
        let reader = inspectionService(for: policy)
        if case .localOnly = policy {
            return try await reader.localSnapshot(prepareResourceRead(resource, in: record), visibility: visibility, publish: publish)
        }
        let path = try await reader.checked(resource, in: record)
        let origin = record.repositories.first(where: { $0.id == resource.repo })?.url
        let refreshBase: @Sendable (String?) async throws -> Void = { base in
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
        async let changes = snapshotRead {
            switch visibility {
            case .all: return try await reader.git.changes(at: path)
            case .application: return try await reader.git.workingState(at: path, visibility: visibility).changes
            }
        }
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

    public func prepareResourceRead(_ resource: Resource, in record: WorkspaceRecord, visibility: GitChangeVisibility = .all) async throws -> ResourceReadContext {
        try await prepareResourceRead(resource, in: record, repository: nil, visibility: visibility)
    }

    func prepareResourceRead(_ resource: Resource, in record: WorkspaceRecord, repository inspection: RepositoryInspection?, visibility: GitChangeVisibility = .all) async throws -> ResourceReadContext {
        let reader = inspectionService(for: .localOnly)
        let repository: RepositoryInspection
        if let inspection { repository = inspection }
        else { repository = try await reader.checkedRepository(for: resource, in: record) }
        let path = try PathSafety.child(resource.path, of: record.rootURL, allowMissing: false)
        try await reader.checkWorktree(resource, at: path, repository: repository, validateHEAD: false)
        let directory = try await reader.git.run(["rev-parse", "--absolute-git-dir"], at: path).text
        let gitDirectory = URL(fileURLWithPath: directory)
        let submodulePaths: [String]
        let submoduleIndexIdentity: SubmoduleIndexIdentity?
        switch visibility {
        case .all: submodulePaths = []; submoduleIndexIdentity = nil
        case .application:
            submoduleIndexIdentity = try? SubmoduleIndexIdentity(gitDirectory.appending(path: "index"))
            do { submodulePaths = try await reader.git.submodulePaths(at: path) }
            catch let error as ModuError where error.code == "output-limit" {
                // Watch exclusions are optional; a large index must not prevent status reads.
                submodulePaths = []
            }
        }
        try reader.checkCancellation()
        return try ResourceReadContext(resource: resource, workspace: record, path: path, gitDirectory: gitDirectory, commonDirectory: URL(fileURLWithPath: repository.commonDirectory), main: repository.path, submodulePaths: submodulePaths, submoduleIndexIdentity: submoduleIndexIdentity)
    }

    public func workingState(_ context: ResourceReadContext, visibility: GitChangeVisibility = .all) async throws -> GitWorkingState {
        try store.checkBoundary(context.workspace.rootURL)
        guard context.isValid(in: context.workspace) else { throw ModuError("resource-unavailable", .repositorySummaryIsUnavailable) }
        return try await inspectionService(for: .localOnly).git.workingState(at: context.path, visibility: visibility)
    }

    public func summary(_ context: ResourceReadContext, workingState: GitWorkingState) async throws -> GitSummary {
        try store.checkBoundary(context.workspace.rootURL)
        guard context.isValid(in: context.workspace) else { throw ModuError("resource-unavailable", .repositorySummaryIsUnavailable) }
        return try await inspectionService(for: .localOnly).git.summary(at: context.path, workingState: workingState)
    }

    func localSnapshot(_ context: ResourceReadContext, visibility: GitChangeVisibility = .all, publish: @Sendable (ResourceSnapshot) async -> Void = { _ in }) async throws -> ResourceSnapshot {
        var snapshot = ResourceSnapshot(resource: context.resource)
        do {
            let state = try await workingState(context, visibility: visibility)
            snapshot.changes = state.changes
            try checkCancellation()
            await publish(snapshot)
            do { snapshot.summary = try await summary(context, workingState: state) }
            catch { snapshot.summaryError = .wrap(error) }
        } catch {
            try checkCancellation()
            snapshot.changesError = .wrap(error); snapshot.summaryError = .wrap(error)
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
