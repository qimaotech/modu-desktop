import Foundation
import MonoDeckCore
import Observation

@MainActor @Observable
final class SetupModel {
    private let model: AppModel
    private var initialCheckCompleted = false
    private var checkedWorkspace: String?
    var isPreparedForCurrentWorkspace: Bool {
        initialCheckCompleted && checkedWorkspace == model.defaults.string(forKey: "workspace")
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
        cliPreviouslyInstalled = model.hasSavedWorkspace || PathSafety.exists(model.installer.commandLink)
        if let check = model.startupCLIInstallation {
            applyCLIInstallation(check)
            cliActivity = nil
        }
    }

    func check() async {
        guard !working, !isPreparedForCurrentWorkspace else { return }
        initialCheckCompleted = false
        defer { cliActivity = nil; working = false }
        while !Task.isCancelled {
            let workspace = model.defaults.string(forKey: "workspace")
            selectedWorkspace = nil
            error = nil; errorDetails = nil; skillConflict = false
            working = true
            let check: CLIInstallation
            if let startup = model.takeStartupCLIInstallation() {
                check = startup
            } else {
                cliActivity = .checking
                check = await model.installer.checkCLI()
            }
            guard !Task.isCancelled else { return }
            applyCLIInstallation(check)
            cliPreviouslyInstalled = model.hasSavedWorkspace || PathSafety.exists(model.installer.commandLink)
            cliActivity = nil
            guard workspace == model.defaults.string(forKey: "workspace") else { continue }
            restoreSavedSelection()
            checkedWorkspace = workspace
            initialCheckCompleted = true
            return
        }
    }

    func windowClosed() { initialCheckCompleted = false }

    func install() {
        guard !working, !model.busy, !model.presentation.quitPending, model.presentation.result == nil else { return }
        working = true; cliActivity = .installing; error = nil
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
                if check.available { restoreSavedSelection() }
            } catch { presentError(error); outcome.status = Task.isCancelled ? .cancelled : .failed; outcome.message = error.localizedDescription; outcome.userMessage = MonoDeckError.wrap(error).userMessage }
            if PathSafety.exists(model.installer.commandLink) {
                var item = ItemResult(.cli(path: model.installer.commandLink.path), status: outcome.status)
                item.effects = [.init("install-cli", model.installer.commandLink.path, state: cliReady ? "applied" : "unknown")]; outcome.items = [item]
            }
            return outcome
        }
    }
    func selectWorkspace(_ url: URL) {
        guard !working, !model.busy, !model.presentation.quitPending, model.presentation.result == nil else { return }
        selectedWorkspace = url.standardizedFileURL
        error = nil; errorDetails = nil; skillConflict = false
    }
    func continueSetup(onReady: @escaping @MainActor () -> Void) {
        guard !working, !model.busy, !model.presentation.quitPending, model.presentation.result == nil, let root = selectedWorkspace else { return }
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

    private func restoreSavedSelection() {
        guard selectedWorkspace == nil, let path = model.defaults.string(forKey: "workspace") else { return }
        selectedWorkspace = URL(fileURLWithPath: path).standardizedFileURL
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
