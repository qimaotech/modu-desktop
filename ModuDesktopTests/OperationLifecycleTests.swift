import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct OperationLifecycleTests {
    @Test func completedOperationsCannotPublishIntoTheirSuccessor() throws {
        let lifecycle = OperationLifecycle()
        let first = try #require(lifecycle.begin(.management))
        #expect(lifecycle.begin(.setup) == nil)
        lifecycle.finish(first)
        let second = try #require(lifecycle.begin(.workspace))
        lifecycle.report(.init("old", .saving), for: first)
        lifecycle.finish(first)
        #expect(lifecycle.busy && lifecycle.kind == .workspace && lifecycle.progress == nil)
        lifecycle.finish(second)
        #expect(!lifecycle.busy && lifecycle.task == nil)
    }

    @Test func cancellationHonorsTheCurrentCriticalSection() async throws {
        let lifecycle = OperationLifecycle()
        let token = try #require(lifecycle.begin(.setup))
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        lifecycle.attach(task, to: token)
        lifecycle.report(.init("workspace", .saving, cancellable: false), for: token)
        lifecycle.cancel()
        #expect(!lifecycle.cancelling && !task.isCancelled)
        lifecycle.report(.init("workspace", .openingWorkspace), for: token)
        lifecycle.cancel()
        await task.value
        #expect(lifecycle.cancelling && task.isCancelled)
        lifecycle.finish(token)
        #expect(!lifecycle.busy && !lifecycle.cancelling && lifecycle.progress == nil)
    }
}
