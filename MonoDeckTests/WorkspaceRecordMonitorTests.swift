import Foundation
import Testing
@testable import MonoDeckCore

struct WorkspaceRecordMonitorTests {
    @Test func nativeMonitorFiltersOtherRecordsAndDeliversAtomicReplacementAndRemoval() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let record = WorkspaceRecord(root: PathSafety.canonical(fixture.root).path)
        try fixture.service.store.save(record)
        let file = fixture.service.store.recordURL(fixture.root)
        let monitor = WorkspaceRecordChangeMonitor()
        defer { monitor.stop() }
        let events = WorkspaceRecordMonitorEvents()
        try #require(monitor.start(file) { events.record() })
        try await Task.sleep(for: .milliseconds(300))
        events.reset()

        try Data("other".utf8).write(to: file.deletingLastPathComponent().appending(path: "other.json"), options: .atomic)
        try await Task.sleep(for: .milliseconds(300))
        #expect(events.count == 0)
        try Data("replacement".utf8).write(to: file, options: .atomic)
        try await eventually("Atomic replacement must notify the current record monitor") { events.count > 0 }
        try await Task.sleep(for: .milliseconds(300))
        events.reset()
        try FileManager.default.removeItem(at: file)
        try await eventually("Removing the replaced record must still notify the parent-directory monitor") { events.count > 0 }

        monitor.stop()
        let count = events.count
        try Data("after stop".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(300))
        #expect(events.count == count)
    }

    @Test func nativeMonitorCanStartBeforeRecordCreationAndReplaceItsTarget() async throws {
        let fixture = try await Fixture(createRemote: false); defer { fixture.remove() }
        let directory = fixture.directory.appending(path: "records")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let first = directory.appending(path: "first.json")
        let second = directory.appending(path: "second.json")
        let monitor = WorkspaceRecordChangeMonitor()
        defer { monitor.stop() }
        let oldEvents = WorkspaceRecordMonitorEvents()
        let currentEvents = WorkspaceRecordMonitorEvents()
        try #require(monitor.start(first) { oldEvents.record() })
        try Data("first".utf8).write(to: first, options: .atomic)
        try await eventually("Creating the first record must notify its monitor") { oldEvents.count > 0 }
        try #require(monitor.start(second) { currentEvents.record() })
        try await Task.sleep(for: .milliseconds(300))
        let previousCount = oldEvents.count
        currentEvents.reset()
        try Data("old record".utf8).write(to: first, options: .atomic)
        try await Task.sleep(for: .milliseconds(300))
        #expect(oldEvents.count == previousCount && currentEvents.count == 0)
        try Data("second".utf8).write(to: second, options: .atomic)
        try await eventually("Creating the second record must notify the rebound monitor") { currentEvents.count > 0 }
    }

    private func eventually(_ phase: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "\(phase)")
    }
}

private final class WorkspaceRecordMonitorEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
    func reset() { lock.withLock { value = 0 } }
}
