import Foundation
import Darwin

struct WorktreeRemoval: Sendable {
    let runner: CommandRunner
    var temporaryDirectory = WorktreeCleanup.temporaryDirectory
    var helper = Bundle.main.url(forResource: "mono-deck", withExtension: nil)
        ?? Bundle.main.executableURL.flatMap { $0.lastPathComponent == "mono-deck" ? $0 : nil }
    var isInternalLocalVolume: @Sendable (URL) throws -> Bool = { path in
        let values = try path.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey])
        return values.volumeIsLocal == true && values.volumeIsInternal == true
    }

    func canStage(_ path: URL) -> Bool {
        guard let helper, FileManager.default.isExecutableFile(atPath: helper.path),
              (try? isInternalLocalVolume(path)) == true else { return false }
        var source = stat(), temporary = stat()
        return lstat(path.path, &source) == 0 && source.st_mode & S_IFMT == S_IFDIR
            && stat(temporaryDirectory.path, &temporary) == 0 && source.st_dev == temporary.st_dev
    }
}

struct WorktreeRemovalBatch {
    let removal: WorktreeRemoval
    private(set) var directory: URL?
    private var ready: [String] = []

    init(removal: WorktreeRemoval) { self.removal = removal }

    mutating func stage(_ path: URL) -> URL? {
        guard removal.canStage(path) else { return nil }
        if directory == nil {
            let candidate = removal.temporaryDirectory.appending(path: WorktreeCleanup.prefix + UUID().uuidString)
            guard mkdir(candidate.path, 0o700) == 0 else { return nil }
            directory = candidate
        }
        let destination = directory!.appending(path: UUID().uuidString)
        // Unlike a cross-volume move, rename never copies the dependency tree.
        guard renamex_np(path.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { return nil }
        return destination
    }

    mutating func didUnregister(_ path: URL) { ready.append(path.lastPathComponent) }

    func finish() async {
        guard let directory else { return }
        guard !ready.isEmpty, let helper = removal.helper else {
            _ = rmdir(directory.path)
            return
        }
        do {
            let output = try await removal.runner.run("/bin/sh", ["-c",
                "log=$1; shift; /usr/bin/nohup \"$@\" </dev/null >\"$log\" 2>&1 &", "mono-deck-worktree-cleanup",
                directory.appending(path: "cleanup.log").path, helper.path, "--internal-cleanup-worktrees", directory.path] + ready,
                cancellable: false)
            guard output.status == 0 else { throw MonoDeckError("cleanup-failed", "Could not start worktree cleanup.") }
        } catch {
            fputs("MonoDeck worktree cleanup could not start; files remain at \(directory.path): \(error)\n", stderr)
        }
    }
}

public enum WorktreeCleanup {
    static let prefix = "mono-deck-worktree-removal-"
    static var temporaryDirectory: URL {
        #if DEBUG
        if let session = ProcessInfo.processInfo.environment["MONO_DECK_TEST_SESSION_DIRECTORY"] {
            return URL(fileURLWithPath: session).appending(path: "tmp", directoryHint: .isDirectory)
        }
        #endif
        return FileManager.default.temporaryDirectory
    }

    public static func run(directory: URL, entries: [String], runner: CommandRunner = .init()) async throws {
        let directory = PathSafety.canonical(directory)
        try PathSafety.confined(directory, to: PathSafety.canonical(temporaryDirectory))
        guard directory.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil,
              !entries.isEmpty, entries.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw MonoDeckError("invalid-input", "Invalid worktree cleanup directory or entries.")
        }
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700 else {
            throw MonoDeckError("unsafe-path", "Expected a private worktree cleanup directory.")
        }
        let lock = directory.deletingLastPathComponent().appending(path: ".mono-deck-worktree-cleanup.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        // Helpers survive their callers; serialize disk cleanup across App and CLI processes.
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        let output = try await runner.run("/bin/rm", ["-rf", "--"] + entries.map { directory.appending(path: $0).path }, timeout: 24 * 60 * 60, cancellable: false)
        guard output.status == 0 else {
            throw MonoDeckError("cleanup-failed", "Worktree files remain at \(directory.path): \(String(decoding: output.stderr, as: UTF8.self))")
        }
        try? FileManager.default.removeItem(at: directory.appending(path: "cleanup.log"))
        // A failed Git unregister may have left another entry; keep it intact.
        _ = rmdir(directory.path)
    }
}
