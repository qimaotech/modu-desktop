import AppKit
import Darwin
import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct AppRelaunchTests {
    @Test func relaunchWaitsForTheOriginalProcessAndPreservesTheIsolatedEnvironment() async throws {
        let fixture = try AppUpdateFixture()
        let relauncher = AppRelauncher()
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["60"]
        var handoff: AppRelaunch?
        defer {
            if let handoff { clean(handoff, using: relauncher) }
            if parent.isRunning { parent.terminate(); parent.waitUntilExit() }
            fixture.remove()
        }
        let output = try await CommandRunner().run("/usr/bin/ditto", [Bundle.main.bundleURL.path, fixture.application.path])
        try #require(output.status == 0)
        let helper = try #require(Bundle.main.url(forResource: "modu-cli", withExtension: nil))
        let applicationPath = PathSafety.canonical(fixture.application).path
        try parent.run()
        let prepared = try await relauncher.launch(application: fixture.application, helper: helper, arguments: ["--relaunch-test"], parentPID: parent.processIdentifier)
        handoff = prepared
        let pid = try helperPID(prepared)
        #expect(!NSWorkspace.shared.runningApplications.contains { $0.bundleURL.map { PathSafety.canonical($0).path } == applicationPath })
        parent.terminate(); parent.waitUntilExit()
        try await waitUntil {
            NSWorkspace.shared.runningApplications.contains { $0.bundleURL.map { PathSafety.canonical($0).path } == applicationPath && $0.isFinishedLaunching }
                && !PathSafety.exists(prepared.directory) && !running(pid)
        }
        let application = try #require(NSWorkspace.shared.runningApplications.first { $0.bundleURL.map { PathSafety.canonical($0).path } == applicationPath })
        if let session = ProcessInfo.processInfo.environment["MODU_TEST_SESSION_DIRECTORY"] {
            #expect(PathSafety.exists(URL(fileURLWithPath: session).appending(path: "hosts/\(application.processIdentifier).json")))
        }
    }

    @Test(arguments: [false, true])
    func timeoutAndCancellationDoNotOpenAnotherInstance(_ cancelled: Bool) async throws {
        let fixture = try AppUpdateFixture()
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["30"]
        let relaunch = AppRelaunch(directory: fixture.directory.appending(path: "modu-relaunch-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: relaunch.directory, withIntermediateDirectories: false)
        defer {
            if parent.isRunning { parent.terminate(); parent.waitUntilExit() }
            fixture.remove()
        }
        if cancelled { AppRelauncher().cancel(relaunch) }
        try parent.run()
        do {
            try await AppRelauncher(exitTimeout: 0.01).run(application: fixture.application, directory: relaunch.directory,
                                                        parentPID: parent.processIdentifier, arguments: [])
            Issue.record("The original process is still running.")
        } catch {
            if cancelled { #expect(error is CancellationError) }
            else { #expect((error as? ModuError)?.code == "relaunch-failed" && PathSafety.exists(relaunch.failure)) }
        }
        #expect(parent.isRunning)
        #expect(!NSWorkspace.shared.runningApplications.contains { $0.bundleURL.map { PathSafety.canonical($0).path } == PathSafety.canonical(fixture.application).path })
        if cancelled { #expect(!PathSafety.exists(relaunch.directory)) }
    }

    @Test func invalidHandoffDirectoryIsNeverRemoved() async throws {
        let fixture = try AppUpdateFixture()
        defer { fixture.remove() }
        let marker = fixture.directory.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: marker)
        do {
            try await AppRelauncher().run(application: fixture.application, directory: fixture.directory, parentPID: Int32.max, arguments: [])
            Issue.record("An unrelated directory must not be used for relaunch data.")
        } catch {
            #expect((error as? ModuError)?.code == "invalid-input")
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
    }

    @Test func languageRestartWaitsForOperationsAndFailureKeepsTheAppOpen() async throws {
        let fixture = try AppUpdateFixture()
        defer { fixture.remove() }
        let defaults = try fixture.preferences().defaults
        defaults.set(AppLanguage.english.rawValue, forKey: "appLanguage")
        var requests = 0
        let relaunch = AppRelaunchModel(helper: nil, requestRestart: { requests += 1 })
        let model = AppModel(defaults: defaults, relaunch: relaunch)
        var finalQuitRequests = 0
        let delegate = AppDelegate { _ in finalQuitRequests += 1 }
        delegate.model = model
        let generation = try #require(model.operations.begin(.workspace, cancellable: false))
        model.changeLanguageAndRestart(.simplifiedChinese)
        model.changeLanguageAndRestart(.english)
        #expect(requests == 1 && relaunch.restartPending)
        #expect(defaults.string(forKey: "appLanguage") == "zh_CN" && model.preferences.activeLocale == .english)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        #expect(model.presentation.quitPending && !model.cancelling && delegate.terminationTask == nil)
        model.operations.finish(generation)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        await (try #require(delegate.terminationTask)).value
        #expect(finalQuitRequests == 0 && !relaunch.restartPending && !model.presentation.quitPending)
        #expect(model.presentation.message != nil && model.presentation.messageHost == .settings)
        #expect(defaults.string(forKey: "appLanguage") == "zh_CN")
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
    }

    @Test func finalQuitWaitsForHelperReadinessAndHandoffFailureAllowsRetry() async throws {
        let fixture = try AppUpdateFixture()
        defer { fixture.remove() }
        let handoffPath = fixture.directory.appending(path: "handoff-path")
        let helper = fixture.directory.appending(path: "relaunch-helper")
        try Data("""
        #!/bin/sh
        printf '%s' "$3" > "$RELAUNCH_TEST_HANDOFF"
        printf '%s' "$$" > "$3/ready"
        while [ -d "$3" ] && [ ! -e "$3/cancelled" ]; do /bin/sleep 0.02; done
        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        var environment = ProcessInfo.processInfo.environment
        environment["RELAUNCH_TEST_HANDOFF"] = handoffPath.path
        let relauncher = AppRelauncher(runner: CommandRunner(environment: environment))
        var requests = 0
        let relaunch = AppRelaunchModel(relauncher: relauncher, helper: helper, requestRestart: { requests += 1 })
        let model = AppModel(defaults: try fixture.preferences().defaults, relaunch: relaunch)
        let quit = QuitProbe()
        let delegate = AppDelegate(terminate: quit.request)
        quit.delegate = delegate
        delegate.model = model
        var handoff: AppRelaunch?
        defer { if let handoff { clean(handoff, using: relauncher) } }
        relaunch.restart()
        #expect(requests == 1)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        let preparation = try #require(delegate.terminationTask)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        await preparation.value
        let prepared = AppRelaunch(directory: URL(fileURLWithPath: try String(contentsOf: handoffPath, encoding: .utf8)))
        handoff = prepared
        let pid = try helperPID(prepared)
        #expect(PathSafety.exists(prepared.ready) && relaunch.restartPending && quit.replies == [.terminateNow])
        try Data("Test handoff failure".utf8).write(to: prepared.failure)
        try await waitUntil { !relaunch.restartPending && !running(pid) }
        #expect(!model.presentation.quitPending && model.presentation.message != nil)
        #expect(!PathSafety.exists(prepared.directory))
        relaunch.restart()
        #expect(requests == 2)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition())
    }

    private func helperPID(_ relaunch: AppRelaunch) throws -> Int32 {
        try #require(Int32(String(contentsOf: relaunch.ready, encoding: .utf8)))
    }

    private func running(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }

    private func clean(_ relaunch: AppRelaunch, using relauncher: AppRelauncher) {
        relauncher.cancel(relaunch)
        if let pid = try? helperPID(relaunch) {
            let deadline = Date(timeIntervalSinceNow: 5)
            while running(pid), Date() < deadline { usleep(10_000) }
            #expect(!running(pid))
        }
        relauncher.discard(relaunch)
    }

    @MainActor private final class QuitProbe {
        weak var delegate: AppDelegate?
        var replies: [NSApplication.TerminateReply] = []

        func request(_ application: NSApplication) {
            guard let delegate else { Issue.record("Missing application delegate"); return }
            replies.append(delegate.applicationShouldTerminate(application))
        }
    }
}
