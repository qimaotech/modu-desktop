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
        guard !values.isEmpty else { throw MonoDeckError("git-failed", .gitReturnedNoWorktreeRegistrations) }
        return values
    }
    func checkBranchNotInUse(_ branch: String, registrations: [WorktreeRegistration], at repository: URL, excluding worktreePath: String? = nil, commonDirectory: String? = nil) async throws {
        let occupied = registrations.filter { $0.path != worktreePath }.compactMap(\.branch)
        guard !occupied.isEmpty else { return }
        let common: String
        if let commonDirectory { common = commonDirectory }
        else { common = try await run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: repository).text }
        let heads = URL(fileURLWithPath: common).appending(path: "refs/heads")
        // Differently cased branch names can share one loose ref on case-insensitive volumes.
        let identity = PathSafety.identity(heads.appending(path: branch))
        guard !occupied.contains(where: { PathSafety.identity(heads.appending(path: $0)) == identity }) else {
            throw MonoDeckError("branch-in-use", .branchIsAlreadyCheckedOut(branch))
        }
    }
    public func checkRepository(_ path: URL, origin: String? = nil, main: Bool = false) async throws {
        try PathSafety.directory(path)
        let top = try await run(["rev-parse", "--show-toplevel"], at: path).text
        try await checkRepository(path, origin: origin, main: main, topLevel: top)
    }
    func checkRepository(_ path: URL, origin: String?, main: Bool = false, topLevel: String) async throws {
        guard PathSafety.identity(URL(fileURLWithPath: topLevel)) == PathSafety.identity(path) else { throw MonoDeckError("resource-unavailable", .notRepositoryRoot2(path.path)) }
        if main { try PathSafety.directory(path.appending(path: ".git")) }
        if let origin {
            let actual = try await run(["config", "--get", "remote.origin.url"], at: path).text
            guard actual == origin else { throw MonoDeckError("origin-mismatch", .repositoryOriginDoesNotMatchWorkspaceRecord(path.path)) }
        }
    }
    func repositoryMetadata(at path: URL, validateHEAD: Bool = false) async throws -> (topLevel: String, commonDirectory: String)? {
        try PathSafety.directory(path)
        var arguments = ["rev-parse", "--show-toplevel", "--path-format=absolute", "--git-common-dir"]
        if validateHEAD { arguments += ["--verify", "--end-of-options", "HEAD^{commit}"] }
        let output = try await run(arguments, at: path, allowFailure: true)
        guard !Task.isCancelled else { throw MonoDeckError("cancelled", .operationCancelled) }
        // Ambiguous paths or failed HEAD checks must retain the original validation and errors.
        guard output.status == 0, output.stdout.last == 10 else { return nil }
        let fields = output.stdout.dropLast().split(separator: 10, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard fields.count == (validateHEAD ? 3 : 2), fields[0].hasPrefix("/"), fields[1].hasPrefix("/") else { return nil }
        if validateHEAD, fields[2].range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) == nil { return nil }
        return (fields[0], fields[1])
    }
    public func validateRef(_ group: String, at root: URL) async throws {
        try PathSafety.groupName(group)
        guard try await run(["check-ref-format", "refs/heads/\(group)"], at: root, allowFailure: true).status == 0 else { throw MonoDeckError("invalid-input", .invalidGroupBranchName(group)) }
    }
    public func oid(_ ref: String, at root: URL, cancellable: Bool = true) async throws -> String? {
        let output = try await run(["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"], at: root, allowFailure: true, cancellable: cancellable)
        return output.status == 0 ? output.text : nil
    }
    func creationReferences(_ branch: String, at repository: URL, commonDirectory: String) async throws -> [String: String]? {
        let names = ["refs/heads/\(branch)", "refs/remotes/origin/\(branch)", "refs/remotes/origin/HEAD"]
        let output = try await run(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(symref)", "--"] + names, at: repository, allowFailure: true)
        guard output.status == 0 else { return nil }
        var references: [String: String] = [:]
        for line in output.stdout.split(separator: 10) {
            let fields = line.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count == 4 else { return nil }
            let name = fields[0]
            guard names.contains(name) else { continue }
            guard fields[2] == "commit", fields[1].range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil else { return nil }
            if name == "refs/remotes/origin/HEAD", !fields[3].hasPrefix("refs/remotes/origin/") { return nil }
            references[name] = fields[1]
        }
        // Loose refs can resolve through filesystem case aliases that ref enumeration does not match.
        let common = URL(fileURLWithPath: commonDirectory)
        guard !names.contains(where: { name in
            let path = common.appending(path: name)
            guard references[name] == nil, PathSafety.exists(path) else { return false }
            let type = (try? FileManager.default.attributesOfItem(atPath: path.path)[.type]) as? FileAttributeType
            return type != .typeDirectory
        }) else { return nil }
        return references
    }
    public func changes(at path: URL) async throws -> [FileChange] {
        try Self.parseChanges(await changeStatus(at: path))
    }
    public func workingState(at path: URL, visibility: GitChangeVisibility = .all) async throws -> GitWorkingState {
        var arguments = ["status", "--porcelain=v2", "--branch", "--no-ahead-behind", "-z", "--untracked-files=all"]
        if case .application = visibility { arguments.append("--ignore-submodules=dirty") }
        return try Self.parseWorkingState(await run(arguments, at: path).stdout, visibility: visibility)
    }
    public func hasVisibleChanges(at path: URL, visibility: GitChangeVisibility = .application) async throws -> Bool {
        let start = ContinuousClock.now
        defer { runner.diagnostics?.record("status.lightweight", duration: start.duration(to: .now)) }
        var arguments = ["status", "--porcelain=v2", "--no-ahead-behind", "-z", "--untracked-files=normal"]
        if case .application = visibility { arguments.append("--ignore-submodules=dirty") }
        return try Self.parseHasVisibleChanges(await run(arguments, at: path).stdout, visibility: visibility)
    }

    public static func parseWorkingState(_ data: Data, visibility: GitChangeVisibility = .all) throws -> GitWorkingState {
        var changes: [FileChange] = [], head: String?, branch: String?
        try readWorkingState(data, visibility: visibility, header: { field in
            let value = String(decoding: field, as: UTF8.self)
            if value.hasPrefix("# branch.oid ") {
                let oid = String(value.dropFirst(13))
                guard oid == "(initial)" || oid.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil else { throw MonoDeckError("git-output-invalid", .invalidGitStatusRecord) }
                head = oid == "(initial)" ? nil : oid
            } else if value.hasPrefix("# branch.head ") {
                let name = String(value.dropFirst(14))
                branch = name == "(detached)" ? nil : name
            }
        }, consume: { record in
            let x = record.index == 46 ? " " : String(UnicodeScalar(record.index))
            let y = record.workingTree == 46 ? " " : String(UnicodeScalar(record.workingTree))
            changes.append(.init(path: String(decoding: record.path, as: UTF8.self), originalPath: record.original.map { String(decoding: $0, as: UTF8.self) }, index: x, workingTree: y))
        })
        return .init(changes: changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, headOID: head, branch: branch)
    }

    public static func parseHasVisibleChanges(_ data: Data, visibility: GitChangeVisibility = .application) throws -> Bool {
        var dirty = false
        try readWorkingState(data, visibility: visibility, header: { _ in }, consume: { _ in dirty = true })
        return dirty
    }

    private static func readWorkingState(_ data: Data, visibility: GitChangeVisibility,
                                         header: (Data.SubSequence) throws -> Void, consume: (WorkingChangeRecord) -> Void) throws {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var index = 0
        while index < fields.count {
            let field = fields[index]; index += 1
            if field.starts(with: Data("# ".utf8)) { try header(field); continue }
            if field.starts(with: Data("? ".utf8)) {
                guard field.count > 2 else { throw MonoDeckError("git-output-invalid", .invalidGitStatusRecord) }
                consume(.init(path: field.dropFirst(2), original: nil, index: 32, workingTree: 63))
                continue
            }
            let count: Int
            switch field.first {
            case UInt8(ascii: "1"): count = 8
            case UInt8(ascii: "2"): count = 9
            case UInt8(ascii: "u"): count = 10
            default: throw MonoDeckError("git-output-invalid", .invalidGitStatusRecord)
            }
            let parts = field.split(separator: 32, maxSplits: count, omittingEmptySubsequences: false)
            guard parts.count == count + 1, parts[1].count == 2, !parts[count].isEmpty else { throw MonoDeckError("git-output-invalid", .invalidGitStatusRecord) }
            let status = Array(parts[1])
            var original: Data.SubSequence?
            if field.first == UInt8(ascii: "2") {
                guard index < fields.count else { throw MonoDeckError("git-output-invalid", .missingRenameSourcePath) }
                original = fields[index]; index += 1
            }
            if case .application = visibility, field.first != UInt8(ascii: "u") {
                let modes = parts[3...5]
                let hasGitlink = modes.contains { $0.elementsEqual("160000".utf8) }
                let hasOrdinaryFile = modes.contains { !$0.elementsEqual("160000".utf8) && !$0.elementsEqual("000000".utf8) }
                if (parts[2].first == UInt8(ascii: "S") || hasGitlink), !hasOrdinaryFile, !status.contains(UInt8(ascii: "T")) { continue }
            }
            consume(.init(path: parts[count], original: original, index: status[0], workingTree: status[1]))
        }
    }

    private struct WorkingChangeRecord {
        let path: Data.SubSequence
        let original: Data.SubSequence?
        let index: UInt8
        let workingTree: UInt8
    }
    public func submodulePaths(at path: URL) async throws -> [String] {
        let output = try await run(["-c", "core.fsmonitor=false", "ls-files", "--stage", "-z"], at: path)
        var paths = Set<String>()
        for field in output.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            guard let separator = field.firstIndex(of: 9) else { throw MonoDeckError("git-output-invalid", .invalidGitStatusRecord) }
            let metadata = field[..<separator].split(separator: 32, omittingEmptySubsequences: true)
            let name = field[field.index(after: separator)...]
            guard metadata.count == 3, !name.isEmpty else { throw MonoDeckError("git-output-invalid", .invalidGitStatusRecord) }
            if metadata[0].elementsEqual("160000".utf8), metadata[2].elementsEqual("0".utf8) {
                paths.insert(String(decoding: name, as: UTF8.self))
            }
        }
        return paths.sorted()
    }
    func changeCount(at path: URL) async throws -> Int {
        try Self.countChanges(await changeStatus(at: path))
    }
    private func changeStatus(at path: URL) async throws -> Data {
        try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: path).stdout
    }
    public static func parseChanges(_ data: Data) throws -> [FileChange] {
        var result: [FileChange] = []
        _ = try readChanges(data) { field, originalField in
            let x = String(UnicodeScalar(field[field.startIndex])), y = String(UnicodeScalar(field[field.startIndex + 1]))
            let path = String(decoding: field.dropFirst(3), as: UTF8.self)
            let original = originalField.map { String(decoding: $0, as: UTF8.self) }
            result.append(.init(path: path, originalPath: original, index: x == "?" ? " " : x, workingTree: y))
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    static func countChanges(_ data: Data) throws -> Int {
        try readChanges(data) { _, _ in }
    }
    private static func readChanges(_ data: Data, consume: (Data.SubSequence, Data.SubSequence?) -> Void) throws -> Int {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var index = 0, count = 0
        while index < fields.count {
            let field = fields[index]; index += 1
            guard field.count >= 4, field[field.startIndex + 2] == 32 else { throw MonoDeckError("git-output-invalid", .invalidGitStatusRecord) }
            let x = field[field.startIndex], y = field[field.startIndex + 1]
            var original: Data.SubSequence?
            if x == UInt8(ascii: "R") || x == UInt8(ascii: "C") || y == UInt8(ascii: "R") || y == UInt8(ascii: "C") {
                guard index < fields.count else { throw MonoDeckError("git-output-invalid", .missingRenameSourcePath) }
                original = fields[index]; index += 1
            }
            consume(field, original)
            count += 1
        }
        return count
    }
    func summary(at path: URL, workingState: GitWorkingState) async throws -> GitSummary {
        guard let head = workingState.headOID else { throw MonoDeckError("resource-unavailable", .headDoesNotIdentifyCommit) }
        var summary = GitSummary(head: workingState.head, headOID: head)
        do {
            summary.hasRemotes = !(try await run(["remote"], at: path).text.isEmpty)
            guard summary.hasRemotes else { return summary }
            let ref = try await run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], at: path, allowFailure: true)
            guard ref.status == 0, ref.text.hasPrefix("refs/remotes/origin/"), let oid = try await oid(ref.text, at: path) else { throw MonoDeckError("base-unavailable", .originHEADDoesNotIdentifyCommit) }
            summary.base = String(ref.text.dropFirst(13)); summary.baseOID = oid
        } catch { let failure = MonoDeckError.wrap(error); summary.baseError = failure.message; summary.baseMessage = failure.userMessage }
        return summary
    }
    public func commits(at path: URL, head: String, base: String, skip: Int = 0, limit: Int? = 30) async throws -> [GitCommit] {
        guard [head, base].allSatisfy({ $0.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil }) else { throw MonoDeckError("invalid-input", .invalidCommitObjectID) }
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
        guard !names.isEmpty else { return [] }
        let temp = FileManager.default.temporaryDirectory.appending(path: "mono-deck-ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try await run(["-c", "init.templateDir=", "init", "--quiet"], at: temp, cancellable: cancellable)
        try contents.write(to: temp.appending(path: ".gitignore"))
        let input = Data((names.map { "\($0)/" }.joined(separator: "\0") + "\0").utf8)
        let output = try await run(["-c", "core.excludesFile=/dev/null", "check-ignore", "--no-index", "--stdin", "-z"], at: temp, allowFailure: true, cancellable: cancellable, input: input)
        guard output.status == 0 || output.status == 1 else {
            throw MonoDeckError("git-failed", .couldNotCheckGitignoreRules)
        }
        let ignored = Set(output.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        return names.filter { !ignored.contains("\($0)/") }
    }
    func ensureIgnore(_ names: [String], at root: URL, cancellable: Bool = true) async throws -> Bool {
        do { return try await updateIgnore(names, at: root, cancellable: cancellable) }
        catch let error as MonoDeckError where ["cancelled", "ignore-write-failed", "ignore-unavailable"].contains(error.code) { throw error }
        catch { throw MonoDeckError("ignore-unavailable", .couldNotCheckGitignore(MonoDeckError.wrap(error).userMessage)) }
    }
    private func updateIgnore(_ names: [String], at root: URL, cancellable: Bool) async throws -> Bool {
        let file = root.appending(path: ".gitignore")
        if PathSafety.exists(file) {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular, FileManager.default.isReadableFile(atPath: file.path), FileManager.default.isWritableFile(atPath: file.path) else { throw MonoDeckError("ignore-unavailable", .gitignoreMustBeReadableWritableRegularFile) }
        }
        var data = PathSafety.exists(file) ? try Data(contentsOf: file) : Data((Self.defaultWorkspaceIgnoreRules + "\n\n").utf8)
        let missing = try await ignored(names, contents: data, cancellable: cancellable)
        guard !missing.isEmpty else { return false }
        var section = Data("# mono-deck\n".utf8)
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if let header = lines.firstIndex(where: { $0.elementsEqual("# mono-deck".utf8) || $0.elementsEqual("# mono-deck\r".utf8) }) {
            let start = lines[header].startIndex
            let end = lines.dropFirst(header + 1).first(where: { $0.first == 35 })?.startIndex ?? data.endIndex
            section = data.subdata(in: start..<end)
            data.removeSubrange(start..<end)
        }
        // Keep the MonoDeck section last so later negations cannot override new rules.
        if !data.isEmpty && data.last != 10 { data.append(10) }
        data.append(section)
        if data.last != 10 { data.append(10) }
        data.append(Data(missing.map { "/\($0)/\n" }.joined().utf8))
        do { try data.write(to: file, options: .atomic) }
        catch { throw MonoDeckError("ignore-write-failed", .couldNotUpdateGitignore(MonoDeckError.wrap(error).userMessage)) }
        return true
    }
    func checkRootCommit(_ oid: String, members: [String], at root: URL) async throws {
        let paths = ["repositories", "worktrees"] + members
        let tracked = try await run(["ls-tree", "-r", "--name-only", "-z", oid, "--"] + paths, at: root)
        guard tracked.stdout.isEmpty else { throw MonoDeckError("path-conflict", .groupCommitTracksReservedResourcePath) }
        let entry = try await run(["ls-tree", oid, "--", ".gitignore"], at: root).text
        guard entry.hasPrefix("100644 ") || entry.hasPrefix("100755 ") else { throw MonoDeckError("workspace-ignore-required", .commitRegularWorkspaceGitignoreBeforeCreatingGroup) }
        let contents = try await run(["show", "\(oid):.gitignore"], at: root).stdout
        let missing = try await ignored(paths, contents: contents)
        guard missing.isEmpty else { throw MonoDeckError("workspace-ignore-required", .commitWorkspaceGitignoreBeforeCreatingGroupMissing(missing.map { "/\($0)/" }.joined(separator: ", "))) }
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
