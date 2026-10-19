import AppKit
import Darwin
import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct ImportCancellationTests {
    @Test(arguments: ["repositories", "workspace", "quit"], [false, true])
    func cancellationDuringSavingFinishesTheCurrentRepository(_ kind: String, _ finalItem: Bool) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let other = try await prepare(fixture)
        let pause = ImportPause(directory: fixture.directory)
        let store = WorkspaceStore(support: fixture.service.store.support) { data, url in
            try data.write(to: url, options: .atomic)
            if !PathSafety.exists(pause.started) { try pause.hold() }
        }
        let service = WorkspaceService(store: store, git: fixture.service.git, trash: fixture.service.trashDirectory)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: service)
        model.language = "en"
        model.workspace.record = try store.load(fixture.root)
        if kind == "workspace" {
            model.management.importWorkspace(workspaceYAML(fixture, other: finalItem ? nil : other), filename: "workspace.yaml")
        } else {
            model.management.sheet = .add
            model.management.importRepositories("repos: [\(fixture.remoteURL)\(finalItem ? "" : ", \(other)")]", filename: "repos.yaml")
        }
        let operation = try #require(model.operation)
        do {
            try await pause.waitUntilStarted()
            #expect(model.progress?.phase == .saving && model.progress?.cancellable == false)
            if kind == "quit" {
                let delegate = AppDelegate()
                delegate.model = model
                #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
                #expect(model.presentation.quitPending)
            } else { model.cancel() }
            #expect(model.cancelling && operation.isCancelled && model.busy)
            #expect(model.presentation.operationProgressPhaseText == "Finishing current item before cancellation…")
            #expect(try store.load(fixture.root).repositories.map(\.id) == ["repo"])
            #expect(PathSafety.exists(fixture.root.appending(path: "repositories/repo")))
            #expect(!PathSafety.exists(fixture.root.appending(path: "repositories/other")))
            try pause.resume()
            await operation.value
            await model.workspace.detailPreloadTask?.value
        } catch {
            try? pause.resume()
            await operation.value
            await model.workspace.detailPreloadTask?.value
            model.presentation.quitPending = false
            throw error
        }
        model.presentation.quitPending = false
        #expect(!model.busy && !model.cancelling && model.management.sheet == nil && model.management.formError == nil)
        let saved = try store.load(fixture.root)
        #expect(saved.repositories.map(\.id) == ["repo"] && saved.groups.isEmpty)
        #expect(!PathSafety.exists(saved.repositoryURL("other")) && !PathSafety.exists(saved.groupURL("feature")))
        let committed = try await fixture.service.git.run(["show", "HEAD:.gitignore"], at: fixture.root).text
        #expect(committed.contains("/repo/") && !committed.contains("/other/"))
        if finalItem {
            #expect(model.presentation.result == nil || (kind == "quit" && model.presentation.result?.status == .success))
        } else {
            let result = try #require(model.presentation.result)
            #expect(result.status == .cancelled && result.reasonCode == "cancelled" && result.exitCode == 130)
            let completed = try #require(result.items.first { $0.resource == .repository("repo") })
            #expect(completed.status == .success && completed.effects.allSatisfy { $0.state == "applied" })
            #expect(completed.effects.contains { $0.action == "clone" } && completed.effects.contains { $0.action == "save-configuration" })
            #expect(result.items.contains { $0.effects.contains { $0.action == "commit-workspace-files" } })
            #expect(result.items.filter { $0.resource == .repository("other") }.allSatisfy { $0.effects.isEmpty && [.cancelled, .skipped].contains($0.status) })
            #expect(!result.items.contains { $0.status == .failed })
        }
        let lease = try store.lock(fixture.root); lease.unlock()
    }

    @Test func workspaceImportRestoresCancellationBeforeGroupPreflight() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        _ = try await prepare(fixture)
        let pause = ImportPause(directory: fixture.directory)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(fixture.root.path, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.language = "en"
        model.workspace.record = try fixture.service.store.load(fixture.root)
        let yaml = workspaceYAML(fixture, other: nil, group: true)
        model.management.run { service, root, progress in
            await service.importWorkspaceYAML(yaml, at: root) { value in
                progress(value)
                if value.target == Resource.group("feature").path, value.phase == .checkingRepository { try? pause.hold() }
            }
        }
        let operation = try #require(model.operation)
        do {
            try await pause.waitUntilStarted()
            #expect(model.progress?.phase == .checkingRepository && model.progress?.cancellable == true)
            model.cancel()
            #expect(model.cancelling && operation.isCancelled)
            #expect(model.presentation.operationProgressPhaseText == "Cancelling…")
            try pause.resume()
            await operation.value
            await model.workspace.detailPreloadTask?.value
        } catch {
            try? pause.resume()
            await operation.value
            await model.workspace.detailPreloadTask?.value
            throw error
        }
        let result = try #require(model.presentation.result)
        #expect(result.status == .cancelled && !result.items.contains { $0.status == .failed })
        #expect(result.items.filter { [.group, .member].contains($0.resource.kind) }.allSatisfy { $0.effects.isEmpty })
        let saved = try fixture.service.store.load(fixture.root)
        #expect(saved.repositories.map(\.id) == ["repo"] && saved.groups.isEmpty)
        #expect(!PathSafety.exists(saved.groupURL("feature")))
        #expect(try await fixture.service.git.run(["show", "HEAD:.gitignore"], at: fixture.root).text.contains("/repo/"))
    }

    @Test(arguments: ["add", "repositories"])
    func cancellationDuringWorkspaceValidationIsNotReportedAsFailure(_ kind: String) async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        _ = try await prepare(fixture)
        let record = try fixture.service.store.load(fixture.root)
        let defaults = try #require(UserDefaults(suiteName: fixture.directory.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: fixture.directory.lastPathComponent) }
        defaults.set(record.root, forKey: "workspace")
        let model = AppModel(defaults: defaults, service: fixture.service)
        model.workspace.record = record
        model.management.sheet = .add
        let config = fixture.root.appending(path: ".git/config")
        let original = try Data(contentsOf: config)
        try FileManager.default.removeItem(at: config)
        try #require(mkfifo(config.path, 0o600) == 0)
        var writer: Int32 = -1
        defer { if writer >= 0 { close(writer) } }
        if kind == "add" { model.management.add(fixture.remoteURL, name: "") }
        else { model.management.importRepositories("repos: [\(fixture.remoteURL)]", filename: "repos.yaml") }
        let operation = try #require(model.operation)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            // Keep Git reading its config until the cancellation entry point is exercised.
            while writer < 0, ContinuousClock.now < deadline {
                writer = Darwin.open(config.path, O_WRONLY | O_NONBLOCK)
                if writer < 0 { try await Task.sleep(for: .milliseconds(10)) }
            }
            try #require(writer >= 0)
            model.cancel()
            #expect(model.cancelling && operation.isCancelled)
            try FileManager.default.removeItem(at: config)
            try original.write(to: config, options: .atomic)
            await operation.value
            await model.workspace.detailPreloadTask?.value
        } catch {
            try? FileManager.default.removeItem(at: config)
            try? original.write(to: config, options: .atomic)
            model.cancel()
            await operation.value
            await model.workspace.detailPreloadTask?.value
            throw error
        }
        #expect(!model.busy && model.management.formError == nil && model.presentation.result == nil && model.management.sheet == nil)
        #expect(try fixture.service.store.load(fixture.root) == record)
        #expect(!PathSafety.exists(record.repositoryURL("repo")))
    }

    private func prepare(_ fixture: Fixture) async throws -> String {
        #expect(await fixture.service.openWorkspace(fixture.root).status == .success)
        let other = "https://modu-test.invalid/other.git"
        _ = try await fixture.service.git.run(["config", "--global", "--add", "url.\(fixture.directory.appending(path: "repo.git").path).insteadOf", other], at: fixture.root)
        return other
    }

    private func workspaceYAML(_ fixture: Fixture, other: String?, group: Bool = false) -> String {
        """
        version: 1
        repositories:
          - url: \(fixture.remoteURL)
        \(other.map { "  - url: \($0)\n" } ?? "")groups: \(group || other != nil ? "\n  feature:\n    created-at: \"2026-10-10T00:00:00Z\"\n    repositories: [repo]" : "{}")
        """
    }
}

private struct ImportPause: Sendable {
    let started: URL
    let release: URL

    init(directory: URL) {
        started = directory.appending(path: "import-started")
        release = directory.appending(path: "import-release")
    }

    func hold() throws {
        try Data().write(to: started)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !PathSafety.exists(release), ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard PathSafety.exists(release) else { throw ModuError("test-timeout", "Import pause was not released.") }
    }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !PathSafety.exists(started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(PathSafety.exists(started))
    }

    func resume() throws { try Data().write(to: release) }
}
