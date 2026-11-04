import Foundation
import Testing
@testable import MonoDeckCore

struct WorkspaceLockTests {
    @Test func acquisitionRetriesAfterTheOtherOperationReleasesItsLock() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let retry = LockAcquisitionRetryGate()
        let store = WorkspaceStore(support: fixture.service.store.support, waitForLockRetry: { try await retry.wait() })
        let lease = try store.tryLock(fixture.root)
        defer { lease.unlock() }
        let other = try await store.lock(fixture.directory.appending(path: "other"))
        other.unlock()
        let acquisition = Task { try await store.lock(fixture.root) }
        do {
            try await retry.waitUntilStarted()
            lease.unlock()
            await retry.release()
            let acquired = try await acquisition.value
            defer { acquired.unlock() }
            #expect(throws: MonoDeckError.self) { try store.tryLock(fixture.root) }
        } catch {
            acquisition.cancel()
            await retry.release()
            if let acquired = try? await acquisition.value { acquired.unlock() }
            throw error
        }
    }

    @Test func acquisitionTimesOutWhileAnotherOperationHoldsTheLock() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let lease = try fixture.service.store.tryLock(fixture.root)
        defer { lease.unlock() }
        do {
            _ = try await fixture.service.store.lock(fixture.root)
            Issue.record("Expected workspace lock acquisition to time out.")
        } catch {
            #expect((error as? MonoDeckError)?.code == "workspace-lock-timeout")
        }
        lease.unlock()
        let acquired = try await fixture.service.store.lock(fixture.root)
        acquired.unlock()
    }

    @Test func cancellationStopsWaitingWithoutReleasingAnotherOperationsLock() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let retry = LockAcquisitionRetryGate()
        let store = WorkspaceStore(support: fixture.service.store.support, waitForLockRetry: { try await retry.wait() })
        let lease = try store.tryLock(fixture.root)
        defer { lease.unlock() }
        let acquisition = Task { try await store.lock(fixture.root) }
        do {
            try await retry.waitUntilStarted()
            acquisition.cancel()
            await retry.release()
            do {
                let acquired = try await acquisition.value
                acquired.unlock()
                Issue.record("Expected workspace lock acquisition to be cancelled.")
            } catch {
                #expect((error as? MonoDeckError)?.code == "cancelled")
            }
            #expect(throws: MonoDeckError.self) { try store.tryLock(fixture.root) }
            lease.unlock()
            let acquired = try await store.lock(fixture.root)
            acquired.unlock()
        } catch {
            acquisition.cancel()
            await retry.release()
            if let acquired = try? await acquisition.value { acquired.unlock() }
            throw error
        }
    }

    @Test(arguments: [false, true])
    func injectedRetryWaitPreservesLockOwnershipAndFailureReason(_ cancelled: Bool) async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        let retries = RecordedLockRetries(cancelled: cancelled)
        let store = WorkspaceStore(support: fixture.service.store.support, waitForLockRetry: { try await retries.wait() })
        let lease = try fixture.service.store.tryLock(fixture.root)
        defer { lease.unlock() }
        do {
            _ = try await store.lock(fixture.root)
            Issue.record("Expected the held lock to reject acquisition.")
        } catch {
            #expect((error as? MonoDeckError)?.code == (cancelled ? "cancelled" : "workspace-lock-timeout"))
        }
        let expectedRetries = cancelled ? 1 : 10
        #expect(await retries.count == expectedRetries)
        #expect(throws: MonoDeckError.self) { try fixture.service.store.tryLock(fixture.root) }
        lease.unlock()
        let acquired = try await store.lock(fixture.root)
        acquired.unlock()
        #expect(await retries.count == expectedRetries)
    }
}

private actor LockAcquisitionRetryGate {
    private var started = false
    private var released = false

    func wait() async throws {
        started = true
        while !released { try await Task.sleep(for: .milliseconds(1)) }
        try Task.checkCancellation()
    }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(started)
    }

    func release() { released = true }
}

private actor RecordedLockRetries {
    private let cancelled: Bool
    private(set) var count = 0

    init(cancelled: Bool) { self.cancelled = cancelled }

    func wait() throws {
        count += 1
        if cancelled { throw CancellationError() }
    }
}
