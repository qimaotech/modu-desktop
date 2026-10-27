import Foundation
import Darwin

public struct CommandOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public var text: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
}

public struct CommandRunner: Sendable {
    public var environment: [String: String]
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) { self.environment = environment }

    public func run(_ executable: String, _ arguments: [String], at directory: URL? = nil, timeout: TimeInterval = 60, cancellable: Bool = true) async throws -> CommandOutput {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Synchronous process polling must not occupy Swift's cooperative thread pool.
                DispatchQueue.global().async {
                    continuation.resume(with: Result {
                        try execute(executable, arguments, directory: directory, timeout: timeout, cancellation: cancellation, cancellable: cancellable)
                    })
                }
            }
        } onCancel: { if cancellable { cancellation.cancel() } }
    }

    private func execute(_ executable: String, _ arguments: [String], directory: URL?, timeout: TimeInterval, cancellation: CancellationFlag, cancellable: Bool) throws -> CommandOutput {
        if cancellable && cancellation.cancelled { throw ModuError("cancelled", .operationCancelled) }
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw ModuError("process-failed", .couldNotCreateOutputPipe) }
        guard pipe(&err) == 0 else { close(out[0]); close(out[1]); throw ModuError("process-failed", .couldNotCreateErrorPipe) }
        defer { close(out[0]); close(err[0]) }
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
        for fd in out + err { posix_spawn_file_actions_addclose(&actions, fd) }
        if let directory { posix_spawn_file_actions_addchdir(&actions, directory.path) }
        var defaults = sigset_t(); sigemptyset(&defaults)
        for value in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&defaults, value) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t(); sigemptyset(&mask); posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnError = argv.withUnsafeBufferPointer { a in
            envp.withUnsafeBufferPointer { e in
                posix_spawn(&pid, executable, &actions, &attributes, a.baseAddress!, e.baseAddress!)
            }
        }
        close(out[1]); close(err[1])
        guard spawnError == 0 else { throw ModuError("process-failed", .couldNotLaunch(URL(fileURLWithPath: executable).lastPathComponent, .diagnostic(String(cString: strerror(spawnError))))) }
        for fd in [out[0], err[0]] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        var stdout = Data(), stderr = Data(), status: Int32 = 0
        let start = ContinuousClock.now
        var termination: ContinuousClock.Instant?
        var failure: ModuError?
        var parentExited = false
        var pollInterval: useconds_t = 1_000
        while true {
            readAvailable(out[0], into: &stdout); readAvailable(err[0], into: &stderr)
            if !parentExited {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { parentExited = true }
                if waited == -1 && errno != EINTR { failure = ModuError("process-failed", .couldNotReadProcessExitStatus); break }
            }
            if termination == nil {
                if parentExited { break }
                if cancellable && cancellation.cancelled { failure = ModuError("cancelled", .operationCancelled) }
                else if start.duration(to: .now) >= .seconds(timeout) { failure = ModuError("network-timeout", .commandExceededSecondTimeLimit(Int(timeout))) }
                else if stdout.count + stderr.count > 32 * 1024 * 1024 { failure = ModuError("output-limit", .commandOutputExceeded32MiB) }
                if failure != nil { termination = .now; kill(-pid, SIGTERM) }
            } else {
                // Helpers can outlive the parent while remaining in its process group.
                if parentExited && !processGroupExists(pid) { break }
                if termination!.duration(to: .now) >= .seconds(5) { kill(-pid, SIGKILL) }
            }
            usleep(pollInterval)
            pollInterval = min(pollInterval * 2, 20_000)
        }
        // A detached helper may retain the pipe. Drain available bytes, never wait for its EOF.
        readAvailable(out[0], into: &stdout); readAvailable(err[0], into: &stderr)
        if let failure { throw failure }
        let exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return CommandOutput(status: exitStatus, stdout: stdout, stderr: stderr)
    }

    private func processGroupExists(_ pid: pid_t) -> Bool {
        kill(-pid, 0) == 0 || errno != ESRCH
    }

    private func readAvailable(_ fd: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= 32 * 1024 * 1024 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}
