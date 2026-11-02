import CoreServices
import Foundation

public protocol WorkspaceRecordChangeMonitoring: AnyObject, Sendable {
    func start(_ recordURL: URL, onChange: @escaping @Sendable () -> Void) -> Bool
    func stop()
}

public final class WorkspaceRecordChangeMonitor: WorkspaceRecordChangeMonitoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "fun.armantang.Modu.workspace-record-events", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private var recordPath: String?
    private var directoryPath: String?
    private var onChange: (@Sendable () -> Void)?

    public init() { queue.setSpecific(key: queueKey, value: true) }
    deinit { stop() }

    public func start(_ recordURL: URL, onChange: @escaping @Sendable () -> Void) -> Bool {
        queue.sync {
            stopStream()
            let directory = PathSafety.canonical(recordURL.deletingLastPathComponent())
            guard (try? PathSafety.directory(directory)) != nil else { return false }
            recordPath = directory.appending(path: recordURL.lastPathComponent).path
            directoryPath = directory.path
            self.onChange = onChange
            var info = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { stream, info, count, paths, flags, _ in
                guard let info else { return }
                let monitor = Unmanaged<WorkspaceRecordChangeMonitor>.fromOpaque(info).takeUnretainedValue()
                let names = unsafeBitCast(paths, to: NSArray.self) as! [String]
                monitor.receive(names, flags: flags, count: count, from: stream)
            }, &info, [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
                stopStream()
                return false
            }
            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else { stopStream(); return false }
            return true
        }
    }

    public func stop() {
        // The callback can release the last reference on the event queue.
        if DispatchQueue.getSpecific(key: queueKey) == true { stopStream() }
        else { queue.sync { stopStream() } }
    }

    private func stopStream() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
        stream = nil; recordPath = nil; directoryPath = nil; onChange = nil
    }

    private func receive(_ paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int, from stream: ConstFSEventStreamRef) {
        guard self.stream == stream, let recordPath, let directoryPath else { return }
        let uncertain = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        let directoryChanges = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
        for index in 0..<count {
            if flags[index] & uncertain != 0 { onChange?(); return }
            let event = URL(fileURLWithPath: paths[index])
            // Removed files can arrive through a volume alias; resolve their existing parent instead of the missing leaf.
            let path = PathSafety.canonical(event.deletingLastPathComponent()).appending(path: event.lastPathComponent).path
            if path == recordPath || (path == directoryPath && flags[index] & directoryChanges != 0) {
                onChange?()
                return
            }
        }
    }
}
