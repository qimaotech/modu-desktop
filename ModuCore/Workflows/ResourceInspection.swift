import Foundation

extension WorkspaceService {
    public func prepareResourceRead(_ resource: Resource, in record: WorkspaceRecord, visibility: GitChangeVisibility = .all) async throws -> ResourceReadContext {
        try await prepareResourceRead(resource, in: record, repository: nil, visibility: visibility)
    }

    func prepareResourceRead(_ resource: Resource, in record: WorkspaceRecord, repository inspection: RepositoryInspection?, visibility: GitChangeVisibility = .all) async throws -> ResourceReadContext {
        let reader = inspectionService()
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
        return try await inspectionService().git.workingState(at: context.path, visibility: visibility)
    }

    public func summary(_ context: ResourceReadContext, workingState: GitWorkingState) async throws -> GitSummary {
        try store.checkBoundary(context.workspace.rootURL)
        guard context.isValid(in: context.workspace) else { throw ModuError("resource-unavailable", .repositorySummaryIsUnavailable) }
        return try await inspectionService().git.summary(at: context.path, workingState: workingState)
    }

    func localSnapshot(_ context: ResourceReadContext, content: InspectionContent, visibility: GitChangeVisibility = .all) async throws -> ResourceSnapshot {
        var snapshot = ResourceSnapshot(resource: context.resource)
        do {
            let state = try await workingState(context, visibility: visibility)
            snapshot.changes = state.changes
            try checkCancellation()
            if case .withSummary = content {
                do { snapshot.summary = try await summary(context, workingState: state) }
                catch { snapshot.summaryError = .wrap(error) }
            }
        } catch {
            try checkCancellation()
            snapshot.changesError = .wrap(error)
            if case .withSummary = content { snapshot.summaryError = .wrap(error) }
        }
        try checkCancellation()
        return snapshot
    }

    func inspectionService() -> WorkspaceService {
        var reader = git
        reader.runner.environment["GIT_OPTIONAL_LOCKS"] = "0"
        return WorkspaceService(store: store, git: reader, trash: trashDirectory)
    }
}
