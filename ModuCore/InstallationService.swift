import Foundation
import Darwin
import CryptoKit

public struct CLIInstallation: Sendable {
    public var available: Bool
    public var message: String
}

public struct InstallationService: Sendable {
    public let support: URL
    public let runner: CommandRunner
    private let home: URL
    private let shell: String
    private let shellArguments: [String]
    private let directoryBoundary: URL?
    public init(support: URL = WorkspaceStore().support, runner: CommandRunner = .init(), home: URL? = nil, shell: String? = nil,
                shellArguments: [String] = ["-lic"], directoryBoundary: URL? = nil) {
        self.support = support; self.runner = runner
        self.shellArguments = shellArguments; self.directoryBoundary = directoryBoundary.map(PathSafety.canonical)
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        self.home = home ?? environment["MODU_TEST_HOME_DIRECTORY"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        self.shell = shell ?? environment["MODU_TEST_LOGIN_SHELL"] ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        #else
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
        self.shell = shell ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        #endif
    }
    public var executable: URL { support.appending(path: "versions/\(ModuVersion.current)/modu-cli") }

    public func checkCLI() async -> CLIInstallation {
        let installation = await checkCLIInstallation()
        guard installation.available else { return installation }
        return await checkCLIPath()
    }
    public func checkCLIInstallation() async -> CLIInstallation {
        do {
            try checkBoundary()
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ModuError("cli-unavailable", "Install modu-cli to continue.") }
            let link = home.appending(path: ".local/bin/modu-cli")
            guard FileManager.default.isExecutableFile(atPath: link.path), PathSafety.canonical(link) == PathSafety.canonical(executable) else {
                throw ModuError("cli-unavailable", "Reinstall modu-cli to restore ~/.local/bin/modu-cli to the managed executable.")
            }
            let run = try await runner.run(executable.path, ["--version"], timeout: 10)
            guard run.status == 0 else { throw ModuError("cli-unavailable", "The managed modu-cli could not run. Reinstall and retry.") }
            return .init(available: true, message: "Installed")
        } catch { return .init(available: false, message: ModuError.wrap(error).message) }
    }
    public func checkCLIPath() async -> CLIInstallation {
        do {
            try checkBoundary()
            let found = try await loginShell("command -v modu-cli")
            guard found.status == 0, found.text.hasPrefix("/"), PathSafety.canonical(URL(fileURLWithPath: found.text)) == PathSafety.canonical(executable) else { throw ModuError("cli-path-unavailable", "Add ~/.local/bin to your login shell’s PATH and remove any conflicting modu-cli command, then retry. The command must resolve to \(executable.path). Shell configuration is not changed by Modu.") }
            return .init(available: true, message: "Installed")
        } catch { return .init(available: false, message: ModuError.wrap(error).message) }
    }
    public func installCLI(from source: URL) async throws -> CLIInstallation {
        try checkBoundary()
        guard FileManager.default.isExecutableFile(atPath: source.path) else { throw ModuError("cli-unavailable", "The app’s bundled CLI is missing or not executable.") }
        let installDirectory = try PathSafety.child(".local/bin", of: home)
        for directory in [installDirectory.deletingLastPathComponent(), installDirectory] {
            if !PathSafety.exists(directory) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
            guard eligible(directory) else { throw ModuError("cli-install-conflict", "Check ~/.local/bin ownership and permissions. Modu requires user-owned directories without group or world write access.") }
        }
        let link = installDirectory.appending(path: "modu-cli")
        guard try canLink(link) else { throw ModuError("cli-install-conflict", "The existing non-Modu ~/.local/bin/modu-cli was kept. Move it before retrying.") }
        let directory = executable.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contentsOf: source).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if PathSafety.exists(link) { try FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        let path = try await loginShell("/usr/bin/printf '%s' \"$PATH\"")
        for component in path.text.split(separator: ":") where component.hasPrefix("/") {
            let url = PathSafety.canonical(URL(fileURLWithPath: String(component), isDirectory: true))
            if let directoryBoundary, (try? PathSafety.confined(url, to: directoryBoundary)) == nil { continue }
            let oldLink = url.appending(path: "modu-cli")
            if PathSafety.identity(url) != PathSafety.identity(installDirectory), eligible(url), PathSafety.exists(oldLink), try canLink(oldLink) {
                try FileManager.default.removeItem(at: oldLink)
            }
        }
        return await checkCLI()
    }
    @discardableResult public func installSkill(from source: URL, workspace: URL) throws -> Bool {
        let content = try Data(contentsOf: source)
        let state = try skillState(content: content, workspace: workspace)
        if state == .current { return false }
        let directory = workspace.appending(path: ".agents/skills/modu-workflow")
        if state == .managedLink { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: directory.appending(path: "SKILL.md"), options: .atomic)
        return true
    }
    func skillNeedsUpdate(from source: URL, workspace: URL) throws -> Bool {
        try skillState(content: Data(contentsOf: source), workspace: workspace) == .outdated
    }
    private enum SkillState { case missing, current, outdated, managedLink }
    private func skillState(content: Data, workspace: URL) throws -> SkillState {
        if let directoryBoundary { try PathSafety.confined(workspace, to: directoryBoundary) }
        let agents = workspace.appending(path: ".agents")
        let skills = agents.appending(path: "skills")
        for directory in [agents, skills] { try PathSafety.directory(directory, allowMissing: true) }
        let directory = skills.appending(path: "modu-workflow")
        let file = directory.appending(path: "SKILL.md")
        guard PathSafety.exists(directory) else { return .missing }
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        if attrs[.type] as? FileAttributeType == .typeDirectory,
           (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular {
            return try SHA256.hash(data: Data(contentsOf: file)) == SHA256.hash(data: content) ? .current : .outdated
        }
        guard try canLink(directory) else { throw ModuError("skill-conflict", "The existing non-directory modu-workflow, non-regular SKILL.md, or third-party link was kept.") }
        return .managedLink
    }
    private func canLink(_ url: URL) throws -> Bool {
        guard PathSafety.exists(url) else { return true }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { return false }
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        let target = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent())
        return PathSafety.canonical(target).path.hasPrefix(PathSafety.canonical(support.appending(path: "versions")).path + "/")
    }
    private func eligible(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), let permissions = attrs[.posixPermissions] as? NSNumber else { return false }
        return permissions.intValue & 0o022 == 0 && FileManager.default.isWritableFile(atPath: url.path)
    }
    private func loginShell(_ command: String) async throws -> CommandOutput {
        // Keep interactive PATH setup, but isolate the result from startup and exit output.
        let token = "modu-\(UUID().uuidString)"
        let marker = Data("\0\(token)\0".utf8)
        let delimiter = "/usr/bin/printf '\\000\(token)\\000'"
        let output = try await runner.run(shell, shellArguments + ["\(delimiter); \(command) && \(delimiter)"], timeout: 10)
        guard output.status == 0 else { return .init(status: output.status, stdout: Data(), stderr: output.stderr) }
        guard let start = output.stdout.range(of: marker),
              let end = output.stdout.range(of: marker, in: start.upperBound..<output.stdout.endIndex) else {
            throw ModuError("cli-path-unavailable", "The login shell did not return a complete result. Check its startup configuration and retry.")
        }
        return .init(status: output.status, stdout: output.stdout.subdata(in: start.upperBound..<end.lowerBound), stderr: output.stderr)
    }
    private func checkBoundary() throws {
        guard let directoryBoundary else { return }
        for path in [home, home.appending(path: ".local/bin"), support, executable] {
            try PathSafety.confined(path, to: directoryBoundary)
        }
    }
}
