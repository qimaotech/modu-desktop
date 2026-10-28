import Foundation
import Darwin

public struct PreparedAppUpdate: Codable, Sendable {
    public let identifier: UUID
    public let directory: URL
    let application: URL
    let version: String
    let originalIdentity: UpdateFileIdentity
    let candidateIdentity: UpdateFileIdentity
    var candidate: URL { directory.appending(path: "Modu.app") }
    var ready: URL { directory.appending(path: "ready") }
    var cancelled: URL { directory.appending(path: "cancelled") }
    var failure: URL { directory.appending(path: "failure.json") }

    static func read(from directory: URL) throws -> PreparedAppUpdate {
        try PathSafety.directory(directory)
        let update = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appending(path: "installation.json")))
        guard PathSafety.canonical(update.directory).path == PathSafety.canonical(directory).path,
              PathSafety.canonical(directory.deletingLastPathComponent()).path == PathSafety.canonical(update.application.deletingLastPathComponent()).path,
              directory.lastPathComponent.hasPrefix(".Modu-Update-") else {
            throw ModuError("update-plan-invalid", .updateInstallationPlanIsInvalid)
        }
        return update
    }
}

public struct AppUpdateInstaller: Sendable {
    private let runner: CommandRunner
    private let exitTimeout: TimeInterval
    private static let bundleID = "fun.armantang.ModuDesktop"

    public init(runner: CommandRunner = .init(), exitTimeout: TimeInterval = 60) {
        self.runner = runner
        self.exitTimeout = exitTimeout
    }

    public func prepare(installer: URL, update: AppUpdate, application: URL, helper: URL) async throws -> PreparedAppUpdate {
        // Automatic replacement requires a checksum even for releases that support manual downloads without one.
        guard update.asset.digest != nil else { throw ModuError("update-integrity-failed", .releaseHasNoInstallerChecksum) }
        try AppUpdateService().verifyDownload(at: installer, asset: update.asset)
        let application = application.resolvingSymlinksInPath()
        try validateApplication(application)
        let originalIdentity = try UpdateFileIdentity(application)
        let directory = application.deletingLastPathComponent().appending(path: ".Modu-Update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw ModuError("update-location-unwritable", .moduCannotUpdateInLocationInstallInWritable) }
        let mount = directory.appending(path: "mount")
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
            do {
                // Let attachment finish before observing cancellation so its mount can always be detached.
                try await command("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, "-plist", installer.path], cancellable: false)
                try Task.checkCancellation()
                let source = mount.appending(path: "Modu.app")
                try validateApplication(source, version: update.version)
                let candidate = directory.appending(path: "Modu.app")
                try await command("/usr/bin/ditto", [source.path, candidate.path])
                try await verifyApplication(candidate, version: update.version)
            } catch {
                try await detach(mount)
                throw error
            }
            try await detach(mount)
            try Task.checkCancellation()
            let executable = directory.appending(path: "modu-update")
            try FileManager.default.copyItem(at: helper, to: executable)
            let prepared = PreparedAppUpdate(identifier: UUID(), directory: directory, application: application, version: update.version,
                                             originalIdentity: originalIdentity, candidateIdentity: try UpdateFileIdentity(directory.appending(path: "Modu.app")))
            try JSONEncoder().encode(prepared).write(to: directory.appending(path: "installation.json"), options: .atomic)
            return prepared
        } catch {
            if !isMounted(mount) { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    public func launch(_ update: PreparedAppUpdate, parentPID: Int32 = ProcessInfo.processInfo.processIdentifier) async throws {
        let log = update.directory.appending(path: "installer.log")
        let result = try await runner.run("/bin/sh", ["-c", "/usr/bin/nohup \"$1\" --internal-install-update \"$2\" \"$3\" </dev/null >>\"$4\" 2>&1 &",
                                                     "modu-update", update.directory.appending(path: "modu-update").path, update.directory.path, String(parentPID), log.path], cancellable: false)
        guard result.status == 0 else { throw ModuError("update-helper-failed", .couldNotStartUpdateInstaller) }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !FileManager.default.fileExists(atPath: update.ready.path) {
                guard ContinuousClock.now < deadline else { throw ModuError("update-helper-failed", .updateInstallerDidNotBecomeReadyPleaseTry) }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            try? Data().write(to: update.cancelled)
            throw error
        }
    }

    public func discard(_ update: PreparedAppUpdate) {
        try? FileManager.default.removeItem(at: update.directory)
    }

    public func cancelHandoff(_ update: PreparedAppUpdate) {
        try? Data().write(to: update.cancelled)
    }

    public func run(directory: URL, parentPID: Int32) async throws {
        let update = try PreparedAppUpdate.read(from: directory)
        guard parentPID > 1, parentPID != getpid() else {
            throw ModuError("update-plan-invalid", .updateInstallationPlanIsInvalid)
        }
        do {
            try await waitForExit(parentPID, update: update)
        } catch {
            if error is CancellationError { discard(update) }
            else { try recordFailure(error, for: update) }
            throw error
        }
        do {
            try await install(update)
            try await openApplication(update.application)
            discard(update)
        } catch {
            try recordFailure(error, for: update)
            throw error
        }
    }

    private func install(_ update: PreparedAppUpdate) async throws {
        guard try UpdateFileIdentity(update.application) == update.originalIdentity,
              try UpdateFileIdentity(update.candidate) == update.candidateIdentity else {
            throw ModuError("update-application-changed", .installedApplicationOrPreparedUpdateChangedPleaseCheck)
        }
        try await verifyApplication(update.candidate, version: update.version)
        try Task.checkCancellation()
        try swap(update.candidate, update.application)
        // The atomic exchange leaves the replaced application at the candidate path.
        try? FileManager.default.removeItem(at: update.candidate)
    }

    public func waitForFailure(_ update: PreparedAppUpdate) async throws -> ModuError {
        if let failure = try failure(for: update) { return failure }
        let pid = try String(contentsOf: update.ready, encoding: .utf8)
        guard let pid = Int32(pid), pid > 1 else { throw ModuError("update-helper-failed", .updateInstallerHasNoValidProcessIdentifier) }
        let process = try ProcessExitMonitor(pid)
        while true {
            try Task.checkCancellation()
            if let failure = try failure(for: update) { return failure }
            if try process.exited() {
                if let failure = try failure(for: update) { return failure }
                throw ModuError("update-helper-failed", .updateInstallerStoppedUnexpectedlyPleaseTryAgain)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func failure(for update: PreparedAppUpdate) throws -> ModuError? {
        guard FileManager.default.fileExists(atPath: update.failure.path) else { return nil }
        guard let data = try? Data(contentsOf: update.failure), let failure = try? JSONDecoder().decode(AppUpdateFailure.self, from: data) else { return nil }
        return failure.identifier == update.identifier ? failure.error : nil
    }

    private func recordFailure(_ error: Error, for update: PreparedAppUpdate) throws {
        let failure = AppUpdateFailure(identifier: update.identifier, error: ModuError.wrap(error))
        try JSONEncoder().encode(failure).write(to: update.failure, options: .atomic)
        try? Data(error.localizedDescription.utf8).write(to: update.directory.appending(path: "error.txt"))
    }

    private func verifyApplication(_ application: URL, version: String) async throws {
        try validateApplication(application, version: version)
        try await command("/usr/bin/codesign", ["--verify", "--deep", "--strict", application.path])
        guard Bundle(url: application)?.executableArchitectures?.contains(NSNumber(value: NSBundleExecutableArchitectureARM64)) == true else {
            throw ModuError("update-application-invalid", .installerDoesNotContainAppleSiliconExecutable)
        }
    }

    private func validateApplication(_ application: URL, version: String? = nil) throws {
        try PathSafety.directory(application)
        let info = application.appending(path: "Contents/Info.plist")
        try PathSafety.confined(info, to: application)
        guard let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
              values["CFBundleIdentifier"] as? String == Self.bundleID,
              values["CFBundleExecutable"] as? String == "Modu",
              version == nil || values["CFBundleShortVersionString"] as? String == version else {
            throw ModuError("update-application-invalid", .installerDoesNotContainExpectedVersionOfModu)
        }
        for path in ["Contents/MacOS/Modu", "Contents/Resources/modu-cli"] {
            let file = application.appending(path: path)
            try PathSafety.confined(file, to: application)
            guard FileManager.default.isExecutableFile(atPath: file.path) else {
                throw ModuError("update-application-invalid", .installerIsMissingRequiredExecutable)
            }
        }
        if let minimum = values["LSMinimumSystemVersion"] as? String {
            let parts = minimum.split(separator: ".").compactMap { Int($0) }
            guard (1...3).contains(parts.count), ProcessInfo.processInfo.isOperatingSystemAtLeast(
                .init(majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0)) else {
                throw ModuError("update-system-unsupported", .updateRequiresNewerVersionOfMacOS)
            }
        }
    }

    private func detach(_ mount: URL) async throws {
        guard isMounted(mount) else { return }
        try await command("/usr/bin/hdiutil", ["detach", mount.path], cancellable: false)
    }

    private func isMounted(_ mount: URL) -> Bool {
        guard let volume = try? UpdateFileIdentity(mount), let parent = try? UpdateFileIdentity(mount.deletingLastPathComponent()) else { return false }
        return volume.device != parent.device
    }

    private func swap(_ first: URL, _ second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw ModuError("update-replacement-failed", .couldNotReplaceModu(.diagnostic(String(cString: strerror(errno)))))
        }
    }

    private func openApplication(_ application: URL) async throws {
        var arguments = ["-n"]
        #if DEBUG
        for key in ["MODU_TEST_DEFAULTS", "MODU_TEST_WORKSPACE", "MODU_TEST_SUPPORT_DIRECTORY", "MODU_TEST_HOME_DIRECTORY",
                    "MODU_TEST_LOGIN_SHELL", "MODU_UNIT_TEST_HOST", "MODU_TEST_SESSION_DIRECTORY"] {
            if let value = runner.environment[key] { arguments += ["--env", "\(key)=\(value)"] }
        }
        #endif
        try await command("/usr/bin/open", arguments + [application.path], cancellable: false)
    }

    private func command(_ executable: String, _ arguments: [String], cancellable: Bool = true) async throws {
        let output = try await runner.run(executable, arguments, timeout: 120, cancellable: cancellable)
        guard output.status == 0 else {
            throw ModuError("update-install-failed", .context(URL(fileURLWithPath: executable).lastPathComponent, .diagnostic(String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))))
        }
    }

    private func waitForExit(_ pid: Int32, update: PreparedAppUpdate) async throws {
        try await withTaskCancellationHandler {
            let process = try ProcessExitMonitor(pid)
            try Data(String(getpid()).utf8).write(to: update.ready, options: .atomic)
            let deadline = ContinuousClock.now.advanced(by: .seconds(exitTimeout))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard !FileManager.default.fileExists(atPath: update.cancelled.path), FileManager.default.fileExists(atPath: update.directory.path) else {
                    throw CancellationError()
                }
                if try process.exited() { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ModuError("update-exit-timeout", .moduDidNotExitInTimeUpdateWas)
        } onCancel: { try? Data().write(to: update.cancelled) }
    }
}

private struct AppUpdateFailure: Codable {
    let identifier: UUID
    let code: String
    let message: String
    var error: ModuError { .init(code, message) }

    init(identifier: UUID, error: ModuError) {
        self.identifier = identifier; code = error.code; message = error.message
    }
}

struct UpdateFileIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64

    init(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        device = value.st_dev; inode = value.st_ino
    }
}
