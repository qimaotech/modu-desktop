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
    public var diagnostics: RepositoryReadDiagnostics?
    private let terminationGracePeriod: TimeInterval
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, diagnostics: RepositoryReadDiagnostics? = nil, terminationGracePeriod: TimeInterval = 5) {
        precondition(terminationGracePeriod.isFinite && terminationGracePeriod >= 0)
        self.environment = environment; self.diagnostics = diagnostics
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(_ executable: String, _ arguments: [String], at directory: URL? = nil, timeout: TimeInterval = 60, cancellable: Bool = true, input: Data? = nil) async throws -> CommandOutput {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Synchronous process polling must not occupy Swift's cooperative thread pool.
                DispatchQueue.global().async {
                    continuation.resume(with: Result {
                        try execute(executable, arguments, directory: directory, timeout: timeout, cancellation: cancellation, cancellable: cancellable, input: input)
                    })
                }
            }
        } onCancel: { if cancellable { cancellation.cancel() } }
    }

    private func execute(_ executable: String, _ arguments: [String], directory: URL?, timeout: TimeInterval, cancellation: CancellationFlag, cancellable: Bool, input: Data?) throws -> CommandOutput {
        let started = ContinuousClock.now
        var stdout = Data(), stderr = Data()
        defer { diagnostics?.record(commandMetric(executable, arguments), duration: started.duration(to: .now), bytes: stdout.count + stderr.count) }
        if cancellable && cancellation.cancelled { throw MonoDeckError("cancelled", .operationCancelled) }
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw MonoDeckError("process-failed", .couldNotCreateOutputPipe) }
        guard pipe(&err) == 0 else { close(out[0]); close(out[1]); throw MonoDeckError("process-failed", .couldNotCreateErrorPipe) }
        defer { close(out[0]); close(err[0]) }
        var inputPipe: [Int32] = [-1, -1]
        if input != nil {
            guard pipe(&inputPipe) == 0 else { close(out[1]); close(err[1]); throw MonoDeckError("process-failed", .couldNotCreateOutputPipe) }
        }
        defer { for fd in inputPipe where fd >= 0 { close(fd) } }
        for fd in out + err + inputPipe where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        if inputPipe[1] >= 0 {
            // A command may close stdin early; keep EPIPE local to this descriptor.
            guard fcntl(inputPipe[1], F_SETNOSIGPIPE, 1) == 0 else {
                close(out[1]); close(err[1])
                throw MonoDeckError("process-failed", "Could not configure command input.")
            }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        if inputPipe[0] >= 0 { posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO) }
        else { posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) }
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
        for fd in out + err + inputPipe where fd >= 0 { posix_spawn_file_actions_addclose(&actions, fd) }
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
        if inputPipe[0] >= 0 { close(inputPipe[0]); inputPipe[0] = -1 }
        guard spawnError == 0 else { throw MonoDeckError("process-failed", .couldNotLaunch(URL(fileURLWithPath: executable).lastPathComponent, .diagnostic(String(cString: strerror(spawnError))))) }
        for fd in [out[0], err[0], inputPipe[1]] where fd >= 0 { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        var inputOffset = 0
        var status: Int32 = 0
        let start = ContinuousClock.now
        var termination: ContinuousClock.Instant?
        var failure: MonoDeckError?
        var parentExited = false
        var pollInterval: useconds_t = 1_000
        while true {
            readAvailable(out[0], into: &stdout); readAvailable(err[0], into: &stderr)
            if inputPipe[1] >= 0, let input {
                if termination != nil || !writeAvailable(inputPipe[1], input: input, offset: &inputOffset) {
                    close(inputPipe[1]); inputPipe[1] = -1
                }
            }
            if !parentExited {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { parentExited = true }
                if waited == -1 && errno != EINTR { failure = MonoDeckError("process-failed", .couldNotReadProcessExitStatus); break }
            }
            if termination == nil {
                if parentExited { break }
                if cancellable && cancellation.cancelled { failure = MonoDeckError("cancelled", .operationCancelled) }
                else if start.duration(to: .now) >= .seconds(timeout) { failure = MonoDeckError("network-timeout", .commandExceededSecondTimeLimit(Int(timeout))) }
                else if stdout.count + stderr.count > 32 * 1024 * 1024 { failure = MonoDeckError("output-limit", .commandOutputExceeded32MiB) }
                if failure != nil { termination = .now; kill(-pid, SIGTERM) }
            } else {
                // Helpers can outlive the parent while remaining in its process group.
                if parentExited && !processGroupExists(pid) { break }
                if termination!.duration(to: .now) >= .seconds(terminationGracePeriod) { kill(-pid, SIGKILL) }
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

    private func writeAvailable(_ fd: Int32, input: Data, offset: inout Int) -> Bool {
        input.withUnsafeBytes { bytes in
            var budget = 64 * 1_024
            while offset < bytes.count, budget > 0 {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), min(16_384, min(bytes.count - offset, budget)))
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return true }
                guard count > 0 else { return false }
                offset += count; budget -= count
            }
            return offset < bytes.count
        }
    }

    private func commandMetric(_ executable: String, _ arguments: [String]) -> String {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard name == "git" else { return "command.\(name)" }
        var skip = false
        for argument in arguments {
            if skip { skip = false; continue }
            if argument == "-c" || argument == "-C" { skip = true; continue }
            if !argument.hasPrefix("-") { return "command.git.\(argument)" }
        }
        return "command.git"
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
