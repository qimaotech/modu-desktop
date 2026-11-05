import Foundation
import MonoDeckCore
import Observation

@MainActor @Observable
final class SetupModel {
    private let model: AppModel
    private var initialCheckCompleted = false
    private var checkedWorkspace: String?
    private var selectionWorkspace: String?
    var isPreparedForCurrentWorkspace: Bool {
        initialCheckCompleted && checkedWorkspace == model.defaults.string(forKey: "workspace")
    }
    var canSelectWorkspace: Bool {
        (!working || cliActivity == .checking) && !settingUp && !model.busy
            && !model.presentation.quitPending && model.presentation.result == nil
    }
    var canContinueSetup: Bool {
        canSelectWorkspace && cliReady && cliActivity == nil && !working && selectedWorkspace != nil
            && selectionWorkspace == model.defaults.string(forKey: "workspace")
    }
    private(set) var cliReady = false
    private(set) var cliPreviouslyInstalled = false
    private(set) var cliMessage = ""
    private(set) var cliUserMessage: UserMessage?
    private(set) var selectedWorkspace: URL?
    private(set) var working = false
    private(set) var cliActivity: CLIActivity? = .checking
    private(set) var settingUp = false
    private(set) var error: String?
    private(set) var errorDetails: String?
    private(set) var skillConflict = false

    init(model: AppModel) {
        self.model = model
        selectionWorkspace = model.defaults.string(forKey: "workspace")
        cliPreviouslyInstalled = model.hasSavedWorkspace || PathSafety.exists(model.installer.commandLink)
        if let check = model.startupCLIInstallation {
            applyCLIInstallation(check)
            cliActivity = nil
        }
    }

    func check() async {
        guard !working, !isPreparedForCurrentWorkspace, !model.presentation.quitPending else { return }
        initialCheckCompleted = false
        working = true
        defer { cliActivity = nil; working = false }
        while !Task.isCancelled {
            let workspace = model.defaults.string(forKey: "workspace")
            synchronizeSelection()
            cliActivity = .checking
            cliReady = false; cliMessage = ""; cliUserMessage = nil
            let check: CLIInstallation
            if let startup = model.takeStartupCLIInstallation() {
                check = startup
            } else {
                check = await model.installer.checkCLI()
            }
            guard !Task.isCancelled, !model.presentation.quitPending else { return }
            applyCLIInstallation(check)
            cliPreviouslyInstalled = model.hasSavedWorkspace || PathSafety.exists(model.installer.commandLink)
            guard workspace == model.defaults.string(forKey: "workspace") else { continue }
            checkedWorkspace = workspace
            initialCheckCompleted = true
            return
        }
    }

    func windowClosed() { initialCheckCompleted = false }

    func install() {
        guard !working, cliActivity == nil, !model.busy, !model.presentation.quitPending, model.presentation.result == nil else { return }
        working = true; cliActivity = .installing
        cliReady = false; cliMessage = ""; cliUserMessage = nil
        model.runSetupOperation { [self] in
            var outcome = OperationResult(command: "cli.install", workspace: nil)
            defer {
                cliPreviouslyInstalled = cliPreviouslyInstalled || PathSafety.exists(model.installer.commandLink)
                cliActivity = nil; working = false
            }
            do {
                let check = try await model.installer.installCLI()
                applyCLIInstallation(check)
                outcome.status = check.available ? .success : .failed; outcome.message = check.message; outcome.userMessage = check.userMessage
                cliActivity = nil
                if check.available { synchronizeSelection() }
            } catch {
                let failure = MonoDeckError.wrap(error)
                cliReady = false; cliMessage = Git.sanitize(failure.message); cliUserMessage = failure.userMessage
                outcome.status = Task.isCancelled ? .cancelled : .failed
                outcome.message = error.localizedDescription; outcome.userMessage = failure.userMessage
            }
            if PathSafety.exists(model.installer.commandLink) {
                var item = ItemResult(.cli(path: model.installer.commandLink.path), status: outcome.status)
                item.effects = [.init("install-cli", model.installer.commandLink.path, state: cliReady ? "applied" : "unknown")]; outcome.items = [item]
            }
            return outcome
        }
    }
    func selectWorkspace(_ url: URL) {
        guard canSelectWorkspace else { return }
        synchronizeSelection()
        selectedWorkspace = url.standardizedFileURL
        clearWorkspaceError()
    }
    func continueSetup(onReady: @escaping @MainActor () -> Void) {
        guard canContinueSetup, let root = selectedWorkspace else { return }
        working = true; settingUp = true; error = nil; errorDetails = nil
        model.runSetupOperation { [self] in
            let skill = skillConflict ? nil : Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "mono-deck-workflow")
            let opened = await model.service.openWorkspaceWithRecord(root, skill: skill, installer: model.installer, recoverUnregisteredResources: true)
            var outcome = opened.result
            defer { settingUp = false; working = false }
            if outcome.status != .success {
                let text = model.presentation.text
                error = (outcome.message.map { _ in text.message(outcome) }.map { [$0] } ?? []) .joined(separator: "\n") + outcome.items.map { text.message($0) + "\n" + text.effectSummaries($0, workspace: outcome.workspace).joined(separator: "\n") }.joined(separator: "\n")
                errorDetails = Git.sanitize(([outcome.message].compactMap { $0 } + outcome.items.compactMap(\.message)).joined(separator: "\n"))
                return outcome
            }
            if Task.isCancelled { outcome.status = .cancelled; return outcome }
            if !skillConflict {
                if let error = opened.skillError ?? (skill == nil ? MonoDeckError("skill-unavailable", .bundledSkillIsUnavailable) : nil) {
                    presentError(error); skillConflict = true; return outcome
                }
            }
            guard !model.presentation.quitPending else { return outcome }
            do {
                try await model.completeSetup(root, loaded: opened.record)
                onReady()
            } catch {
                presentError(error)
                outcome.items.append(ItemResult(.workspace(path: root.path), status: .failed, error: .wrap(error)))
                outcome.summarize()
            }
            return outcome
        }
    }

    private func synchronizeSelection() {
        let workspace = model.defaults.string(forKey: "workspace")
        if selectionWorkspace != workspace {
            selectionWorkspace = workspace
            selectedWorkspace = nil
            clearWorkspaceError()
        }
        guard selectedWorkspace == nil, let path = workspace else { return }
        selectedWorkspace = URL(fileURLWithPath: path).standardizedFileURL
    }

    private func clearWorkspaceError() {
        error = nil; errorDetails = nil; skillConflict = false
    }

    private func applyCLIInstallation(_ check: CLIInstallation) {
        cliReady = check.available; cliMessage = check.message; cliUserMessage = check.userMessage
    }

    private func presentError(_ failure: Error) {
        error = model.text.message(failure)
        errorDetails = Git.sanitize(failure.localizedDescription)
    }

    enum CLIActivity { case checking, installing }
}
