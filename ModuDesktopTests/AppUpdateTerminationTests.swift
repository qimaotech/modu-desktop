import AppKit
import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct AppUpdateTerminationTests {
    @Test func quittingWaitsForCancellationCleanupAndCoalescesRepeatedRequests() async throws {
        let fixture = try AppUpdateFixture()
        defer { fixture.remove() }
        let model = try makeModel(fixture)
        let cleanup = CleanupGate()
        var started = false
        defer {
            cleanup.release()
            model.updates.cancel()
        }
        model.updates.runInstallation { _ in
            started = true
            do { try await Task.sleep(for: .seconds(30)) }
            catch { await cleanup.wait() }
        }
        try await waitUntil { started }
        let quit = QuitProbe()
        let delegate = AppDelegate(terminate: quit.request)
        quit.delegate = delegate
        delegate.model = model

        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        let preparation = try #require(delegate.terminationTask)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        try await waitUntil { cleanup.waiting }
        #expect(model.presentation.quitPending && quit.replies.isEmpty)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        cleanup.release()
        await preparation.value

        #expect(quit.replies == [.terminateNow])
        #expect(delegate.terminationTask == nil && !model.updates.needsTerminationPreparation)
    }

    @Test func updateInstallerIsReadyBeforeTheFinalQuitAndFailureAllowsAnotherHandoff() async throws {
        let fixture = try AppUpdateFixture()
        defer { fixture.remove() }
        let prepared = try fixture.prepared()
        var restartRequests = 0
        let updates = AppUpdateModel(preferences: try fixture.preferences(), requestRestart: { restartRequests += 1 })
        let model = try makeModel(fixture, updates: updates)
        let quit = QuitProbe()
        let delegate = AppDelegate { sender in
            #expect(PathSafety.exists(prepared.ready))
            quit.request(sender)
        }
        quit.delegate = delegate
        delegate.model = model

        updates.restart(afterPreparing: prepared)
        #expect(restartRequests == 1 && updates.restartPending)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        let preparation = try #require(delegate.terminationTask)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        await preparation.value
        #expect(quit.replies == [.terminateNow])
        #expect(updates.restartPending && updates.needsTerminationPreparation)

        let failure: [String: String] = ["identifier": prepared.identifier.uuidString, "code": "update-exit-timeout", "message": "Test exit timeout"]
        try JSONSerialization.data(withJSONObject: failure).write(to: prepared.failure, options: .atomic)
        try await waitUntil { !updates.restartPending }
        #expect(!model.presentation.quitPending && updates.error != nil)
        try await waitUntil { fixture.helperHasExited(prepared) }

        let retry = try fixture.prepared()
        updates.restart(afterPreparing: retry)
        #expect(restartRequests == 2)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        await (try #require(delegate.terminationTask)).value
        #expect(PathSafety.exists(retry.ready) && quit.replies == [.terminateNow, .terminateNow])
        AppUpdateInstaller().cancelHandoff(retry)
        try await waitUntil { !updates.restartPending && fixture.helperHasExited(retry) }
    }

    @Test func failedInstallerLaunchCancelsQuitAndRestoresUpdateControls() async throws {
        let fixture = try AppUpdateFixture()
        defer { fixture.remove() }
        let prepared = try fixture.prepared(helper: "#!/bin/sh\nexit 1\n")
        let updates = AppUpdateModel(preferences: try fixture.preferences(), requestRestart: {})
        let model = try makeModel(fixture, updates: updates)
        var terminationRequests = 0
        let delegate = AppDelegate { _ in terminationRequests += 1 }
        delegate.model = model

        updates.restart(afterPreparing: prepared)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        await (try #require(delegate.terminationTask)).value

        #expect(terminationRequests == 0 && delegate.terminationTask == nil)
        #expect(!updates.restartPending && !updates.working && updates.error != nil)
        #expect(!model.presentation.quitPending && PathSafety.exists(prepared.cancelled))
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
    }

    private func makeModel(_ fixture: AppUpdateFixture, updates: AppUpdateModel? = nil) throws -> AppModel {
        AppModel(defaults: try fixture.preferences().defaults,
                 toolService: ExternalTools(applicationURL: { _ in nil }, openURL: { _, _ in }), updates: updates)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @MainActor private final class CleanupGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        var waiting: Bool { continuation != nil }

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume(); continuation = nil
        }
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
