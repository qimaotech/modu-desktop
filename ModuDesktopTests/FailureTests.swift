import Foundation
import Darwin
import Testing
@testable import ModuCore
@testable import ModuDesktop

struct FailureTests {
    @Test(arguments: ["remote", "clone", "checkout", "save", "save-unknown"])
    func failedRepositoryAdditionDoesNotUpdateIgnore(_ stage: String) async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == .success)
        let ignoreFile = f.root.appending(path: ".gitignore")
        let before = try Data(contentsOf: ignoreFile)
        let remote = f.directory.appending(path: "repo.git")
        var git = f.service.git
        if stage == "remote" { try FileManager.default.removeItem(at: remote) }
        if stage == "checkout" {
            let hooks = f.directory.appending(path: "hooks")
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
            let hook = hooks.appending(path: "post-checkout")
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            let index = Int(git.runner.environment["GIT_CONFIG_COUNT"] ?? "0") ?? 0
            git.runner.environment["GIT_CONFIG_COUNT"] = String(index + 1)
            git.runner.environment["GIT_CONFIG_KEY_\(index)"] = "core.hooksPath"
            git.runner.environment["GIT_CONFIG_VALUE_\(index)"] = hooks.path
        }
        let store = WorkspaceStore(support: f.service.store.support) { data, url in
            if stage == "save" { throw ModuError("configuration-write-failed", "Injected save failure.") }
            if stage == "save-unknown" {
                try Data("invalid".utf8).write(to: url)
                throw ModuError("configuration-write-failed", "Injected uncertain save.")
            }
            try data.write(to: url, options: .atomic)
        }
        let service = WorkspaceService(store: store, git: git, trash: f.service.trashDirectory)
        let result = await service.addRepository(.init(url: f.remoteURL), at: f.root) { progress in
            if stage == "clone", progress.phase == .cloning { try? FileManager.default.removeItem(at: remote) }
        }
        #expect(result.status == .failed)
        let item = try #require(result.items.first)
        #expect(item.reasonCode == (stage == "save-unknown" ? "save-outcome-unknown" : stage == "save" ? "configuration-write-failed" : "git-failed"))
        #expect(!item.effects.contains { $0.action == "update-ignore" })
        #expect(try Data(contentsOf: ignoreFile) == before)
        if stage == "save-unknown" {
            #expect(PathSafety.exists(f.root.appending(path: "repositories/repo")))
            #expect(item.effects.contains { $0.action == "clone" && $0.state == "unknown" })
        } else {
            #expect(try f.service.store.load(f.root).repositories.isEmpty)
            #expect(!PathSafety.exists(f.root.appending(path: "repositories/repo")))
        }
    }

    @Test(arguments: ["single", "batch"], [false, true])
    func cancelledRepositoryCleanupReportsItsActualOutcome(_ kind: String, _ cleanupFails: Bool) async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == .success)
        let targetURL = kind == "single" ? f.remoteURL : "https://modu-test.invalid/next.git"
        let targetName = try RepositoryIdentity(targetURL).name
        let started = f.directory.appending(path: "checkout-started"), release = f.directory.appending(path: "checkout-release")
        let hooks = f.directory.appending(path: "checkout-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
        let hook = hooks.appending(path: "post-checkout")
        try Data("""
        #!/bin/sh
        origin=$(/usr/bin/git config --get remote.origin.url)
        if [ "$origin" = "\(targetURL)" ]; then
          : > "\(started.path)"
          trap 'exit 143' TERM INT
          while [ ! -e "\(release.path)" ]; do sleep 0.02; done
        fi
        """.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        var git = f.service.git
        let configuration = [("core.hooksPath", hooks.path),
                             ("url.\(f.directory.appending(path: "repo.git").path).insteadOf", targetURL),
                             ("url.\(f.directory.appending(path: "repo.git").path).insteadOf", "https://modu-test.invalid/later.git")]
        var index = Int(git.runner.environment["GIT_CONFIG_COUNT"] ?? "0") ?? 0
        for (key, value) in configuration {
            git.runner.environment["GIT_CONFIG_KEY_\(index)"] = key
            git.runner.environment["GIT_CONFIG_VALUE_\(index)"] = value
            index += 1
        }
        git.runner.environment["GIT_CONFIG_COUNT"] = String(index)
        let service = WorkspaceService(store: f.service.store, git: git, trash: { source in
            if cleanupFails { throw ModuError("fixture-trash-failed", "Injected Trash failure.") }
            return try f.service.trashDirectory(source)
        })
        let task = Task {
            if kind == "single" { return await service.addRepository(.init(url: targetURL), at: f.root) }
            return await service.importRepositories([f.remoteURL, targetURL, "https://modu-test.invalid/later.git"], at: f.root)
        }
        defer { task.cancel(); try? Data().write(to: release) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !PathSafety.exists(started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(PathSafety.exists(started))
        task.cancel()
        let result = await task.value
        #expect(result.status.rawValue == (cleanupFails ? (kind == "single" ? "failed" : "partial-success") : "cancelled"))
        #expect(result.exitCode == (cleanupFails ? 1 : 130))
        let item = try #require(result.items.first { $0.resource.repo == targetName })
        #expect(item.status.rawValue == (cleanupFails ? "failed" : "cancelled"))
        #expect(item.reasonCode == (cleanupFails ? "cleanup-failed" : "cancelled"))
        #expect(item.causeCode == (cleanupFails ? "cancelled" : nil))
        let effect = try #require(item.effects.first { $0.action == "clone" })
        #expect(effect.state == (cleanupFails ? "unknown" : "reverted"))
        #expect(PathSafety.exists(URL(fileURLWithPath: effect.target)) == cleanupFails)
        let record = try f.service.store.load(f.root)
        #expect(record.repositories.map(\.id) == (kind == "single" ? [] : ["repo"]))
        #expect(!PathSafety.exists(record.repositoryURL(targetName)))
        #expect(try String(contentsOf: f.root.appending(path: ".gitignore"), encoding: .utf8).contains("/\(targetName)/") == false)
        if kind == "batch" {
            #expect(result.items.first?.status == .success)
            #expect(result.items.last?.reasonCode == "not-processed")
            #expect(!PathSafety.exists(record.repositoryURL("later")))
        }
        let lease = try f.service.store.lock(f.root); lease.unlock()
    }

    @Test func invalidRepositoryInputIsRejectedBeforeWorkspaceOrGitAccess() async throws {
        let f = try await Fixture(createRemote: false); defer { f.remove() }
        var runner = f.service.git.runner
        let trace = f.directory.appending(path: "invalid-input-trace")
        runner.environment["GIT_TRACE"] = trace.path
        let service = WorkspaceService(store: f.service.store, git: Git(runner: runner))
        let result = await service.addRepository(.init(url: "file:///tmp/repo.git"), at: f.root)
        #expect(result.status == .failed && result.reasonCode == "invalid-input" && result.exitCode == 2)
        #expect(result.items.isEmpty && !PathSafety.exists(trace))
        #expect(!PathSafety.exists(service.store.support) && !PathSafety.exists(f.root.appending(path: "repositories")))
    }

    @Test func repositoryIgnoreIsWrittenAfterSavingAndCompletesDespiteLateCancellation() async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == .success)
        let ignoreFile = f.root.appending(path: ".gitignore")
        let before = try Data(contentsOf: ignoreFile)
        let store = WorkspaceStore(support: f.service.store.support) { data, url in
            #expect(try Data(contentsOf: ignoreFile) == before)
            #expect(PathSafety.exists(f.root.appending(path: "repositories/repo")))
            try data.write(to: url, options: .atomic)
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let service = WorkspaceService(store: store, git: f.service.git, trash: f.service.trashDirectory)
        let result = await Task { await service.addRepository(.init(url: f.remoteURL), at: f.root) }.value
        #expect(result.status == .success)
        #expect(result.items.first?.effects.map(\.action) == ["clone", "save-configuration", "update-ignore", "commit-workspace-files"])
        #expect(try f.service.store.load(f.root).repositories.map(\.id) == ["repo"])
        #expect(try String(contentsOf: ignoreFile, encoding: .utf8).contains("/repo/\n"))
    }

    @Test func ignoreFailureKeepsSuccessfullyAddedRepositoryAndCanBeRetried() async throws {
        let f = try await Fixture(); defer { f.remove() }
        #expect(await f.service.openWorkspace(f.root).status == .success)
        let file = f.root.appending(path: ".gitignore")
        let original = f.directory.appending(path: "user-ignore")
        try FileManager.default.moveItem(at: file, to: original)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        let before = try Data(contentsOf: original)
        let result = await f.service.addRepository(.init(url: f.remoteURL), at: f.root)
        #expect(result.status == .failed)
        let item = try #require(result.items.first)
        #expect(item.reasonCode == "ignore-unavailable" && item.data?["disposition"] == "added")
        #expect(item.effects.map(\.action) == ["clone", "save-configuration"])
        #expect(try f.service.store.load(f.root).repositories.map(\.id) == ["repo"])
        #expect(PathSafety.exists(f.root.appending(path: "repositories/repo")))
        #expect(try Data(contentsOf: original) == before)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: original, to: file)
        let retried = await f.service.addRepository(.init(url: f.remoteURL), at: f.root)
        #expect(retried.status == .success && retried.items.first?.data?["disposition"] == "already-exists")
        #expect(retried.items.first?.effects.map(\.action) == ["update-ignore", "commit-workspace-files"])
    }

    @Test @MainActor func claudeRequiresDesktopAndOpensItsCodeSessionWithTheCurrentDirectory() async throws {
        let root = TestEnvironment.temporaryDirectory.appending(path: "modu-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "项目 #&+%?' folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let claude = try #require(ExternalTool.builtIn.first { $0.id == "claude" })
        let desktopID = "com.anthropic.claudefordesktop"
        let desktop = root.appending(path: "Claude.app")
        var applications = ["com.anthropic.claude-code-url-handler": root.appending(path: "CLI.app")]
        var launches: [(URL, URL)] = []
        let tools = ExternalTools(applicationURL: { applications[$0] }, openURL: { launches.append(($0, $1)) })

        #expect(await tools.available().contains { $0.id == "claude" } == false)
        do { try await tools.open(claude, directory: directory); Issue.record("Expected a missing desktop app to be rejected.") }
        catch { #expect((error as? ModuError)?.code == "tool-unavailable") }
        #expect(launches.isEmpty)

        applications[desktopID] = desktop
        #expect(await tools.available().map(\.id) == ["claude"])
        try await tools.open(claude, directory: directory)
        let launched = try #require(launches.first)
        #expect(launched.1 == desktop)
        let link = try #require(URLComponents(url: launched.0, resolvingAgainstBaseURL: false))
        #expect(link.scheme == "claude" && link.host == "code" && link.path == "/new")
        #expect(link.queryItems == [URLQueryItem(name: "folder", value: directory.path)])
        #expect(link.percentEncodedQuery?.contains("%2B") == true)
        #expect(link.fragment == nil)

        applications[desktopID] = nil
        do { try await tools.open(claude, directory: directory); Issue.record("Expected installation to be rechecked before launch.") }
        catch { #expect((error as? ModuError)?.code == "tool-unavailable") }
        #expect(launches.count == 1)
    }

    @Test func cliInstallationUsesLocalBinAndMigratesOnlyManagedLinks() async throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "modu-install-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appending(path: ".local/bin"), support = directory.appending(path: "support")
        let shims = directory.appending(path: ".asdf/shims"), legacy = directory.appending(path: ".vite-plus/bin")
        let other = directory.appending(path: "other-bin")
        for path in [shims, legacy, other] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let source = directory.appending(path: "source-cli"), shell = directory.appending(path: "login-shell")
        try Data("#!/bin/sh\nprintf '\(ModuVersion.current)\\n'\n".utf8).write(to: source)
        try Data("#!/bin/sh\nPATH=\"$MODU_FAKE_PATH\"\nexec /bin/sh -c \"$2\"\n".utf8).write(to: shell)
        for executable in [source, shell] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path) }
        var environment = ProcessInfo.processInfo.environment
        environment["MODU_FAKE_PATH"] = [shims, legacy, other, bin, shims].map(\.path).joined(separator: ":")
        let installer = InstallationService(support: support, executable: source, runner: .init(environment: environment), home: directory, shell: shell.path)
        let previousExecutable = support.appending(path: "versions/previous/modu-cli")
        try FileManager.default.createDirectory(at: previousExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("previous CLI".utf8).write(to: previousExecutable)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appending(path: "modu-cli"), withDestinationURL: previousExecutable)
        let oldLink = shims.appending(path: "modu-cli"), legacyLink = legacy.appending(path: "modu-cli")
        try FileManager.default.createSymbolicLink(at: oldLink, withDestinationURL: installer.executable)
        try FileManager.default.createSymbolicLink(at: legacyLink, withDestinationURL: support.appending(path: "versions/0.0.1/modu-cli"))
        #expect(await installer.checkCLI().available == false)
        #expect(try await installer.installCLI().available)
        #expect(!PathSafety.exists(support.appending(path: "versions/\(ModuVersion.current)")))
        #expect(try String(contentsOf: previousExecutable, encoding: .utf8) == "previous CLI")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin.appending(path: "modu-cli").path) == installer.executable.path)
        #expect(!PathSafety.exists(oldLink) && !PathSafety.exists(legacyLink))
        #expect(!PathSafety.exists(other.appending(path: "modu-cli")))
        #expect(await installer.checkCLI().available)
        let thirdParty = directory.appending(path: "third-party-cli")
        try FileManager.default.copyItem(at: source, to: thirdParty)
        try FileManager.default.createSymbolicLink(at: oldLink, withDestinationURL: thirdParty)
        let conflictingPATH = try await installer.installCLI()
        #expect(!conflictingPATH.available && conflictingPATH.message.contains("different command"))
        #expect(conflictingPATH.message.contains(oldLink.path) && conflictingPATH.message.contains(source.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: oldLink.path) == thirdParty.path)
        try FileManager.default.removeItem(at: oldLink)
        try Data("third-party".utf8).write(to: oldLink)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldLink.path)
        #expect(try await installer.installCLI().available == false)
        #expect(try String(contentsOf: oldLink, encoding: .utf8) == "third-party")
        try FileManager.default.removeItem(at: oldLink)
        environment["MODU_FAKE_PATH"] = other.path
        let missingPATH = try await InstallationService(support: support, executable: source, runner: .init(environment: environment), home: directory, shell: shell.path).installCLI()
        #expect(!missingPATH.available && missingPATH.message.contains("~/.local/bin"))
        #expect(missingPATH.message.contains("could not find modu-cli") && !missingPATH.message.contains("conflict"))
        let missingMessage = await InterfaceText(locale: .simplifiedChinese).message(try #require(missingPATH.userMessage))
        #expect(missingMessage.contains("PATH") && !missingMessage.contains("冲突"))
        #expect(PathSafety.exists(bin.appending(path: "modu-cli")))
        #expect(!PathSafety.exists(other.appending(path: "modu-cli")))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installer.executable.path)
        #expect(await installer.checkCLI().available == false)
    }

    @Test func cliLinkFollowsAppReplacementAndRollbackWithoutReinstallation() async throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "modu-cli-update-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let application = directory.appending(path: "Modu.app"), replacement = directory.appending(path: "replacement.app")
        for (app, version) in [(application, "1.0.0"), (replacement, "2.0.0")] {
            let executable = app.appending(path: "Contents/Resources/modu-cli")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nprintf '\(version)\\n'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let shell = directory.appending(path: "login-shell")
        try Data("#!/bin/sh\nexec /bin/sh -c \"$2\"\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.appending(path: ".local/bin").path + ":/usr/bin:/bin"
        let installer = InstallationService(support: directory.appending(path: "support"), executable: application.appending(path: "Contents/Resources/modu-cli"),
                                            runner: .init(environment: environment), home: directory, shell: shell.path)
        #expect(try await installer.installCLI().available)
        #expect(try await installer.runner.run(installer.commandLink.path, ["--version"]).text == "1.0.0")
        let backup = directory.appending(path: "backup.app")
        try FileManager.default.moveItem(at: application, to: backup)
        try FileManager.default.moveItem(at: replacement, to: application)
        #expect(await installer.checkCLI().available)
        #expect(try await installer.runner.run(installer.commandLink.path, ["--version"]).text == "2.0.0")
        try FileManager.default.moveItem(at: application, to: replacement)
        try FileManager.default.moveItem(at: backup, to: application)
        #expect(await installer.checkCLI().available)
        #expect(try await installer.runner.run(installer.commandLink.path, ["--version"]).text == "1.0.0")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: installer.commandLink.path) == installer.executable.path)
        #expect(!PathSafety.exists(installer.support))
    }

    @Test(arguments: ["existing", "missing", "renamed"])
    func cliInstallationRepairsLinksToPreviousAppLocations(_ kind: String) async throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "modu-cli-move-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousApp = directory.appending(path: kind == "renamed" ? "Previous Modu.app" : "previous/Modu.app")
        let executable = directory.appending(path: "current/Modu.app/Contents/Resources/modu-cli")
        let previousExecutable = previousApp.appending(path: "Contents/Resources/modu-cli")
        for file in [executable, previousExecutable] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "fun.armantang.ModuDesktop"], format: .xml, options: 0)
        try info.write(to: previousApp.appending(path: "Contents/Info.plist"))
        let shell = directory.appending(path: "login-shell")
        try Data("#!/bin/sh\nexec /bin/sh -c \"$2\"\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.appending(path: ".local/bin").path + ":/usr/bin:/bin"
        let installer = InstallationService(support: directory.appending(path: "support"), executable: executable,
                                            runner: .init(environment: environment), home: directory, shell: shell.path)
        try FileManager.default.createDirectory(at: installer.commandLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: installer.commandLink, withDestinationURL: previousExecutable)
        if kind == "missing" { try FileManager.default.removeItem(at: previousApp) }
        #expect(!(await installer.checkCLI().available))
        #expect(try await installer.installCLI().available)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: installer.commandLink.path) == executable.path)
        #expect(!PathSafety.exists(installer.support))
        #expect(PathSafety.exists(previousExecutable) == (kind != "missing"))
    }

    @Test(arguments: [("quiet", false), ("stdout", false), ("multiline", false), ("stderr", false), ("exit", false), ("exit", true), ("missing", false), ("alias", true)])
    func cliInstallationReadsInteractiveLoginPATH(_ output: String, _ conflictingCommand: Bool) async throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "modu-login-shell-tests-\(UUID().uuidString) with 'quotes' and $signs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appending(path: ".local/bin")
        let other = directory.appending(path: "other-bin")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let source = directory.appending(path: "source-cli")
        try Data("#!/bin/sh\nprintf '\(ModuVersion.current)\\n'\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let support = directory.appending(path: "support")
        let oldLink = other.appending(path: "modu-cli")
        if conflictingCommand { try FileManager.default.copyItem(at: source, to: oldLink) }
        else { try FileManager.default.createSymbolicLink(at: oldLink, withDestinationURL: support.appending(path: "versions/\(ModuVersion.current)/modu-cli")) }
        let noise: String
        switch output {
        case "stdout": noise = "printf 'Welcome without a newline'\n"
        case "multiline": noise = "printf 'Welcome\\n/unrelated/path:another/path\\n'\n"
        case "stderr": noise = "printf 'Shell diagnostic\\n' >&2\n"
        case "exit": noise = "printf 'Welcome\\n'\ntrap 'printf \"\\nGoodbye\\n/unrelated/modu-cli\\n\"' EXIT\n"
        case "alias": noise = "alias modu-cli='/usr/bin/true'\n"
        default: noise = ""
        }
        try Data(("export PATH=\"$MODU_LOGIN_PATH\"\n" + noise).utf8).write(to: directory.appending(path: ".zshrc"))
        var environment = ProcessInfo.processInfo.environment
        environment["ZDOTDIR"] = directory.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["MODU_LOGIN_PATH"] = ([other.path] + (output == "missing" ? [] : [bin.path]) + [environment["PATH"]!]).joined(separator: ":")
        let runner = CommandRunner(environment: environment)
        let noninteractive = try await runner.run("/bin/zsh", ["-lc", "command -v modu-cli"], timeout: 10)
        #expect(noninteractive.status != 0)
        let installer = InstallationService(support: support, executable: source, runner: runner, home: directory, shell: "/bin/zsh")
        let installed = try await installer.installCLI()
        let available = !conflictingCommand && output != "missing"
        #expect(installed.available == available, "\(installed.message)")
        #expect(await installer.checkCLI().available == available)
        if output == "missing" {
            #expect(installed.message.contains("could not find modu-cli") && !installed.message.contains("conflict"))
        } else if conflictingCommand {
            let resolved = output == "alias" ? "/usr/bin/true" : oldLink.path
            #expect(installed.message.contains(resolved) && installed.message.contains(source.path))
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin.appending(path: "modu-cli").path) == installer.executable.path)
        if conflictingCommand { #expect(try Data(contentsOf: oldLink) == Data(contentsOf: source)) }
        else { #expect(!PathSafety.exists(oldLink)) }
    }

    @Test(arguments: ["output", "failed-startup", "failed-exit"])
    func loginShellStartupOutputCannotReplaceTheCLIProbe(_ kind: String) async throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "modu-shell-probe-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appending(path: "login-shell")
        var environment = ProcessInfo.processInfo.environment
        let support = directory.appending(path: "support")
        let executable = directory.appending(path: "Modu.app/Contents/Resources/modu-cli")
        environment["MODU_FAKE_RESOLVED"] = executable.path
        environment["PATH"] = "/usr/bin:/bin"
        let installer = InstallationService(support: support, executable: executable, runner: .init(environment: environment), home: directory, shell: shell.path)
        let link = directory.appending(path: ".local/bin/modu-cli")
        try FileManager.default.createDirectory(at: installer.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: installer.executable)
        let script = kind == "failed-exit" ? "/bin/sh -c \"$2\"\nexit 7\n" : "printf '%s\\n' \"$MODU_FAKE_RESOLVED\"\nexit \(kind == "failed-startup" ? 7 : 0)\n"
        try Data(("#!/bin/sh\n" + script).utf8).write(to: shell)
        for file in [installer.executable, shell] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: installer.executable)
        #expect(await installer.checkCLIInstallation().available)
        let check = await installer.checkCLIPath()
        #expect(!check.available && check.userMessage == .loginShellCouldNotCompleteCLICheckCheck)
    }

    @Test(arguments: ["file", "link", "app-link", "unsafe-parent", "unsafe-bin", "parent-link", "bin-link"])
    func cliInstallationRejectsConflictsAndUnsafeDirectories(_ kind: String) async throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "modu-install-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appending(path: ".local"), bin = local.appending(path: "bin")
        let shims = directory.appending(path: ".asdf/shims"), source = directory.appending(path: "source-cli")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let installer = InstallationService(support: directory.appending(path: "support"), executable: source, home: directory)
        let oldLink = shims.appending(path: "modu-cli"), link = bin.appending(path: "modu-cli")
        try FileManager.default.createSymbolicLink(at: oldLink, withDestinationURL: installer.executable)
        switch kind {
        case "file": try Data("third-party".utf8).write(to: link)
        case "link": try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appending(path: "third-party-cli"))
        case "app-link":
            let other = directory.appending(path: "Other.app/Contents/Resources/modu-cli")
            try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: other)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        case "unsafe-parent", "unsafe-bin":
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: (kind == "unsafe-parent" ? local : bin).path)
        default:
            let target = directory.appending(path: "user-directory")
            let replaced = kind == "parent-link" ? local : bin
            try FileManager.default.moveItem(at: replaced, to: target)
            try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: target)
        }
        do { _ = try await installer.installCLI(); Issue.record("Expected the unsafe installation to be rejected.") }
        catch { #expect(["cli-install-conflict", "unsafe-path"].contains((error as? ModuError)?.code ?? "")) }
        #expect(try String(contentsOf: source, encoding: .utf8) == "#!/bin/sh\nexit 0\n")
        #expect(!PathSafety.exists(installer.support))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: oldLink.path) == installer.executable.path)
        if kind == "file" { #expect(try String(contentsOf: link, encoding: .utf8) == "third-party") }
        if kind == "link" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == directory.appending(path: "third-party-cli").path) }
        if kind == "app-link" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == directory.appending(path: "Other.app/Contents/Resources/modu-cli").path) }
        if kind == "parent-link" || kind == "bin-link" { #expect(!PathSafety.exists(link)) }
    }
    @Test(arguments: ["copy", "link", "dangling-link"])
    func skillInstallationCopiesFilesAndMigratesManagedLinks(_ kind: String) throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "modu-skill-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "workspace"), support = directory.appending(path: "support")
        let skill = root.appending(path: ".agents/skills/modu-workflow")
        let source = directory.appending(path: "SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("managed".utf8).write(to: source)
        let policy = source.deletingLastPathComponent().appending(path: "agents/openai.yaml")
        try FileManager.default.createDirectory(at: policy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to: policy)
        if kind != "copy" {
            let legacySkill = support.appending(path: "versions/0.1.0/modu-workflow")
            if kind == "link" {
                try FileManager.default.createDirectory(at: legacySkill, withIntermediateDirectories: true)
                try Data("old skill".utf8).write(to: legacySkill.appending(path: "SKILL.md"))
            }
            try FileManager.default.createSymbolicLink(at: skill, withDestinationURL: legacySkill)
        }
        let installer = InstallationService(support: support)
        try installer.installSkill(from: source, workspace: root)
        #expect(try FileManager.default.attributesOfItem(atPath: skill.path)[.type] as? FileAttributeType == .typeDirectory)
        #expect(try FileManager.default.attributesOfItem(atPath: skill.appending(path: "SKILL.md").path)[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: skill.appending(path: "agents/openai.yaml")) == Data(contentsOf: policy))
        let extra = skill.appending(path: "notes.txt")
        try Data("keep me".utf8).write(to: extra)
        #expect(try !installer.installSkill(from: source, workspace: root))
        try Data("updated".utf8).write(to: source)
        #expect(try installer.skillNeedsUpdate(from: source, workspace: root))
        #expect(try installer.installSkill(from: source, workspace: root))
        #expect(try !installer.skillNeedsUpdate(from: source, workspace: root))
        try Data("policy:\n  allow_implicit_invocation: true\n".utf8).write(to: policy)
        #expect(try installer.skillNeedsUpdate(from: source, workspace: root))
        #expect(try installer.installSkill(from: source, workspace: root))
        #expect(try Data(contentsOf: skill.appending(path: "agents/openai.yaml")) == Data(contentsOf: policy))
        #expect(try !installer.installSkill(from: source, workspace: root))
        if PathSafety.exists(support) { try FileManager.default.removeItem(at: support) }
        try FileManager.default.removeItem(at: source)
        #expect(try String(contentsOf: skill.appending(path: "SKILL.md"), encoding: .utf8) == "updated")
        #expect(try String(contentsOf: extra, encoding: .utf8) == "keep me")
    }
    @Test(arguments: ["file", "link", "file-link", "policy-link", "agents-link"])
    func skillConflictDoesNotOverwriteWorkspaceFile(_ kind: String) throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "modu-skill-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "workspace"), skills = root.appending(path: ".agents/skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let source = directory.appending(path: "SKILL.md")
        try Data("managed".utf8).write(to: source)
        let policy = directory.appending(path: "agents/openai.yaml")
        try FileManager.default.createDirectory(at: policy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("managed policy".utf8).write(to: policy)
        let existing = skills.appending(path: "modu-workflow")
        let userFile: URL
        switch kind {
        case "policy-link", "agents-link":
            let target = directory.appending(path: "user-agents")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            userFile = target.appending(path: "openai.yaml")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
            try Data("old skill".utf8).write(to: existing.appending(path: "SKILL.md"))
            let agents = existing.appending(path: "agents")
            if kind == "agents-link" { try FileManager.default.createSymbolicLink(at: agents, withDestinationURL: target) }
            else {
                try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: false)
                try FileManager.default.createSymbolicLink(at: agents.appending(path: "openai.yaml"), withDestinationURL: userFile)
            }
        case "link", "file-link":
            let target = directory.appending(path: "user-skill")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            userFile = target.appending(path: "SKILL.md")
            if kind == "link" { try FileManager.default.createSymbolicLink(at: existing, withDestinationURL: target) }
            else {
                try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
                try FileManager.default.createSymbolicLink(at: existing.appending(path: "SKILL.md"), withDestinationURL: userFile)
            }
        default: userFile = existing
        }
        try Data("user content".utf8).write(to: userFile)
        let installer = InstallationService(support: directory.appending(path: "support"))
        #expect(throws: ModuError.self) { try installer.installSkill(from: source, workspace: root) }
        #expect(try String(contentsOf: userFile, encoding: .utf8) == "user content")
        if kind == "policy-link" || kind == "agents-link" {
            #expect(try String(contentsOf: existing.appending(path: "SKILL.md"), encoding: .utf8) == "old skill")
        }
    }
    @Test func deletingAfterSaveFailureKeepsBranchAndDeclaration() async throws {
        let f = try await Fixture(); defer { f.remove() }
        try await prepare(f)
        let failing = WorkspaceStore(support: f.service.store.support) { _, _ in throw ModuError("injected", "save failed") }
        let service = WorkspaceService(store: failing, git: f.service.git)
        let result = await service.remove(.group("feature"), at: f.root, execute: true)
        #expect(result.status == .failed)
        #expect(result.items[0].effects.first?.state == "applied")
        #expect(result.items.last?.resource == .group("feature"))
        #expect(result.items.last?.reasonCode == "not-processed")
        #expect(PathSafety.exists(f.root.appending(path: "worktrees/feature")))
        #expect(try f.service.store.load(f.root).groups["feature"]?.repositories == ["repo"])
        #expect(try await f.service.git.oid("refs/heads/feature", at: f.root.appending(path: "repositories/repo")) != nil)
        #expect(!PathSafety.exists(f.root.appending(path: "worktrees/feature/repo")))
        #expect(await f.service.remove(.member(group: "feature", repo: "repo"), at: f.root, execute: true).status == .success)
    }
    @Test func confirmationDoesNotBypassNewUnmanagedWorktree() async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        let preview = try await f.service.previewDelete(.repository("repo"), at: f.root)
        let main = f.root.appending(path: "repositories/repo"), outside = f.directory.appending(path: "outside")
        _ = try await f.service.git.run(["worktree", "add", "-b", "outside", outside.path], at: main)
        _ = try await f.service.git.run(["worktree", "lock", outside.path], at: main)
        try FileManager.default.removeItem(at: outside)
        let result = await f.service.remove(.repository("repo"), at: f.root, authorization: preview)
        #expect(result.reasonCode == "unmanaged-worktree")
        #expect(PathSafety.exists(f.root.appending(path: "worktrees/feature/repo")))
    }
    @Test func groupDeletionRejectsNestedBareRepository() async throws {
        let f = try await Fixture(); defer { f.remove() }; try await prepare(f)
        let nested = f.root.appending(path: "worktrees/feature/unmanaged.git")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        _ = try await f.service.git.run(["init", "--bare"], at: nested)
        let result = await f.service.remove(.group("feature"), at: f.root, execute: true)
        #expect(result.reasonCode == "unmanaged-worktree")
        #expect(PathSafety.exists(f.root.appending(path: "worktrees/feature/repo")))
    }
    @Test(arguments: [0, 7])
    func fastCommandsPreserveOutputAndExitStatus(_ status: Int) async throws {
        let stdout = String(repeating: "stdout\n", count: 2_048), stderr = String(repeating: "stderr\n", count: 2_048)
        for _ in 0..<5 {
            let output = try await CommandRunner().run("/bin/sh", ["-c", "printf '%s' \"$1\"; printf '%s' \"$2\" >&2; exit \"$3\"", "modu-runner-test", stdout, stderr, String(status)])
            #expect(output.status == status)
            #expect(output.stdout == Data(stdout.utf8) && output.stderr == Data(stderr.utf8))
        }
    }
    @Test(arguments: ["cancelled", "network-timeout"])
    func terminationWaitsForHelpersAfterTheParentExits(_ reason: String) async throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: "modu-process-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appending(path: "helper")
        let pidFile = directory.appending(path: "helper.pid")
        try Data("""
        #!/bin/sh
        trap '' TERM INT
        echo $$ > "$1/helper.pid"
        while [ ! -e "$1/release" ]; do sleep 0.02; done
        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let task = Task {
            try await CommandRunner().run("/bin/sh", ["-c", "trap 'exit 143' TERM INT; \"$1/helper\" \"$1\" & wait", "modu-process-group-test", directory.path], timeout: reason == "network-timeout" ? 1 : 30)
        }
        var helperPID: pid_t?
        defer {
            if let helperPID { kill(helperPID, SIGKILL) }
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !PathSafety.exists(pidFile), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let pid: pid_t = try #require(pid_t(pidText))
            helperPID = pid
            let group = getpgid(pid)
            try #require(group > 0 && group != getpgrp())
            if reason == "cancelled" { task.cancel() }
            do { _ = try await task.value; Issue.record("Expected the command to terminate.") }
            catch { #expect((error as? ModuError)?.code == reason) }
            let groupStatus = kill(-group, 0), groupError = errno
            let helperStatus = kill(pid, 0), helperError = errno
            #expect(groupStatus == -1 && groupError == ESRCH, "The process group must exit before termination returns.")
            #expect(helperStatus == -1 && helperError == ESRCH, "The helper must not survive command termination.")
            if helperStatus == -1 && helperError == ESRCH { helperPID = nil }
        } catch {
            try? Data().write(to: directory.appending(path: "release"))
            task.cancel()
            _ = try? await task.value
            throw error
        }
    }
    private func prepare(_ f: Fixture) async throws {
        #expect(await f.service.openWorkspace(f.root).status == .success)
        #expect(await f.service.addRepository(.init(url: f.remoteURL), at: f.root).status == .success)
        #expect(await f.service.createGroup("feature", repositories: ["repo"], at: f.root).status == .success)
    }
}
