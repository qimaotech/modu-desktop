import Foundation
import MonoDeckCore

enum WorkspaceActionIssue: Error {
    case noWorkspace, preparing, maintenanceFailed, recordUnavailable, busy, cancelling, quitting
    case workspaceChanged, noRepositories, targetUnavailable
    case directoryMissing(String), directoryUnreadable(String)

    var message: LocalizedStringResource {
        switch self {
        case .noWorkspace: .init("action.noWorkspace", defaultValue: "No workspace is selected. Set up a workspace first.")
        case .preparing: .init("action.preparing", defaultValue: "The workspace is being prepared. Please try again when it finishes.")
        case .maintenanceFailed: .init("action.maintenanceFailed", defaultValue: "Workspace maintenance failed. Retry maintenance before starting this operation.")
        case .recordUnavailable: .init("action.recordUnavailable", defaultValue: "The workspace record could not be read or validated. Reload the workspace and try again.")
        case .busy: .init("action.busy", defaultValue: "Another operation is in progress. Please try again when it finishes.")
        case .cancelling: .init("action.cancelling", defaultValue: "The current operation is finishing cancellation. Please try again when it finishes.")
        case .quitting: .init("action.quitting", defaultValue: "MonoDeck is quitting and cannot start a new operation.")
        case .workspaceChanged: .init("action.workspaceChanged", defaultValue: "The workspace has changed. Close this form and open it again.")
        case .noRepositories: .init("action.noRepositories", defaultValue: "Add at least one repository before creating a group.")
        case .targetUnavailable: .init("action.targetUnavailable", defaultValue: "No target directory has been loaded yet. Please select a workspace and try again.")
        case .directoryMissing(let path): .init("action.directoryMissing", defaultValue: "The target directory does not exist: \(path)")
        case .directoryUnreadable(let path): .init("action.directoryUnreadable", defaultValue: "The target directory cannot be accessed: \(path)")
        }
    }
}

func checkActionDirectory(_ directory: URL) throws {
    guard PathSafety.exists(directory) else { throw WorkspaceActionIssue.directoryMissing(directory.path) }
    try PathSafety.directory(directory)
    guard FileManager.default.isReadableFile(atPath: directory.path),
          FileManager.default.isExecutableFile(atPath: directory.path) else {
        throw WorkspaceActionIssue.directoryUnreadable(directory.path)
    }
}
