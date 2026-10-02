import Foundation

extension Git {
    func commitWorkspaceFiles(_ paths: [String], message: String, at root: URL) async throws -> String? {
        do {
            for path in paths {
                let file = root.appending(path: path)
                if path.contains("/") { _ = try PathSafety.child((path as NSString).deletingLastPathComponent, of: root, allowMissing: false) }
                else { try PathSafety.directory(root) }
                guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else { throw ModuError("git-failed", "Workspace commit requires a regular file: \(path)") }
            }
            // Check only the managed files without waiting for a repository-wide fsmonitor refresh.
            if try await run(["-c", "core.fsmonitor=false", "ls-files", "--error-unmatch", "--"] + paths, at: root, allowFailure: true, cancellable: false).status == 0,
               try await run(["-c", "core.fsmonitor=false", "diff", "--quiet", "HEAD", "--"] + paths, at: root, allowFailure: true, cancellable: false).status == 0 { return nil }
            _ = try await run(["add", "--force", "--"] + paths, at: root, cancellable: false)
            let diff = try await run(["diff", "--cached", "--quiet", "--"] + paths, at: root, allowFailure: true, cancellable: false)
            if diff.status == 0 { return nil }
            guard diff.status == 1 else { throw ModuError("git-failed", "Could not check workspace file changes.") }
            // --only preserves unrelated staged files; hooks cannot expand this automatic commit's scope.
            _ = try await run(["-c", "core.hooksPath=/dev/null", "commit", "--only", "-m", message, "--"] + paths, at: root, cancellable: false)
            return try await run(["rev-parse", "--verify", "HEAD"], at: root, cancellable: false).text
        } catch {
            throw ModuError("workspace-commit-failed", "Could not automatically commit workspace files. Saved resources and file changes were kept; the specified files may be staged. Check your Git identity, signing configuration and repository state, then retry. \(ModuError.wrap(error).message)")
        }
    }
}
