import Foundation
import Darwin

public struct CLIInstallation: Sendable {
    public var available: Bool
    public var message: String
}

public struct InstallationService: Sendable {
    public let support: URL
    public let runner: CommandRunner
    private let home: URL
    private let shell: String
    public init(support: URL = WorkspaceStore().support, runner: CommandRunner = .init(), home: URL? = nil, shell: String? = nil) {
        self.support = support; self.runner = runner
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        self.home = home ?? environment["MODU_TEST_HOME_DIRECTORY"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        self.shell = shell ?? environment["MODU_TEST_LOGIN_SHELL"] ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        #else
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
        self.shell = shell ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        #endif
    }
    public var executable: URL { support.appending(path: "versions/0.1.0/modu-cli") }

    public func checkCLI() async -> CLIInstallation {
        do {
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ModuError("cli-unavailable", "Install modu-cli to continue.") }
            let run = try await runner.run(executable.path, ["--version"], timeout: 10)
            guard run.status == 0 else { throw ModuError("cli-unavailable", "The managed modu-cli could not run. Reinstall and retry.") }
            let found = try await loginShell("command -v modu-cli")
            guard found.status == 0, found.text.hasPrefix("/"), PathSafety.canonical(URL(fileURLWithPath: found.text)) == PathSafety.canonical(executable) else { throw ModuError("cli-path-unavailable", "Add ~/.local/bin to your login shell’s PATH and remove any conflicting modu-cli command, then retry. The command must resolve to \(executable.path). Shell configuration is not changed by Modu.") }
            return .init(available: true, message: "Installed")
        } catch { return .init(available: false, message: ModuError.wrap(error).message) }
    }
    public func installCLI(from source: URL) async throws -> CLIInstallation {
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
        let path = try await loginShell("printf '%s' \"$PATH\"")
        for component in path.text.split(separator: ":") where component.hasPrefix("/") {
            let url = PathSafety.canonical(URL(fileURLWithPath: String(component), isDirectory: true))
            let oldLink = url.appending(path: "modu-cli")
            if PathSafety.identity(url) != PathSafety.identity(installDirectory), eligible(url), PathSafety.exists(oldLink), try canLink(oldLink) {
                try FileManager.default.removeItem(at: oldLink)
            }
        }
        return await checkCLI()
    }
    @discardableResult public func installSkill(from source: URL, workspace: URL) throws -> Bool {
        let content = try Data(contentsOf: source)
        let agents = workspace.appending(path: ".agents")
        let skills = agents.appending(path: "skills")
        for directory in [agents, skills] { try PathSafety.directory(directory, allowMissing: true) }
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let directory = skills.appending(path: "modu-workflow")
        let file = directory.appending(path: "SKILL.md")
        if PathSafety.exists(directory) {
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            if attrs[.type] as? FileAttributeType == .typeDirectory,
               (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular,
               (try? Data(contentsOf: file)) == content { return false }
            guard try canLink(directory) else { throw ModuError("skill-conflict", "The existing modu-workflow file, modified skill, or third-party link was kept.") }
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try content.write(to: file, options: .atomic)
        return true
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
        return try await runner.run(shell, ["-lc", command], timeout: 10)
    }
}
