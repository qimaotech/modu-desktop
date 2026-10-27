import Foundation
import AppKit
import ModuCore

extension AppModel {
    static func launch() -> AppModel {
        do {
            try TestHost.registerIfNeeded()
            return try makeForLaunch(arguments: ProcessInfo.processInfo.arguments)
        }
        catch {
            FileHandle.standardError.write(Data("Modu: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    static func makeForLaunch(arguments: [String]) throws -> AppModel {
        guard let index = arguments.firstIndex(of: "--mock") else {
            guard !arguments.contains("--mock-workspace") else { throw ModuError("invalid-input", .mockWorkspaceRequiresMock) }
            return AppModel()
        }
        #if DEBUG
        guard arguments.filter({ $0 == "--mock" }).count == 1, index + 1 < arguments.count,
              let scenario = MockWorkspace.Scenario(rawValue: arguments[index + 1]),
              arguments.filter({ $0 == "--mock-workspace" }).count == 1,
              let workspaceIndex = arguments.firstIndex(of: "--mock-workspace"), workspaceIndex + 1 < arguments.count,
              arguments[workspaceIndex + 1].hasPrefix("/") else {
            throw ModuError("invalid-input", .useBuildScriptPrepareMockLinkedWorktreeSelected)
        }
        return try MockWorkspace(scenario: scenario, workspace: URL(fileURLWithPath: arguments[workspaceIndex + 1])).makeModel()
        #else
        throw ModuError("debug-only", .mockScenariosAreOnlyAvailableInDebugBuilds)
        #endif
    }
}
