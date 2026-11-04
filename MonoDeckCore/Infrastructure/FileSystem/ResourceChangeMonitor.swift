import CoreServices
import Foundation

public struct ResourceChange: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let workingTree = Self(rawValue: 1 << 0)
    public static let summary = Self(rawValue: 1 << 1)
    public static let index = Self(rawValue: 1 << 2)
    public static let configuration = Self(rawValue: 1 << 3)
    public static let structure = Self(rawValue: 1 << 4)
}

public struct ResourceChangeEvent: Sendable {
    public static let maximumCandidateCount = 256
    public static let maximumCandidateBytes = 64 * 1_024
    public let change: ResourceChange
    public let candidatePaths: [String]

    public init(change: ResourceChange = [], candidatePaths: [String] = []) {
        self.change = change; self.candidatePaths = candidatePaths
    }
}

public protocol ResourceChangeMonitoring: AnyObject, Sendable {
    func start(_ context: ResourceReadContext, excludedDirectories: [URL], onChange: @escaping @Sendable (ResourceChangeEvent) -> Void) -> Bool
    func stop()
}

public final class ResourceChangeMonitor: ResourceChangeMonitoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "fun.armantang.MonoDeck.resource-events", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private var gitDirectories: [String] = []
    private var worktreePath = ""
    private var gitPath = ""
    private var excluded: [String] = []
    private var submodules: [String] = []
    private var onChange: (@Sendable (ResourceChangeEvent) -> Void)?

    public init() { queue.setSpecific(key: queueKey, value: true) }
    deinit { stop() }

    public func start(_ context: ResourceReadContext, excludedDirectories: [URL] = [], onChange: @escaping @Sendable (ResourceChangeEvent) -> Void) -> Bool {
        queue.sync {
            stopStream()
            self.excluded = excludedDirectories.map { PathSafety.canonical($0).path }
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
        stream = nil; onChange = nil; excluded = []; submodules = []
        gitDirectories = []; worktreePath = ""; gitPath = ""
    }

    private func receive(_ paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        guard stream != nil else { return }
        var change: ResourceChange = []
        var candidates = Set<String>()
        var candidateBytes = 0
        let uncertain = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        for index in 0..<count {
            if flags[index] & uncertain != 0 { change.insert(.structure); continue }
            let event = URL(fileURLWithPath: paths[index])
            // Removed files can arrive through a volume alias; resolve their existing parent instead of the missing leaf.
            let path = PathSafety.canonical(event.deletingLastPathComponent()).appending(path: event.lastPathComponent).path
            if excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            guard let event = classify(path, flags: flags[index]) else { continue }
            let notCandidate = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink)
            if event == .workingTree, path.hasPrefix(worktreePath + "/"),
               flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0, flags[index] & notCandidate == 0,
               !change.contains(.workingTree) {
                let relative = String(path.dropFirst(worktreePath.count + 1))
                if candidates.insert(relative).inserted { candidateBytes += relative.utf8.count + 1 }
                if candidates.count > ResourceChangeEvent.maximumCandidateCount || candidateBytes > ResourceChangeEvent.maximumCandidateBytes {
                    candidates = []; candidateBytes = 0; change.insert(.workingTree)
                }
            } else { change.formUnion(event) }
        }
        if !change.isEmpty || !candidates.isEmpty { onChange?(.init(change: change, candidatePaths: candidates.sorted())) }
    }

    private func classify(_ path: String, flags: FSEventStreamEventFlags) -> ResourceChange? {
        for directory in gitDirectories {
            if path == directory { return .structure }
            guard path.hasPrefix(directory + "/") else { continue }
            let relative = String(path.dropFirst(directory.count + 1))
            if relative.hasSuffix(".lock") || relative.hasPrefix("objects/") || relative.hasPrefix("logs/") { return nil }
            if relative == "config" || relative == "config.worktree" { return .configuration }
            if relative == "commondir" || relative == "worktrees" { return .structure }
            if relative.hasPrefix("worktrees/") {
                return relative.split(separator: "/").count <= 2 || relative.hasSuffix("/gitdir") || relative.hasSuffix("/commondir") ? .structure : nil
            }
            if directory != gitPath, relative == "HEAD" || relative == "index" { return nil }
            if relative == "reftable" || relative.hasPrefix("reftable/") { return .summary }
            if relative == "HEAD" || relative == "packed-refs" || relative == "refs" || relative.hasPrefix("refs/") || relative == "shallow" || relative == "info/grafts" { return .summary }
            if relative == "index" || relative.hasPrefix("sharedindex.") { return .index }
            if relative == "info/exclude" || relative == "info/attributes" { return [.configuration, .workingTree] }
            return nil
        }
        let root = worktreePath
        if path == root || path == root + "/.git" { return .structure }
        if path == root + "/.gitmodules" { return [.index, .workingTree] }
        for submodule in submodules {
            if path == submodule + "/.git" { return .structure }
            if path == submodule {
                let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink)
                return flags & structural != 0 ? .structure : nil
            }
            if path.hasPrefix(submodule + "/") { return nil }
        }
        guard path.hasPrefix(root + "/") else { return nil }
        if [".gitignore", ".gitattributes"].contains((path as NSString).lastPathComponent) { return [.configuration, .workingTree] }
        return .workingTree
    }
}
