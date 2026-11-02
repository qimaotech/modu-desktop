import CoreServices
import Foundation

public enum ResourceChange: Int, Sendable, Comparable {
    case workingTree, summary, structure
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public protocol ResourceChangeMonitoring: AnyObject, Sendable {
    func start(_ context: ResourceReadContext, excludedDirectories: [URL], onChange: @escaping @Sendable (ResourceChange) -> Void) -> Bool
    func stop()
}

public final class ResourceChangeMonitor: ResourceChangeMonitoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "fun.armantang.Modu.resource-events", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private var context: ResourceReadContext?
    private var gitDirectories: [String] = []
    private var worktreePath = ""
    private var gitPath = ""
    private var excluded: [String] = []
    private var submodules: [String] = []
    private var onChange: (@Sendable (ResourceChange) -> Void)?

    public init() { queue.setSpecific(key: queueKey, value: true) }
    deinit { stop() }

    public func start(_ context: ResourceReadContext, excludedDirectories: [URL] = [], onChange: @escaping @Sendable (ResourceChange) -> Void) -> Bool {
        queue.sync {
            stopStream()
            self.context = context; self.excluded = excludedDirectories.map { PathSafety.canonical($0).path }
            self.worktreePath = PathSafety.canonical(context.path).path
            self.gitPath = PathSafety.canonical(context.gitDirectory).path
            self.gitDirectories = Array(Set([gitPath, PathSafety.canonical(context.commonDirectory).path])).sorted { $0.count > $1.count }
            self.onChange = onChange
            var info = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let paths = Array(Set([context.path, context.gitDirectory, context.commonDirectory].map { PathSafety.canonical($0).path }))
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, _ in
                guard let info else { return }
                let monitor = Unmanaged<ResourceChangeMonitor>.fromOpaque(info).takeUnretainedValue()
                let names = unsafeBitCast(paths, to: NSArray.self) as! [String]
                monitor.receive(names, flags: flags, count: count)
            }, &info, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return false }
            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else { stopStream(); return false }
            // Changes after this validation are covered by the stream's index events.
            self.submodules = context.submoduleDirectories.map { PathSafety.canonical($0).path }
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
        stream = nil; context = nil; onChange = nil; excluded = []; submodules = []
        gitDirectories = []; worktreePath = ""; gitPath = ""
    }

    private func receive(_ paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        guard context != nil else { return }
        var change: ResourceChange?
        let uncertain = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        for index in 0..<count {
            if flags[index] & uncertain != 0 { change = .structure; break }
            let event = URL(fileURLWithPath: paths[index])
            // Removed files can arrive through a volume alias; resolve their existing parent instead of the missing leaf.
            let path = PathSafety.canonical(event.deletingLastPathComponent()).appending(path: event.lastPathComponent).path
            if excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            if let event = classify(path, flags: flags[index]) { change = max(change ?? event, event) }
        }
        if let change { onChange?(change) }
    }

    private func classify(_ path: String, flags: FSEventStreamEventFlags) -> ResourceChange? {
        for directory in gitDirectories {
            if path == directory { return .structure }
            guard path.hasPrefix(directory + "/") else { continue }
            let relative = String(path.dropFirst(directory.count + 1))
            if relative.hasSuffix(".lock") || relative.hasPrefix("objects/") || relative.hasPrefix("logs/") { return nil }
            if relative == "config" || relative == "config.worktree" || relative == "commondir" || relative == "worktrees" { return .structure }
            if relative.hasPrefix("worktrees/") {
                return relative.split(separator: "/").count <= 2 || relative.hasSuffix("/gitdir") || relative.hasSuffix("/commondir") ? .structure : nil
            }
            if directory != gitPath, relative == "HEAD" || relative == "index" { return nil }
            if relative == "HEAD" || relative == "packed-refs" || relative == "refs" || relative.hasPrefix("refs/") { return .summary }
            if relative == "index" || relative.hasPrefix("sharedindex.") { return .structure }
            if relative == "info/exclude" || relative == "info/attributes" { return .workingTree }
            return nil
        }
        let root = worktreePath
        if path == root || path == root + "/.git" || path == root + "/.gitmodules" { return .structure }
        for submodule in submodules {
            if path == submodule + "/.git" { return .structure }
            if path == submodule {
                let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink)
                return flags & structural != 0 ? .structure : nil
            }
            if path.hasPrefix(submodule + "/") { return nil }
        }
        return path.hasPrefix(root + "/") ? .workingTree : nil
    }
}
