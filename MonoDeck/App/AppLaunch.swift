import Foundation
import AppKit
import MonoDeckCore

extension AppModel {
    static func launch() -> AppModel {
        do {
            try TestHost.registerIfNeeded()
            return try makeForLaunch(arguments: ProcessInfo.processInfo.arguments)
        }
        catch {
            FileHandle.standardError.write(Data("MonoDeck: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    static func makeForLaunch(arguments: [String]) throws -> AppModel {
        guard let index = arguments.firstIndex(of: "--mock") else {
            guard !arguments.contains("--mock-workspace") else { throw MonoDeckError("invalid-input", .mockWorkspaceRequiresMock) }
            let diagnostics = RepositoryReadDiagnostics.fromEnvironment()
            return AppModel(cache: launchRepositoryCache(diagnostics: diagnostics), diagnostics: diagnostics)
        }
        #if DEBUG
        guard arguments.filter({ $0 == "--mock" }).count == 1, index + 1 < arguments.count,
              let scenario = MockWorkspace.Scenario(rawValue: arguments[index + 1]),
              arguments.filter({ $0 == "--mock-workspace" }).count == 1,
              let workspaceIndex = arguments.firstIndex(of: "--mock-workspace"), workspaceIndex + 1 < arguments.count,
              arguments[workspaceIndex + 1].hasPrefix("/") else {
            throw MonoDeckError("invalid-input", .useBuildScriptPrepareMockLinkedWorktreeSelected)
        }
        return try MockWorkspace(scenario: scenario, workspace: URL(fileURLWithPath: arguments[workspaceIndex + 1])).makeModel()
        #else
        throw MonoDeckError("debug-only", .mockScenariosAreOnlyAvailableInDebugBuilds)
        #endif
    }

    private static func launchRepositoryCache(diagnostics: RepositoryReadDiagnostics?) -> (any RepositoryDetailCaching)? {
        #if DEBUG
        if let session = ProcessInfo.processInfo.environment["MONO_DECK_TEST_SESSION_DIRECTORY"] {
            return RepositoryDiskCache(directory: URL(fileURLWithPath: session).appending(path: "repository-cache"), diagnostics: diagnostics)
        }
        guard !TestHost.isEnabled() else { return nil }
        let configuration = "development"
        #else
        let configuration = "production"
        #endif
        return RepositoryDiskCache(directory: URL.cachesDirectory.appending(path: "fun.armantang.MonoDeck/RepositoryCache/v2/\(configuration)"), diagnostics: diagnostics)
    }
}
