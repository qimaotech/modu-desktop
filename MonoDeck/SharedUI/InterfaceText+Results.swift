import Foundation
import MonoDeckCore

extension InterfaceText {
    func resultTitle(_ result: OperationResult) -> String {
        if result.reasonCode == "workspace-not-empty" { return string(.uiCanTImportIntoWorkspace) }
        if result.command == "repo.add", result.status == .failed,
           result.items.first?.data?["disposition"] == "added" {
            return string(.uiRepositoryAddedWithIssue)
        }
        let title: LocalizedStringResource
        if result.status == .success, result.hasWarnings {
            title = Self.resultWarningTitles[result.command] ?? .resultOperationWarnings
        } else {
            title = Self.resultTitles[result.command]?[result.status] ?? Self.defaultResultTitle(for: result.status)
        }
        return string(title)
    }

    private static let resultTitles: [String: [OperationStatus: LocalizedStringResource]] = [
        "repo.add": [
            .success: .resultRepoAddSuccess,
            .failed: .resultRepoAddFailed,
            .cancelled: .resultRepoAddCancelled
        ],
        "repo.update": [
            .success: .resultRepoUpdateSuccess,
            .partialSuccess: .resultRepoUpdatePartialSuccess,
            .failed: .resultRepoUpdateFailed,
            .skipped: .resultRepoUpdateSkipped,
            .cancelled: .resultRepoUpdateCancelled,
            .confirmationRequired: .resultRepoUpdateConfirmationRequired
        ],
        "repo.delete": [
            .success: .resultRepoDeleteSuccess,
            .partialSuccess: .resultRepoDeletePartialSuccess,
            .failed: .resultRepoDeleteFailed,
            .skipped: .resultRepoDeleteSkipped,
            .cancelled: .resultRepoDeleteCancelled,
            .confirmationRequired: .uiDeleteRepository
        ],
        "repo.import": [
            .success: .resultRepoImportSuccess,
            .partialSuccess: .resultRepoImportPartialSuccess,
            .failed: .resultRepoImportFailed,
            .skipped: .uiNoRepositoriesWereAdded,
            .cancelled: .resultRepoImportCancelled,
            .confirmationRequired: .resultRepoImportConfirmationRequired
        ],
        "workspace.configuration.import": [
            .success: .resultWorkspaceImportSuccess,
            .partialSuccess: .resultWorkspaceImportPartialSuccess,
            .failed: .resultWorkspaceImportFailed,
            .skipped: .resultWorkspaceImportSkipped,
            .cancelled: .resultWorkspaceImportCancelled,
            .confirmationRequired: .resultWorkspaceImportConfirmationRequired
        ],
        "workspace.open": [
            .success: .resultWorkspaceOpenSuccess,
            .partialSuccess: .resultWorkspaceOpenPartialSuccess,
            .failed: .resultWorkspaceOpenFailed,
            .cancelled: .resultWorkspaceOpenCancelled
        ],
        "group.create": [
            .success: .resultGroupCreateSuccess,
            .partialSuccess: .resultGroupCreatePartialSuccess,
            .failed: .resultGroupCreateFailed,
            .skipped: .resultGroupCreateSkipped,
            .cancelled: .resultGroupCreateCancelled,
            .confirmationRequired: .resultGroupCreateConfirmationRequired
        ],
        "group.edit": [
            .success: .resultGroupEditSuccess,
            .partialSuccess: .resultGroupEditPartialSuccess,
            .failed: .resultGroupEditFailed,
            .skipped: .resultGroupEditSkipped,
            .cancelled: .resultGroupEditCancelled,
            .confirmationRequired: .resultGroupEditConfirmationRequired
        ],
        "group.delete": [
            .success: .resultGroupDeleteSuccess,
            .partialSuccess: .resultGroupDeletePartialSuccess,
            .failed: .resultGroupDeleteFailed,
            .skipped: .resultGroupDeleteSkipped,
            .cancelled: .resultGroupDeleteCancelled,
            .confirmationRequired: .uiDeleteWorktreeGroup
        ],
        "group.member.delete": [
            .success: .resultMemberDeleteSuccess,
            .partialSuccess: .resultMemberDeletePartialSuccess,
            .failed: .resultMemberDeleteFailed,
            .skipped: .resultMemberDeleteSkipped,
            .cancelled: .resultMemberDeleteCancelled,
            .confirmationRequired: .uiDeleteMemberWorktree
        ],
        "cli.install": [
            .success: .resultCliInstallSuccess,
            .failed: .resultCliInstallFailed,
            .cancelled: .resultCliInstallCancelled
        ]
    ]

    private static let resultWarningTitles: [String: LocalizedStringResource] = [
        "repo.update": .resultRepoUpdateWarnings,
        "repo.delete": .resultRepoDeleteWarnings,
        "repo.import": .resultRepoImportWarnings,
        "workspace.configuration.import": .resultWorkspaceImportWarnings,
        "group.create": .resultGroupCreateWarnings,
        "group.edit": .resultGroupEditWarnings,
        "group.delete": .resultGroupDeleteWarnings,
        "group.member.delete": .resultMemberDeleteWarnings
    ]

    private static func defaultResultTitle(for status: OperationStatus) -> LocalizedStringResource {
        switch status {
        case .success: .resultOperationSuccess
        case .partialSuccess: .resultOperationPartialSuccess
        case .failed: .resultOperationFailed
        case .skipped: .resultOperationSkipped
        case .cancelled: .resultOperationCancelled
        case .confirmationRequired: .resultOperationConfirmationRequired
        }
    }
}
