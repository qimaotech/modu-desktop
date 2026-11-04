import Foundation

extension Git {
    func discardWorkspaceFileChanges(_ path: String, at root: URL) async throws -> Bool {
        let file = root.appending(path: path)
        _ = try PathSafety.child((path as NSString).deletingLastPathComponent, of: root)
        if PathSafety.exists(file) {
            guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
                throw MonoDeckError("unsafe-path", .workspaceChangeDiscardRequiresRegularFile(path))
            }
        }
        let literal = ":(literal)\(path)"
        let options = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
        let status = try await run(options + ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames", "--", literal], at: root, cancellable: false)
        guard let change = try Self.parseChanges(status.stdout).first else { return false }
        if let head = try await oid("HEAD", at: root, cancellable: false), change.workingTree != "?" {
            _ = try await run(options + ["restore", "--source=\(head)", "--staged", "--worktree", "--", literal], at: root, cancellable: false)
        } else {
            if change.workingTree != "?" {
                _ = try await run(options + ["rm", "--cached", "--force", "--", literal], at: root, cancellable: false)
            }
            if PathSafety.exists(file) { try FileManager.default.removeItem(at: file) }
        }
        return true
    }

    func stashWorkspaceChanges(at root: URL) async throws -> String? {
        let options = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
        let status = try await run(options + ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", ".", ":(exclude)repositories", ":(exclude)worktrees"], at: root, cancellable: false)
        guard !status.stdout.isEmpty, try await oid("HEAD", at: root, cancellable: false) != nil else { return nil }
        // Passing excluded ignored directories to stash can fail after it saves the index.
        let changes = try Self.parseChanges(status.stdout)
        let paths = Set(changes.flatMap { [$0.path] + [$0.originalPath].compactMap { $0 } }).sorted().map { ":(literal)\($0)" }
        let previous = try await oid("refs/stash", at: root, cancellable: false)
        let marker = "MonoDeck workflow skill update \(UUID().uuidString)"
        do {
            let saved = try await run(options + ["stash", "push", "--include-untracked", "--message", marker, "--"] + paths, at: root, allowFailure: true, cancellable: false)
            guard saved.status == 0, let stash = try await oid("refs/stash", at: root, cancellable: false), stash != previous else {
                throw MonoDeckError("git-failed", Self.sanitize(String(decoding: saved.stderr, as: UTF8.self)))
            }
            return stash
        } catch {
            var recovery: UserMessage = .joined([], separator: "")
            if let stash = try? await oid("refs/stash", at: root, cancellable: false), stash != previous {
                let subject = try? await run(["show", "--no-patch", "--format=%s", stash], at: root, cancellable: false).text
                if subject?.hasSuffix(marker) == true {
                    do { try await restoreWorkspaceChanges(stash, at: root); recovery = .joined([.joined([], separator: ""), .workspaceChangesWereRestored], separator: " ") }
                    catch { recovery = .joined([.joined([], separator: ""), MonoDeckError.wrap(error).userMessage], separator: " ") }
                }
            }
            throw MonoDeckError("workspace-stash-failed", .couldNotStashWorkspaceChangesBeforeUpdatingWorkflow(recovery, MonoDeckError.wrap(error).userMessage))
        }
    }

    func restoreWorkspaceChanges(_ stash: String, unstaging paths: [String] = [], at root: URL) async throws {
        let options = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
        var restored = false
        do {
            // A failed automatic commit can leave its files staged, which blocks stash --index.
            if !paths.isEmpty { _ = try await run(["restore", "--staged", "--"] + paths, at: root, cancellable: false) }
            _ = try await run(options + ["stash", "apply", "--index", stash], at: root, cancellable: false)
            restored = true
            let entries = try await run(["stash", "list", "--format=%H %gd"], at: root, cancellable: false).text.components(separatedBy: "\n")
            guard let entry = entries.first(where: { $0.hasPrefix(stash + " ") }),
                  let ref = entry.split(separator: " ").last,
                  try await oid(String(ref), at: root, cancellable: false) == stash else {
                throw MonoDeckError("git-failed", .changesWereRestoredButTemporaryStashCouldNot)
            }
            _ = try await run(["stash", "drop", String(ref)], at: root, cancellable: false)
        } catch {
            if restored {
                throw MonoDeckError("workspace-stash-restore-failed", .workspaceChangesAndIndexStateWereRestoredBut(stash, MonoDeckError.wrap(error).userMessage))
            }
            throw MonoDeckError("workspace-stash-restore-failed", .couldNotFinishRestoringWorkspaceChangesStashWas(stash, stash, MonoDeckError.wrap(error).userMessage))
        }
    }

    func commitWorkspaceFiles(_ paths: [String], message: String, at root: URL) async throws -> String? {
        do {
            for path in paths {
                let file = root.appending(path: path)
                if path.contains("/") { _ = try PathSafety.child((path as NSString).deletingLastPathComponent, of: root, allowMissing: false) }
                else { try PathSafety.directory(root) }
                guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else { throw MonoDeckError("git-failed", .workspaceCommitRequiresRegularFile(path)) }
            }
            // Check only the managed files without waiting for a repository-wide fsmonitor refresh.
            if try await run(["-c", "core.fsmonitor=false", "ls-files", "--error-unmatch", "--"] + paths, at: root, allowFailure: true, cancellable: false).status == 0,
               try await run(["-c", "core.fsmonitor=false", "diff", "--quiet", "HEAD", "--"] + paths, at: root, allowFailure: true, cancellable: false).status == 0 { return nil }
            _ = try await run(["add", "--force", "--"] + paths, at: root, cancellable: false)
            let diff = try await run(["diff", "--cached", "--quiet", "--"] + paths, at: root, allowFailure: true, cancellable: false)
            if diff.status == 0 { return nil }
            guard diff.status == 1 else { throw MonoDeckError("git-failed", .couldNotCheckWorkspaceFileChanges) }
            let commitMessage = "\(message)\n\nAuto-committed-by: MonoDeck"
            // --only preserves unrelated staged files; hooks cannot expand this automatic commit's scope.
            _ = try await run(["-c", "core.hooksPath=/dev/null", "commit", "--only", "-m", commitMessage, "--"] + paths, at: root, cancellable: false)
            return try await run(["rev-parse", "--verify", "HEAD"], at: root, cancellable: false).text
        } catch {
            throw MonoDeckError("workspace-commit-failed", .couldNotAutomaticallyCommitWorkspaceFilesSavedResources(MonoDeckError.wrap(error).userMessage))
        }
    }
}
