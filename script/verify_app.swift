import AppKit
import Foundation

func verifyApplication() -> Int32 {
    let activates = CommandLine.arguments.dropFirst().first == "--activate"
    let arguments = Array(CommandLine.arguments.dropFirst(activates ? 2 : 1))
    guard let applicationPath = arguments.first else {
        report("usage: verify_app.swift [--activate] <App.app> [arguments]")
        return 2
    }
    let applicationURL = URL(fileURLWithPath: applicationPath).standardizedFileURL
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = activates
    configuration.promptsUserIfNeeded = false
    configuration.arguments = Array(arguments.dropFirst())
    let environment = ProcessInfo.processInfo.environment
    let keys = ["MODU_TEST_DEFAULTS", "MODU_TEST_WORKSPACE", "MODU_TEST_SUPPORT_DIRECTORY", "MODU_TEST_HOME_DIRECTORY", "MODU_TEST_LOGIN_SHELL",
                "MODU_UNIT_TEST_HOST", "MODU_TEST_SESSION_DIRECTORY"]
    let overrides = environment.filter { keys.contains($0.key) }
    if !overrides.isEmpty { configuration.environment = overrides }

    var interruption: Int32?
    let signals = [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { interruption = number }
        source.resume()
        return source
    }
    defer { signals.forEach { $0.cancel() } }

    var result: Result<NSRunningApplication, Error>?
    NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
        DispatchQueue.main.async {
            if let application { result = .success(application) }
            else { result = .failure(error ?? VerificationError("No application was launched.")) }
        }
    }
    // Keep the launch callback alive after interruption so the caller can identify its instance for cleanup.
    while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
    guard case let .success(application) = result else {
        if case let .failure(error) = result { report("App launch failed: \(error.localizedDescription)") }
        return interruption.map { 128 + $0 } ?? 1
    }

    print("App instance PID: \(application.processIdentifier)")
    fflush(stdout)

    let started = wait(timeout: 5) { application.isFinishedLaunching || application.isTerminated || interruption != nil }
        && application.isFinishedLaunching && !application.isTerminated && interruption == nil
    if started { print("App is running (PID \(application.processIdentifier)).") }
    else if interruption == nil { report("App did not finish launching within 5 seconds or exited before verification.") }

    if let interruption { return 128 + interruption }
    return started ? 0 : 1
}

func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let start = ContinuousClock.now
    while !condition() {
        if start.duration(to: .now) >= .seconds(timeout) { return false }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    return true
}

func report(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

struct VerificationError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

exit(verifyApplication())
