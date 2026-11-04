import Foundation
import Darwin
import CryptoKit

public struct CLIInstallation: Sendable {
    public var available: Bool
    public var message: String
    public var userMessage: UserMessage? = nil
}

public struct InstallationService: Sendable {
    public let support: URL
    public let executable: URL
    public let runner: CommandRunner
    private let home: URL
    private let shell: String
    private let shellArguments: [String]
    private let directoryBoundary: URL?
    public init(support: URL = WorkspaceStore().support, executable: URL = Bundle.main.bundleURL.appending(path: "Contents/Resources/mono-deck"),
                runner: CommandRunner = .init(), home: URL? = nil, shell: String? = nil,
                shellArguments: [String] = ["-lic"], directoryBoundary: URL? = nil) {
        self.support = support; self.executable = executable; self.runner = runner
        self.shellArguments = shellArguments; self.directoryBoundary = directoryBoundary.map(PathSafety.canonical)
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        self.home = home ?? environment["MONO_DECK_TEST_HOME_DIRECTORY"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        self.shell = shell ?? environment["MONO_DECK_TEST_LOGIN_SHELL"] ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        #else
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
        self.shell = shell ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        #endif
    }
    public var commandLink: URL { home.appending(path: ".local/bin/mono-deck") }

    public func checkCLI() async -> CLIInstallation {
        let installation = await checkCLIInstallation()
        guard installation.available else { return installation }
        return await checkCLIPath()
    }
    public func checkCLIInstallation() async -> CLIInstallation {
        do {
            try checkBoundary()
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw MonoDeckError("cli-unavailable", .appSBundledCLIIsMissingOrNot) }
            guard FileManager.default.isExecutableFile(atPath: commandLink.path), PathSafety.canonical(commandLink) == PathSafety.canonical(executable) else {
                throw MonoDeckError("cli-unavailable", .reinstallMonoDeckCliLinkLocalBinMonoDeckCli)
            }
            let run = try await runner.run(executable.path, ["--version"], timeout: 10)
            guard run.status == 0 else { throw MonoDeckError("cli-unavailable", .appSBundledCLICouldNotRun) }
            return .init(available: true, message: "Installed", userMessage: .installed)
        } catch { let failure = MonoDeckError.wrap(error); return .init(available: false, message: failure.message, userMessage: failure.userMessage) }
    }
    public func checkCLIPath() async -> CLIInstallation {
        do {
            try checkBoundary()
            // A missing command still needs a complete probe, unlike a shell startup failure.
            let found = try await loginShell("command -v mono-deck || /usr/bin/true")
            guard !found.text.isEmpty else {
                throw MonoDeckError("cli-path-unavailable", .loginShellCouldNotFindMonoDeckCliAdd)
            }
            guard found.text.hasPrefix("/"), PathSafety.canonical(URL(fileURLWithPath: found.text)) == PathSafety.canonical(executable) else {
                throw MonoDeckError("cli-path-unavailable", .monoDeckCliResolvesDifferentCommandAdjustPATHOrder(found.text, executable.path))
            }
            return .init(available: true, message: "Installed", userMessage: .installed)
        } catch { let failure = MonoDeckError.wrap(error); return .init(available: false, message: failure.message, userMessage: failure.userMessage) }
    }
    public func installCLI() async throws -> CLIInstallation {
        try checkBoundary()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw MonoDeckError("cli-unavailable", .appSBundledCLIIsMissingOrNot) }
        let installDirectory = try PathSafety.child(".local/bin", of: home)
        for directory in [installDirectory.deletingLastPathComponent(), installDirectory] {
            if !PathSafety.exists(directory) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
            guard eligible(directory) else { throw MonoDeckError("cli-install-conflict", .checkLocalBinOwnershipAndPermissionsMonoDeckRequires) }
        }
        let link = installDirectory.appending(path: "mono-deck")
        guard try canLink(link, to: executable) else { throw MonoDeckError("cli-install-conflict", .existingNonMonoDeckLocalBinMonoDeckCliWas) }
        if PathSafety.exists(link) { try FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        let path = try await loginShell("/usr/bin/printf '%s' \"$PATH\"")
        for component in path.text.split(separator: ":") where component.hasPrefix("/") {
            let url = PathSafety.canonical(URL(fileURLWithPath: String(component), isDirectory: true))
            if let directoryBoundary, (try? PathSafety.confined(url, to: directoryBoundary)) == nil { continue }
            let oldLink = url.appending(path: "mono-deck")
            if PathSafety.identity(url) != PathSafety.identity(installDirectory), eligible(url), PathSafety.exists(oldLink), try canLink(oldLink, to: executable) {
                try FileManager.default.removeItem(at: oldLink)
            }
        }
        return await checkCLI()
    }
    @discardableResult public func installSkill(from source: URL, workspace: URL) throws -> Bool {
        let content = try skillContent(from: source)
        let state = try skillState(content: content, workspace: workspace)
        if state == .current { return false }
        let directory = workspace.appending(path: ".agents/skills/mono-deck-workflow")
        if state == .managedLink { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for path in content.keys.sorted() {
            let file = directory.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content[path]!.write(to: file, options: .atomic)
        }
        return true
    }
    func skillNeedsUpdate(from source: URL, workspace: URL) throws -> Bool {
        try skillState(content: skillContent(from: source), workspace: workspace) == .outdated
    }
    func skillPaths(from source: URL) -> [String] {
        let policy = "agents/openai.yaml"
        return ["SKILL.md"] + (PathSafety.exists(source.deletingLastPathComponent().appending(path: policy)) ? [policy] : [])
    }
    private func skillContent(from source: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: skillPaths(from: source).map { path in
            (path, try Data(contentsOf: path == "SKILL.md" ? source : source.deletingLastPathComponent().appending(path: path)))
        })
    }
    private enum SkillState { case missing, current, outdated, managedLink }
    private func skillState(content: [String: Data], workspace: URL) throws -> SkillState {
        if let directoryBoundary { try PathSafety.confined(workspace, to: directoryBoundary) }
        let agents = workspace.appending(path: ".agents")
        let skills = agents.appending(path: "skills")
        for directory in [agents, skills] { try PathSafety.directory(directory, allowMissing: true) }
        let directory = skills.appending(path: "mono-deck-workflow")
        guard PathSafety.exists(directory) else { return .missing }
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        if attrs[.type] as? FileAttributeType == .typeDirectory {
            var current = true
            for path in content.keys.sorted() {
                let target = directory.appending(path: path)
                if path.contains("/") { _ = try PathSafety.child((path as NSString).deletingLastPathComponent, of: directory) }
                guard PathSafety.exists(target) else { current = false; continue }
                guard try FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType == .typeRegular else {
                    throw MonoDeckError("skill-conflict", .existingNonRegularWorkflowSkillFileWasKept(target.path))
                }
                if try SHA256.hash(data: Data(contentsOf: target)) != SHA256.hash(data: content[path]!) { current = false }
            }
            return current ? .current : .outdated
        }
        guard try canLink(directory) else { throw MonoDeckError("skill-conflict", .existingNonDirectoryMonoDeckWorkflowNonRegularSKILL) }
        return .managedLink
    }
    private func canLink(_ url: URL, to executable: URL? = nil) throws -> Bool {
        guard PathSafety.exists(url) else { return true }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { return false }
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        let target = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent())
        if PathSafety.canonical(target).path.hasPrefix(PathSafety.canonical(support.appending(path: "versions")).path + "/") { return true }
        guard let executable else { return false }
        if PathSafety.canonical(target) == PathSafety.canonical(executable) { return true }
        let application = target.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard target.path == application.appending(path: "Contents/Resources/mono-deck").path else { return false }
        if PathSafety.exists(application) { return Bundle(url: application)?.bundleIdentifier == "fun.armantang.MonoDeck" }
        // A moved app leaves a dangling link without bundle metadata to check.
        return application.lastPathComponent == "MonoDeck.app"
    }
    private func eligible(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), let permissions = attrs[.posixPermissions] as? NSNumber else { return false }
        return permissions.intValue & 0o022 == 0 && FileManager.default.isWritableFile(atPath: url.path)
    }
    private func loginShell(_ command: String) async throws -> CommandOutput {
        // Keep interactive PATH setup, but isolate the result from startup and exit output.
        let token = "mono-deck-\(UUID().uuidString)"
        let marker = Data("\0\(token)\0".utf8)
        let delimiter = "/usr/bin/printf '\\000\(token)\\000'"
        let output = try await runner.run(shell, shellArguments + ["\(delimiter); \(command) && \(delimiter)"], timeout: 10)
        guard output.status == 0, let start = output.stdout.range(of: marker),
              let end = output.stdout.range(of: marker, in: start.upperBound..<output.stdout.endIndex) else {
            throw MonoDeckError("cli-path-unavailable", .loginShellCouldNotCompleteCLICheckCheck)
        }
        return .init(status: output.status, stdout: output.stdout.subdata(in: start.upperBound..<end.lowerBound), stderr: output.stderr)
    }
    private func checkBoundary() throws {
        guard let directoryBoundary else { return }
        for path in [home, home.appending(path: ".local/bin"), support] {
            try PathSafety.confined(path, to: directoryBoundary)
        }
    }
}
