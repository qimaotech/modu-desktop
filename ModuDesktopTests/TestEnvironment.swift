import Foundation

enum TestEnvironment {
    static var temporaryDirectory: URL {
        // Xcode may override TMPDIR after launching the hosted test process.
        if let session = ProcessInfo.processInfo.environment["MODU_TEST_SESSION_DIRECTORY"] {
            return URL(fileURLWithPath: session).appending(path: "tmp", directoryHint: .isDirectory)
        }
        return FileManager.default.temporaryDirectory
    }
}
