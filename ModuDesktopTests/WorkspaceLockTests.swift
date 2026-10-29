import Foundation
import Testing
@testable import ModuCore

struct WorkspaceLockTests {
    @Test func acquisitionRetriesAfterTheOtherOperationReleasesItsLock() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let store = fixture.service.store
        let lease = try store.tryLock(fixture.root)
        defer { lease.unlock() }
        let start = ContinuousClock.now
        let acquisition = Task { try await store.lock(fixture.root) }
        defer { acquisition.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        lease.unlock()
        let acquired = try await acquisition.value
        defer { acquired.unlock() }
        #expect(start.duration(to: .now) >= .milliseconds(500))
        #expect(throws: ModuError.self) { try store.tryLock(fixture.root) }
    }

    @Test func acquisitionTimesOutAfterTenRetries() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let lease = try fixture.service.store.tryLock(fixture.root)
        defer { lease.unlock() }
        let start = ContinuousClock.now
        do {
            _ = try await fixture.service.store.lock(fixture.root)
            Issue.record("Expected workspace lock acquisition to time out.")
        } catch {
            #expect((error as? ModuError)?.code == "workspace-lock-timeout")
            #expect(start.duration(to: .now) >= .seconds(5))
        }
        lease.unlock()
        let acquired = try await fixture.service.store.lock(fixture.root)
        acquired.unlock()
    }

    @Test func cancellationStopsWaitingWithoutReleasingAnotherOperationsLock() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let store = fixture.service.store
        let lease = try store.tryLock(fixture.root)
        defer { lease.unlock() }
        let acquisition = Task { try await store.lock(fixture.root) }
        try await Task.sleep(for: .milliseconds(100))
        acquisition.cancel()
        do {
            _ = try await acquisition.value
            Issue.record("Expected workspace lock acquisition to be cancelled.")
        } catch {
            #expect((error as? ModuError)?.code == "cancelled")
        }
        #expect(throws: ModuError.self) { try store.tryLock(fixture.root) }
        lease.unlock()
        let acquired = try await store.lock(fixture.root)
        acquired.unlock()
    }

    @Test func anotherWorkspaceCanBeLockedWhileTheFirstIsBusy() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let lease = try fixture.service.store.tryLock(fixture.root)
        defer { lease.unlock() }
        let other = try await fixture.service.store.lock(fixture.directory.appending(path: "other"))
        other.unlock()
    }
}
