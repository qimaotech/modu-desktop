import Foundation
import ModuCore

struct InterfaceText {
    let locale: AppLocale

    func string(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = locale.locale
        return String(localized: resource)
    }

    func number(_ value: Int) -> String { value.formatted(.number.locale(locale.locale)) }

    func message(_ error: Error) -> String { message(ModuError.wrap(error).userMessage) }

    func message(_ item: ItemResult) -> String {
        guard let value = item.userMessage ?? item.message.map(UserMessage.diagnostic) else { return "" }
        return message(value)
    }

    func message(_ result: OperationResult) -> String {
        guard let value = result.userMessage ?? result.message.map(UserMessage.diagnostic) else { return "" }
        return message(value)
    }

    func baseBranchHelp(_ summary: GitSummary) -> String {
        guard let overview = summary.baseMessage.map(message), !overview.isEmpty else { return summary.baseError ?? "" }
        guard let diagnostic = summary.baseError, !diagnostic.isEmpty, diagnostic != overview else { return overview }
        return overview + "\n\n" + diagnostic
    }

    func resultTitle(_ result: OperationResult) -> String {
        if result.command == "workspace.open", result.status != .success { return string(.uiCanTOpenWorkspace) }
        if result.command == "repo.add", result.status == .failed {
            if result.items.first?.data?["disposition"] == "added" { return string(.uiRepositoryAddedWithIssue) }
            return string(.uiCanTAddRepository)
        }
        if result.status == .skipped, result.command == "repo.import-yaml" { return string(.uiNoRepositoriesWereAdded) }
        let tasks: [String: LocalizedStringResource] = [
            "repo.add": .uiRepositoryAddition, "repo.update": .uiRepositoryUpdate,
            "repo.remove": .uiRepositoryDeletion, "repo.import-yaml": .uiRepositoryImport,
            "workspace.import-yaml": .uiWorkspaceImport, "workspace.open": .uiWorkspaceOpening,
            "workspace.inspect": .uiResourceCheck, "worktree.create": .uiGroupCreation,
            "worktree.update": .uiGroupUpdate, "worktree.remove": .uiWorktreeDeletion,
            "cli.install": .uiCliInstallation
        ]
        let task = tasks[result.command] ?? .uiOperation
        let status: String
        if result.status == .success, result.hasWarnings { status = "completed-with-warnings" }
        else { status = result.status.rawValue }
        return string(task) + " · " + statusText(status)
    }

    func resultSummaryText(_ result: OperationResult) -> String? {
        let items = resultDisplayItems(result)
        guard items.count > 1 else { return nil }
        var counts: [String: Int] = [:]
        for item in items {
            let status: String
            if result.command == "repo.update" { status = item.status == .success ? "updated" : "failed" }
            else if item.reasonCode == "not-processed" { status = "not-processed" }
            else if item.status == .success, item.hasWarning { status = "warning" }
            else { status = item.status.rawValue }
            counts[status, default: 0] += 1
        }
        return ["warning", "updated", "success", "skipped", "failed", "cancelled", "not-processed"].compactMap { status in
            guard let count = counts[status], count > 0 else { return nil }
            let label: String
            if status == "warning" { label = string(.uiWarnings) }
            else { label = statusText(status == "success" && result.command == "repo.import-yaml" ? "added" : status) }
            return label + " " + number(count)
        }.joined(separator: " · ")
    }

    func resultDisplayItems(_ result: OperationResult) -> [ItemResult] {
        if result.command == "repo.update" {
            return result.items.filter { $0.status == .failed || ($0.status == .success && $0.data?["disposition"] == "updated") }
        }
        guard result.status != .success || result.hasWarnings else { return result.items }
        return result.items.filter { $0.status != .success || $0.hasWarning }
    }

    func fileStatus(_ code: String) -> String {
        switch code {
        case "A", "C", "R", "M", "T", "D", "?", "U", " ", ".": return statusText(FileChange.label(code))
        default: return string(.uiUnknown(code))
        }
    }

    func statusText(_ value: String) -> String {
        let labels: [String: LocalizedStringResource] = [
            "success": .uiCompleted, "partial-success": .uiPartiallyCompleted,
            "failed": .uiFailed2, "skipped": .uiSkipped2, "cancelled": .uiCancelled,
            "confirmation-required": .uiConfirmationRequired,
            "completed-with-warnings": .uiCompletedWithWarnings,
            "not-processed": .uiNotProcessed,
            "added": .uiAdded, "already-exists": .uiAlreadyExists, "updated": .uiUpdated,
            "Clean": .uiClean, "Dirty": .uiDirty, "Other": .uiOther, "Unset": .uiUnset,
            "Added": .uiAdded2, "Moved": .uiMoved, "Modified": .uiModified, "Deleted": .uiDeleted, "Untracked": .uiUntracked, "Conflict": .uiConflict,
            "Checking repository…": .uiCheckingRepository, "Cloning…": .uiCloning,
            "Opening workspace…": .uiOpeningWorkspace,
            "Updating repositories…": .uiUpdatingRepositories2,
            "Scanning local repositories…": .uiScanningLocalRepositories,
            "Creating…": .uiCreating, "Creating workspace worktree…": .uiCreatingWorkspaceWorktree,
            "Saving…": .uiSaving, "Cleaning up…": .uiCleaningUp, "Deleting…": .uiDeleting,
            "Importing repositories…": .uiImportingRepositories, "Created": .uiCreated,
            "update-ignore": .uiUpdatedGitignore, "git-init": .uiInitializedGit,
            "install-skill": .uiInstalledWorkflowSkill, "commit-workspace-files": .uiCommittedWorkspaceFiles,
            "install-cli": .uiInstalledCLI,
            "stash-workspace": .uiStashedWorkspaceChanges, "restore-workspace": .uiRestoredWorkspaceChanges,
            "discard-workspace-file-changes": .uiDiscardedManagedFileChanges,
            "create-directory": .uiCreatedDirectory, "save-configuration": .uiSavedConfiguration,
            "clone": .uiClone, "create-worktree": .uiCreateWorktree, "create-branch": .uiCreateBranch,
            "remove-worktree": .uiRemoveWorktree, "remove-declaration": .uiRemoveDeclaration, "delete-branch": .uiDeleteBranch,
            "move-to-trash": .uiMoveTrash, "update-refs": .uiUpdateRefs, "fast-forward": .uiFastForward,
            "applied": .uiApplied, "reverted": .uiCleanedUp, "unknown": .uiUnconfirmed,
            "Agent": .uiAgent, "Git GUI": .uiGitGUI, "Editor": .uiEditor, "Terminal": .uiTerminal
        ]
        guard let label = labels[value] else { return value }
        return string(label)
    }
    func resultStatus(_ item: ItemResult) -> String {
        if item.reasonCode == "not-processed" { return statusText("not-processed") }
        guard let disposition = item.data?["disposition"], disposition != item.status.rawValue else { return statusText(item.status.rawValue) }
        if item.status == .success { return statusText(disposition) }
        return statusText(item.status.rawValue) + " · " + statusText(disposition)
    }
    func resultMessage(_ item: ItemResult, overallMessage: String?, command: String? = nil) -> String? {
        guard let raw = item.message, !raw.isEmpty,
              ![overallMessage, item.status.rawValue, item.data?["disposition"]].contains(raw) else { return nil }
        if item.status == .success, let branch = item.data?["reused-branch"], let comparison = item.data?["comparison-base"] {
            let base = item.resource.kind == .group ? string(.uiWorkspaceHEAD) : comparison
            if item.data?["warning-code"] == "branch-behind-base", let value = item.data?["behind-count"], let count = Int(value) {
                return string(.uiReusedBranchIsCommitsBehindCommitsWereKept(branch, count, base))
            }
        }
        return message(item)
    }
    func effectSummaries(_ item: ItemResult, workspace: String?) -> [String] {
        let fullPath = workspace.map { URL(fileURLWithPath: $0).appending(path: item.resource.path).path }
        return Dictionary(grouping: item.effects, by: \.state).sorted { $0.key < $1.key }.map { state, effects in
            let actions = effects.map { effect in
                let repeatsPath = !effect.action.hasSuffix("-branch") && (effect.target == item.resource.path || effect.target == fullPath)
                let target = repeatsPath ? "" : ": \(effect.target)"
                return statusText(effect.action) + target
            }
            return statusText(state) + ": " + actions.joined(separator: "; ")
        }
    }
}
