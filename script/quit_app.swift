import AppKit
import Foundation

func quitApplication() -> Int32 {
    let identity: TestHostIdentity?
    let pid: Int32
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--identity" {
        do {
            let decoded = try JSONDecoder().decode(TestHostIdentity.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            guard decoded.pid > 0 else { report("Invalid test host PID."); return 1 }
            identity = decoded; pid = decoded.pid
        } catch { report("Could not read test host identity: \(error.localizedDescription)"); return 1 }
    } else if CommandLine.arguments.count == 2, let value = Int32(CommandLine.arguments[1]), value > 0 {
        pid = value; identity = nil
    } else {
        report("usage: quit_app.swift <Modu PID> | --identity <test-host.json>")
        return 2
    }
    guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
        print("App is not running (PID \(pid)).")
        return 0
    }
    guard application.bundleIdentifier == "fun.armantang.ModuDesktop" else {
        report("Refusing to quit a non-Modu process (PID \(pid)).")
        return 1
    }
    if let identity {
        guard let executable = application.executableURL, let launchedAt = application.launchDate,
              executable.standardizedFileURL.resolvingSymlinksInPath().path == identity.executable,
              abs(launchedAt.timeIntervalSince1970 - identity.launchedAt) < 0.001 else {
            report("Refusing to quit a process whose test host identity changed (PID \(pid)).")
            return 1
        }
    }
    guard application.terminate() else {
        report("Could not request App exit (PID \(pid)).")
        return 1
    }
    let start = ContinuousClock.now
    while !application.isTerminated {
        if start.duration(to: .now) >= .seconds(15) {
            report("App did not exit within 15 seconds (PID \(pid)).")
            return 1
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    print("App exited (PID \(pid)).")
    return 0
}

struct TestHostIdentity: Decodable {
    let pid: Int32
    let launchedAt: TimeInterval
    let executable: String
    enum CodingKeys: String, CodingKey { case pid, executable; case launchedAt = "launched-at" }
}

func report(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

exit(quitApplication())
