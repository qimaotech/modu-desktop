import Foundation

public struct WorktreeRegistration: Sendable {
    public var path: String
    public var oid = ""
    public var branch: String?
    public var locked = false
}

extension Git {
    public func registrations(at repository: URL) async throws -> [WorktreeRegistration] {
        let output = try await run(["worktree", "list", "--porcelain", "-z"], at: repository)
        var values: [WorktreeRegistration] = []
        for field in output.stdout.split(separator: 0, omittingEmptySubsequences: false).map({ String(decoding: $0, as: UTF8.self) }) {
            if field.hasPrefix("worktree ") { values.append(.init(path: String(field.dropFirst(9)))) }
            else if !values.isEmpty {
                if field.hasPrefix("HEAD ") { values[values.count - 1].oid = String(field.dropFirst(5)) }
                else if field.hasPrefix("branch refs/heads/") { values[values.count - 1].branch = String(field.dropFirst(18)) }
                else if field == "locked" || field.hasPrefix("locked ") { values[values.count - 1].locked = true }
            }
        }
        guard !values.isEmpty else { throw ModuError("git-failed", .gitReturnedNoWorktreeRegistrations) }
        return values
    }
    func checkBranchNotInUse(_ branch: String, registrations: [WorktreeRegistration], at repository: URL, excluding worktreePath: String? = nil) async throws {
        let occupied = registrations.filter { $0.path != worktreePath }.compactMap(\.branch)
        guard !occupied.isEmpty else { return }
        let common = try await run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: repository).text
        let heads = URL(fileURLWithPath: common).appending(path: "refs/heads")
        // Differently cased branch names can share one loose ref on case-insensitive volumes.
        let identity = PathSafety.identity(heads.appending(path: branch))
        guard !occupied.contains(where: { PathSafety.identity(heads.appending(path: $0)) == identity }) else {
            throw ModuError("branch-in-use", .branchIsAlreadyCheckedOut(branch))
        }
    }
    public func checkRepository(_ path: URL, origin: String? = nil, main: Bool = false) async throws {
        try PathSafety.directory(path)
        let top = try await run(["rev-parse", "--show-toplevel"], at: path).text
        guard PathSafety.identity(URL(fileURLWithPath: top)) == PathSafety.identity(path) else { throw ModuError("resource-unavailable", .notRepositoryRoot2(path.path)) }
        if main { try PathSafety.directory(path.appending(path: ".git")) }
        if let origin {
            let actual = try await run(["config", "--get", "remote.origin.url"], at: path).text
            guard actual == origin else { throw ModuError("origin-mismatch", .repositoryOriginDoesNotMatchWorkspaceRecord(path.path)) }
        }
    }
    public func validateRef(_ group: String, at root: URL) async throws {
        try PathSafety.groupName(group)
        guard try await run(["check-ref-format", "refs/heads/\(group)"], at: root, allowFailure: true).status == 0 else { throw ModuError("invalid-input", .invalidGroupBranchName(group)) }
    }
    public func oid(_ ref: String, at root: URL, cancellable: Bool = true) async throws -> String? {
        let output = try await run(["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"], at: root, allowFailure: true, cancellable: cancellable)
        return output.status == 0 ? output.text : nil
    }
    public func changes(at path: URL) async throws -> [FileChange] {
        let output = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: path)
        return try Self.parseChanges(output.stdout)
    }
    public static func parseChanges(_ data: Data) throws -> [FileChange] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var index = 0, result: [FileChange] = []
        while index < fields.count {
            let bytes = Array(fields[index]); index += 1
            guard bytes.count >= 4, bytes[2] == 32 else { throw ModuError("git-output-invalid", .invalidGitStatusRecord) }
            let x = String(UnicodeScalar(bytes[0])), y = String(UnicodeScalar(bytes[1]))
            let path = String(decoding: bytes.dropFirst(3), as: UTF8.self)
            var original: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                guard index < fields.count else { throw ModuError("git-output-invalid", .missingRenameSourcePath) }
                original = String(decoding: fields[index], as: UTF8.self); index += 1
            }
            result.append(.init(path: path, originalPath: original, index: x == "?" ? " " : x, workingTree: y))
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    public func summary(at path: URL, origin: String? = nil, refreshBase: (@Sendable (String?) async throws -> Void)? = nil) async throws -> GitSummary {
        guard let head = try await oid("HEAD", at: path) else { throw ModuError("resource-unavailable", .headDoesNotIdentifyCommit) }
        let branch = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], at: path, allowFailure: true)
        var summary = GitSummary(head: branch.status == 0 ? branch.text : "Detached at \(head.prefix(8))", headOID: head)
        do {
            try await checkRepository(path, origin: origin)
            summary.hasRemotes = !(try await run(["remote"], at: path).text.isEmpty)
            guard summary.hasRemotes else { return summary }
            var ref = try await run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: path, allowFailure: true)
            guard ref.status == 1 || (ref.status == 0 && ref.text.hasPrefix("refs/remotes/origin/")) else { throw ModuError("base-unavailable", .originHEADDoesNotIdentifyCommit) }
            if let refreshBase {
                try await refreshBase(ref.status == 0 ? ref.text : nil)
                ref = try await run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: path, allowFailure: true)
            }
            guard ref.status == 0, ref.text.hasPrefix("refs/remotes/origin/"), let oid = try await oid(ref.text, at: path) else { throw ModuError("base-unavailable", .originHEADDoesNotIdentifyCommit) }
            summary.base = String(ref.text.dropFirst(13)); summary.baseOID = oid
        } catch { let failure = ModuError.wrap(error); summary.baseError = failure.message; summary.baseMessage = failure.userMessage }
        return summary
    }
    public func commits(at path: URL, head: String, base: String, skip: Int = 0, limit: Int? = 30) async throws -> [GitCommit] {
        guard [head, base].allSatisfy({ $0.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil }) else { throw ModuError("invalid-input", .invalidCommitObjectID) }
        let count = limit.map { ["--max-count=\(max(0, $0))"] } ?? []
        let output = try await run(["log", "-z", "--format=%H%x00%s%x00%an%x00%aI"] + count + ["--skip=\(max(0, skip))", "\(base)..\(head)", "--"], at: path)
        let fields = output.stdout.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var result: [GitCommit] = []
        var index = 0
        while index + 3 < fields.count {
            result.append(.init(id: fields[index], subject: fields[index + 1], author: fields[index + 2], date: fields[index + 3])); index += 4
        }
        return result
    }
    func ignored(_ names: [String], contents: Data, cancellable: Bool = true) async throws -> [String] {
        let temp = FileManager.default.temporaryDirectory.appending(path: "modu-ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try await run(["-c", "init.templateDir=", "init", "--quiet"], at: temp, cancellable: cancellable)
        try contents.write(to: temp.appending(path: ".gitignore"))
        var missing: [String] = []
        for name in names {
            let output = try await run(["-c", "core.excludesFile=/dev/null", "check-ignore", "--no-index", "--quiet", "--", "\(name)/"], at: temp, allowFailure: true, cancellable: cancellable)
            if output.status == 1 { missing.append(name) }
            else if output.status != 0 { throw ModuError("git-failed", .couldNotCheckGitignoreRules) }
        }
        return missing
    }
    func ensureIgnore(_ names: [String], at root: URL, cancellable: Bool = true) async throws -> Bool {
        do { return try await updateIgnore(names, at: root, cancellable: cancellable) }
        catch let error as ModuError where ["cancelled", "ignore-write-failed", "ignore-unavailable"].contains(error.code) { throw error }
        catch { throw ModuError("ignore-unavailable", .couldNotCheckGitignore(ModuError.wrap(error).userMessage)) }
    }
    private func updateIgnore(_ names: [String], at root: URL, cancellable: Bool) async throws -> Bool {
        let file = root.appending(path: ".gitignore")
        if PathSafety.exists(file) {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular, FileManager.default.isReadableFile(atPath: file.path), FileManager.default.isWritableFile(atPath: file.path) else { throw ModuError("ignore-unavailable", .gitignoreMustBeReadableWritableRegularFile) }
        }
        var data = PathSafety.exists(file) ? try Data(contentsOf: file) : Data((Self.defaultWorkspaceIgnoreRules + "\n\n").utf8)
        let missing = try await ignored(names, contents: data, cancellable: cancellable)
        guard !missing.isEmpty else { return false }
        var section = Data("# modu\n".utf8)
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if let header = lines.firstIndex(where: { $0.elementsEqual("# modu".utf8) || $0.elementsEqual("# modu\r".utf8) }) {
            let start = lines[header].startIndex
            let end = lines.dropFirst(header + 1).first(where: { $0.first == 35 })?.startIndex ?? data.endIndex
            section = data.subdata(in: start..<end)
            data.removeSubrange(start..<end)
        }
        // Keep the Modu section last so later negations cannot override new rules.
        if !data.isEmpty && data.last != 10 { data.append(10) }
        data.append(section)
        if data.last != 10 { data.append(10) }
        data.append(Data(missing.map { "/\($0)/\n" }.joined().utf8))
        do { try data.write(to: file, options: .atomic) }
        catch { throw ModuError("ignore-write-failed", .couldNotUpdateGitignore(ModuError.wrap(error).userMessage)) }
        return true
    }
    func checkRootCommit(_ oid: String, members: [String], at root: URL) async throws {
        let paths = ["repositories", "worktrees"] + members
        let tracked = try await run(["ls-tree", "-r", "--name-only", "-z", oid, "--"] + paths, at: root)
        guard tracked.stdout.isEmpty else { throw ModuError("path-conflict", .groupCommitTracksReservedResourcePath) }
        let entry = try await run(["ls-tree", oid, "--", ".gitignore"], at: root).text
        guard entry.hasPrefix("100644 ") || entry.hasPrefix("100755 ") else { throw ModuError("workspace-ignore-required", .commitRegularWorkspaceGitignoreBeforeCreatingGroup) }
        let contents = try await run(["show", "\(oid):.gitignore"], at: root).stdout
        let missing = try await ignored(paths, contents: contents)
        guard missing.isEmpty else { throw ModuError("workspace-ignore-required", .commitWorkspaceGitignoreBeforeCreatingGroupMissing(missing.map { "/\($0)/" }.joined(separator: ", "))) }
    }

    private static let defaultWorkspaceIgnoreRules = """
    # Logs
    logs
    *.log
    npm-debug.log*
    yarn-debug.log*
    yarn-error.log*
    pnpm-debug.log*
    lerna-debug.log*

    node_modules
    dist
    dist-ssr
    *.local

    # Editor directories and files
    .vscode/*
    !.vscode/extensions.json
    .idea
    .DS_Store
    *.suo
    *.ntvs*
    *.njsproj
    *.sln
    *.sw?
    """
}
