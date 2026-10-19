import Foundation
import ModuCore
import Observation

@MainActor @Observable
final class OperationLifecycle {
    enum Kind { case workspace, management, setup }
    private(set) var kind: Kind?
    private(set) var cancelling = false
    private(set) var progress: OperationProgress?
    private(set) var task: Task<Void, Never>?
    private var generation = 0
    var busy: Bool { kind != nil }

    func begin(_ kind: Kind) -> Int? {
        guard !busy else { return nil }
        generation += 1
        self.kind = kind; cancelling = false; progress = nil
        return generation
    }

    func attach(_ task: Task<Void, Never>?, to generation: Int) {
        guard isCurrent(generation) else { return }
        self.task = task
    }

    func report(_ progress: OperationProgress, for generation: Int) {
        guard isCurrent(generation) else { return }
        self.progress = progress
    }

    func isCurrent(_ generation: Int) -> Bool { self.generation == generation && busy }

    func cancel() {
        guard busy, progress?.cancellable != false else { return }
        cancelling = true
        task?.cancel()
    }

    func finish(_ generation: Int) {
        guard self.generation == generation else { return }
        kind = nil; cancelling = false; progress = nil; task = nil
    }
}
