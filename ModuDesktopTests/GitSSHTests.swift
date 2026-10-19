import Foundation
import Testing
@testable import ModuCore

struct GitSSHTests {
    @Test(arguments: ["global", "local", "command", "executable", "default"])
    func honorsSSHCommandPrecedenceWithoutChangingArguments(_ source: String) async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == .success)
        let probe = try SSHProbe(f, defaultSSH: source == "default")
        var runner = probe.runner
        switch source {
        case "global", "local":
            _ = try await f.service.git.run(["config", "--global", "core.sshCommand", source == "global" ? probe.command : "/usr/bin/false"], at: f.root)
            if source == "local" { _ = try await f.service.git.run(["config", "core.sshCommand", probe.command], at: f.root) }
            runner.environment["GIT_SSH"] = "/usr/bin/false"
        case "command":
            _ = try await f.service.git.run(["config", "core.sshCommand", "/usr/bin/false"], at: f.root)
            runner.environment["GIT_SSH"] = "/usr/bin/false"
            runner.environment["GIT_SSH_COMMAND"] = probe.command
        case "executable": runner.environment["GIT_SSH"] = probe.executable.path
        default: break
        }
        let output = try await Git(runner: runner).run(["ls-remote", "ssh://git@modu-ssh.invalid/repo.git", "HEAD"], at: f.root)
        #expect(output.text.hasSuffix("\tHEAD"))
        let arguments = try Data(contentsOf: probe.arguments).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        if ["global", "local", "command"].contains(source) {
            #expect(Array(arguments.prefix(2)) == ["-i", "work key's $identity"])
        }
        #expect(!arguments.contains { $0.contains("BatchMode") || $0.contains("StrictHostKeyChecking") })
        #expect(try String(contentsOf: probe.environment, encoding: .utf8) == "0\nforce\n/usr/bin/false\n")
    }

    @Test func configuredSSHSupportsRepositoryAdditionAndUpdate() async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == .success)
        let probe = try SSHProbe(f)
        let git = Git(runner: probe.runner)
        _ = try await git.run(["config", "--global", "core.sshCommand", probe.command], at: f.root)
        let service = WorkspaceService(store: f.service.store, git: git, trash: f.service.trashDirectory)
        let added = await service.addRepository(.init(url: "ssh://git@modu-ssh.invalid/repo.git"), at: f.root)
        try #require(added.status == .success, "\(added.items)")
        let repository = f.root.appending(path: "repositories/repo")
        _ = try await git.run(["config", "core.sshCommand", probe.command], at: repository)
        _ = try await git.run(["config", "--global", "core.sshCommand", "/usr/bin/false"], at: f.root)
        let source = f.directory.appending(path: "source")
        try Data("updated over configured SSH\n".utf8).write(to: source.appending(path: "README"))
        _ = try await f.service.git.run(["commit", "-am", "update fixture"], at: source)
        _ = try await f.service.git.run(["push", f.directory.appending(path: "repo.git").path, "main"], at: source)
        let updated = await service.updateRepositories(at: f.root)
        #expect(updated.status == .success, "\(updated.items)")
        #expect(updated.items.first?.data?["disposition"] == "updated")
        #expect(try String(contentsOf: repository.appending(path: "README"), encoding: .utf8) == "updated over configured SSH\n")
    }
}

private struct SSHProbe {
    let runner: CommandRunner
    let executable: URL
    let arguments: URL
    let environment: URL
    var command: String { quote(executable.path) + " -i " + quote("work key's $identity") }

    init(_ fixture: Fixture, defaultSSH: Bool = false) throws {
        let directory = fixture.directory.appending(path: "ssh tools")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        executable = directory.appending(path: "work ssh's $client")
        arguments = directory.appending(path: "arguments")
        environment = directory.appending(path: "environment")
        let transport = """
        #!/bin/sh
        for argument; do if [ "$argument" = "-G" ]; then exit 0; fi; done
        printf '%s\\0' "$@" > "$MODU_TEST_SSH_ARGUMENTS"
        printf '%s\\n' "$GIT_TERMINAL_PROMPT" "$SSH_ASKPASS_REQUIRE" "$SSH_ASKPASS" > "$MODU_TEST_SSH_ENVIRONMENT"
        exec /usr/bin/git-upload-pack "$MODU_TEST_SSH_REMOTE"

        """
        for (file, contents) in [(executable, transport), (directory.appending(path: "ssh"), defaultSSH ? transport : "#!/bin/sh\nexit 255\n")] {
            try Data(contents.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        var values = fixture.service.git.runner.environment
        for key in ["GIT_SSH", "GIT_SSH_COMMAND", "GIT_SSH_VARIANT"] { values.removeValue(forKey: key) }
        values["PATH"] = directory.path + ":/usr/bin:/bin"
        values["GIT_ALLOW_PROTOCOL"] = "file:ssh"
        values["SSH_ASKPASS_REQUIRE"] = "never"
        values["SSH_ASKPASS"] = "/usr/bin/true"
        values["MODU_TEST_SSH_REMOTE"] = fixture.directory.appending(path: "repo.git").path
        values["MODU_TEST_SSH_ARGUMENTS"] = arguments.path
        values["MODU_TEST_SSH_ENVIRONMENT"] = environment.path
        runner = CommandRunner(environment: values)
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
