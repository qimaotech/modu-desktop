import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct AppUpdateInstallerTests {
    @Test func preparedUpdateWaitsForExitThenReplacesAndRelaunchesTheApplication() async throws {
        let fixture = try AppUpdateFixture()
        let existing = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "fun.armantang.ModuDesktop" }
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["60"]
        defer {
            if parent.isRunning { parent.terminate(); parent.waitUntilExit() }
            fixture.remove()
            #expect(existing.allSatisfy { !$0.isTerminated })
        }
        let runner = CommandRunner()
        try await command(runner, "/usr/bin/ditto", [Bundle.main.bundleURL.path, fixture.application.path])
        let source = fixture.directory.appending(path: "image/Modu.app")
        try await command(runner, "/usr/bin/ditto", [fixture.application.path, source.path])
        let info = source.appending(path: "Contents/Info.plist")
        var values = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
        values["CFBundleShortVersionString"] = "99.0.0"
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: info)
        try Data("new application".utf8).write(to: source.appending(path: "Contents/Resources/update-marker"))
        try await command(runner, "/usr/bin/codesign", ["--force", "--sign", "-", source.path])
        let dmg = fixture.directory.appending(path: "Modu-99.0.0-arm64.dmg")
        try await command(runner, "/usr/bin/hdiutil", ["create", "-srcfolder", source.deletingLastPathComponent().path,
                                                       "-format", "UDZO", "-fs", "HFS+", dmg.path])
        let data = try Data(contentsOf: dmg)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let update = AppUpdate(version: "99.0.0", releaseURL: AppUpdateService.releasesURL,
                               asset: .init(name: dmg.lastPathComponent, size: Int64(data.count), browserDownloadURL: dmg,
                                            digest: "sha256:\(digest)"))
        let cli = fixture.application.appending(path: "Contents/Resources/modu-cli")
        let link = fixture.directory.appending(path: "modu-cli")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
        let service = AppUpdateService(cacheDirectory: fixture.directory.appending(path: "cache"))
        let download = fixture.directory.appending(path: "download.dmg")
        try FileManager.default.copyItem(at: dmg, to: download)
        let cached = try service.cacheDownload(at: download, asset: update.asset)
        let installer = AppUpdateInstaller(runner: runner)
        let prepared = try await installer.prepare(installer: cached, update: update, application: fixture.application, helper: cli)
        service.discardDownload(at: cached)
        #expect(!PathSafety.exists(cached.deletingLastPathComponent()))
        #expect(PathSafety.exists(dmg))
        try parent.run()
        try await installer.launch(prepared, parentPID: parent.processIdentifier)

        #expect(PathSafety.exists(prepared.ready))
        let helperPID = try #require(Int32(try String(contentsOf: prepared.ready, encoding: .utf8)))
        #expect(!PathSafety.exists(fixture.application.appending(path: "Contents/Resources/update-marker")))
        parent.terminate(); parent.waitUntilExit()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var restarted: NSRunningApplication?
        while ContinuousClock.now < deadline {
            restarted = NSWorkspace.shared.runningApplications.first {
                $0.bundleURL.map { PathSafety.canonical($0).path } == PathSafety.canonical(fixture.application).path && $0.isFinishedLaunching
            }
            if restarted != nil && !PathSafety.exists(prepared.directory) && kill(helperPID, 0) == -1 && errno == ESRCH { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(restarted != nil)
        #expect(!PathSafety.exists(prepared.directory))
        #expect(kill(helperPID, 0) == -1 && errno == ESRCH)
        #expect(try String(contentsOf: fixture.application.appending(path: "Contents/Resources/update-marker"), encoding: .utf8) == "new application")
        let installed = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.application.appending(path: "Contents/Info.plist")), format: nil) as? [String: Any])
        #expect(installed["CFBundleShortVersionString"] as? String == "99.0.0")
        #expect(try await runner.run(link.path, ["--version"]).text == ModuVersion.current)
    }

    @Test(arguments: [false, true])
    func timeoutAndCancellationLeaveTheInstalledApplicationIntact(_ cancelled: Bool) async throws {
        let fixture = try AppUpdateFixture()
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["30"]
        defer {
            if parent.isRunning { parent.terminate(); parent.waitUntilExit() }
            fixture.remove()
        }
        let prepared = try fixture.prepared(helper: "")
        try Data("original application".utf8).write(to: fixture.application.appending(path: "marker"))
        if cancelled { try Data().write(to: prepared.cancelled) }
        try parent.run()
        do {
            try await AppUpdateInstaller(exitTimeout: 0.05).run(directory: prepared.directory, parentPID: parent.processIdentifier)
            Issue.record("The installer must not replace a running application.")
        } catch {
            if cancelled { #expect(error is CancellationError) }
            else { #expect((error as? ModuError)?.code == "update-exit-timeout") }
        }
        #expect(parent.isRunning)
        #expect(try String(contentsOf: fixture.application.appending(path: "marker"), encoding: .utf8) == "original application")
        if cancelled { #expect(!PathSafety.exists(prepared.directory)) }
        else {
            let failure = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: prepared.failure)) as? [String: String])
            #expect(failure["identifier"] == prepared.identifier.uuidString && failure["code"] == "update-exit-timeout")
        }
    }

    private func command(_ runner: CommandRunner, _ executable: String, _ arguments: [String]) async throws {
        let output = try await runner.run(executable, arguments, timeout: 120)
        try #require(output.status == 0, "\(output.text)\n\(String(decoding: output.stderr, as: UTF8.self))")
    }
}

@MainActor struct AppUpdateFixture {
    let directory: URL
    var application: URL { directory.appending(path: "Modu.app") }

    init() throws {
        directory = TestEnvironment.temporaryDirectory.appending(path: "modu update tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func prepared(helper: String = """
    #!/bin/sh
    printf '%s' "$$" > "$2/ready.tmp"
    /bin/mv "$2/ready.tmp" "$2/ready"
    while [ ! -e "$2/cancelled" ]; do /bin/sleep 0.02; done
    """) throws -> PreparedAppUpdate {
        let stage = directory.appending(path: ".Modu-Update-\(UUID().uuidString)")
        let candidate = stage.appending(path: "Modu.app")
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let executable = stage.appending(path: "modu-update")
        try Data(helper.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let update = PreparedAppUpdate(identifier: UUID(), directory: stage, application: application, version: "99.0.0",
                                       originalIdentity: try UpdateFileIdentity(application), candidateIdentity: try UpdateFileIdentity(candidate))
        try JSONEncoder().encode(update).write(to: stage.appending(path: "installation.json"))
        return update
    }

    func preferences() throws -> AppPreferences {
        AppPreferences(defaults: try #require(UserDefaults(suiteName: directory.lastPathComponent)))
    }

    func helperHasExited(_ update: PreparedAppUpdate) -> Bool {
        guard let value = try? String(contentsOf: update.ready, encoding: .utf8), let pid = Int32(value), pid > 1 else { return true }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    func remove() {
        let applications = NSWorkspace.shared.runningApplications.filter { $0.bundleURL.map { PathSafety.canonical($0).path } == PathSafety.canonical(application).path }
        for app in applications { _ = app.terminate() }
        let stages = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(".Modu-Update-") }
        for stage in stages { try? Data().write(to: stage.appending(path: "cancelled")) }
        let deadline = Date(timeIntervalSinceNow: 5)
        func helpersExited() -> Bool {
            stages.allSatisfy { stage in
                guard let value = try? String(contentsOf: stage.appending(path: "ready"), encoding: .utf8), let pid = Int32(value), pid > 1 else { return true }
                // Running the installer inline records the test host instead of a detached helper.
                return pid == getpid() || (kill(pid, 0) == -1 && errno == ESRCH)
            }
        }
        while (!applications.allSatisfy(\.isTerminated) || !helpersExited()), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        guard applications.allSatisfy(\.isTerminated), helpersExited() else {
            Issue.record("Update verification is still running; keeping \(directory.path)")
            return
        }
        UserDefaults(suiteName: directory.lastPathComponent)?.removePersistentDomain(forName: directory.lastPathComponent)
        try? FileManager.default.removeItem(at: directory)
    }
}
