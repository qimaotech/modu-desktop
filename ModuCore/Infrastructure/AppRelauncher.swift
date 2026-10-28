import Foundation
import Darwin

public struct AppRelaunch: Sendable {
    let directory: URL
    var ready: URL { directory.appending(path: "ready") }
    var cancelled: URL { directory.appending(path: "cancelled") }
    var failure: URL { directory.appending(path: "failure") }
}

public struct AppRelauncher: Sendable {
    private let runner: CommandRunner
    private let readinessTimeout: TimeInterval
    private let exitTimeout: TimeInterval

    public init(runner: CommandRunner = .init(), readinessTimeout: TimeInterval = 10, exitTimeout: TimeInterval = 60) {
        self.runner = runner
        self.readinessTimeout = readinessTimeout
        self.exitTimeout = exitTimeout
    }

    public func launch(application: URL, helper: URL, arguments: [String] = [], environment: [String: String] = [:],
                       parentPID: Int32 = ProcessInfo.processInfo.processIdentifier) async throws -> AppRelaunch {
        let relaunch = AppRelaunch(directory: FileManager.default.temporaryDirectory.appending(path: "modu-relaunch-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: relaunch.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var runner = runner
            runner.environment.merge(environment) { _, new in new }
            let output = try await runner.run("/bin/sh", ["-c", "/usr/bin/nohup \"$@\" </dev/null >/dev/null 2>&1 &", "modu-relaunch",
                                                        helper.path, "--internal-relaunch", application.path, relaunch.directory.path, String(parentPID)] + arguments,
                                              cancellable: false)
            guard output.status == 0 else { throw ModuError("relaunch-failed", "Could not start the relaunch helper.") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(readinessTimeout))
            while !FileManager.default.fileExists(atPath: relaunch.ready.path) {
                if let failure = failure(for: relaunch) { throw failure }
                guard ContinuousClock.now < deadline else { throw ModuError("relaunch-failed", "The relaunch helper did not become ready.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            return relaunch
        } catch {
            discard(relaunch)
            throw error
        }
    }

    public func run(application: URL, directory: URL, parentPID: Int32, arguments: [String]) async throws {
        guard parentPID > 1, parentPID != getpid() else { throw ModuError("invalid-input", "Invalid relaunch parent process.") }
        let prefix = "modu-relaunch-"
        guard directory.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil else {
            throw ModuError("invalid-input", "Invalid relaunch directory.")
        }
        try PathSafety.directory(directory)
        let relaunch = AppRelaunch(directory: directory)
        do {
            let process = try ProcessExitMonitor(parentPID)
            try Data(String(getpid()).utf8).write(to: relaunch.ready, options: .atomic)
            let deadline = ContinuousClock.now.advanced(by: .seconds(exitTimeout))
            while true {
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: directory.path), !FileManager.default.fileExists(atPath: relaunch.cancelled.path) else { throw CancellationError() }
                if try process.exited() { break }
                guard ContinuousClock.now < deadline else { throw ModuError("relaunch-failed", "Modu did not exit in time. Please restart it manually.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            var openArguments = ["-n"]
            #if DEBUG
            for key in ["MODU_TEST_DEFAULTS", "MODU_TEST_WORKSPACE", "MODU_TEST_SUPPORT_DIRECTORY", "MODU_TEST_HOME_DIRECTORY",
                        "MODU_TEST_LOGIN_SHELL", "MODU_UNIT_TEST_HOST", "MODU_TEST_SESSION_DIRECTORY"] {
                if let value = runner.environment[key] { openArguments += ["--env", "\(key)=\(value)"] }
            }
            #endif
            openArguments.append(application.path)
            if !arguments.isEmpty { openArguments += ["--args"] + arguments }
            let output = try await runner.run("/usr/bin/open", openArguments, cancellable: false)
            guard output.status == 0 else { throw ModuError("relaunch-failed", "Could not reopen Modu: \(String(decoding: output.stderr, as: UTF8.self))") }
            discard(relaunch)
        } catch {
            if error is CancellationError { discard(relaunch) }
            else { try? Data(Git.sanitize(error.localizedDescription).utf8).write(to: relaunch.failure, options: .atomic) }
            throw error
        }
    }

    public func waitForFailure(_ relaunch: AppRelaunch) async throws -> ModuError {
        let pid = try String(contentsOf: relaunch.ready, encoding: .utf8)
        guard let pid = Int32(pid), pid > 1 else { throw ModuError("relaunch-failed", "Invalid relaunch helper process.") }
        let process = try ProcessExitMonitor(pid)
        while true {
            try Task.checkCancellation()
            if let failure = failure(for: relaunch) { return failure }
            if try process.exited() {
                return failure(for: relaunch) ?? ModuError("relaunch-failed", "The relaunch helper stopped unexpectedly.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    public func cancel(_ relaunch: AppRelaunch) {
        try? Data().write(to: relaunch.cancelled)
    }

    public func discard(_ relaunch: AppRelaunch) {
        try? FileManager.default.removeItem(at: relaunch.directory)
    }

    private func failure(for relaunch: AppRelaunch) -> ModuError? {
        (try? String(contentsOf: relaunch.failure, encoding: .utf8)).map { ModuError("relaunch-failed", $0) }
    }
}
