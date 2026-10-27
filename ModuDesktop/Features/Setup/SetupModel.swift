import Foundation
import ModuCore
import Observation

@MainActor @Observable
final class SetupModel {
    private let model: AppModel
    private(set) var cliReady = false
    private(set) var cliPreviouslyInstalled = false
    private(set) var cliMessage = ""
    private(set) var candidate: URL?
    private var candidateRequiresExistingRecord = false
    private(set) var working = false
    private(set) var cliActivity: CLIActivity? = .checking
    private(set) var settingUp = false
    private(set) var error: String?
    private(set) var skillConflict = false

    init(model: AppModel) { self.model = model }

    func check() async {
        guard !working else { return }
        candidate = nil; candidateRequiresExistingRecord = false
        error = nil; skillConflict = false
        working = true; cliActivity = .checking
        defer { cliActivity = nil; working = false }
        let check = await model.installer.checkCLI()
        guard !Task.isCancelled else { return }
        cliReady = check.available; cliMessage = check.message
        cliPreviouslyInstalled = model.hasSavedWorkspace || PathSafety.exists(model.installer.commandLink)
        cliActivity = nil
        await restoreSavedCandidate()
    }

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
                cliReady = check.available; cliMessage = check.message
                outcome.status = check.available ? .success : .failed; outcome.message = check.message
                cliActivity = nil
                if check.available { await restoreSavedCandidate() }
            } catch { self.error = error.localizedDescription; outcome.status = Task.isCancelled ? .cancelled : .failed; outcome.message = error.localizedDescription }
            if PathSafety.exists(model.installer.commandLink) {
                var item = ItemResult(.cli(path: model.installer.commandLink.path), status: outcome.status)
                item.effects = [.init("install-cli", model.installer.commandLink.path, state: cliReady ? "applied" : "unknown")]; outcome.items = [item]
            }
            return outcome
        }
    }
    func checkCandidate(_ url: URL, requireExistingRecord: Bool = false) async {
        working = true; error = nil; skillConflict = false; candidate = nil
        candidateRequiresExistingRecord = requireExistingRecord
        defer { working = false }
        do {
            let checked = try await model.service.candidate(url, requireExistingRecord: requireExistingRecord)
            guard !Task.isCancelled else { return }
            candidate = checked
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func continueSetup(onReady: @escaping @MainActor () -> Void) {
        guard !working, !model.busy, !model.presentation.quitPending, model.presentation.result == nil, let candidate else { return }
        working = true; settingUp = true; error = nil
        model.runSetupOperation { [self] in
            let skill = skillConflict ? nil : Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "modu-workflow")
            let opened = await model.service.openWorkspaceWithRecord(candidate, skill: skill, installer: model.installer, requireExistingRecord: candidateRequiresExistingRecord)
            var outcome = opened.result
            defer { settingUp = false; working = false }
            if outcome.status != .success {
                let text = model.presentation.text
                error = (outcome.message.map { [text.message($0)] } ?? []) .joined(separator: "\n") + outcome.items.map { text.message($0.message ?? "") + "\n" + text.effectSummaries($0, workspace: outcome.workspace).joined(separator: "\n") }.joined(separator: "\n")
                return outcome
            }
            if Task.isCancelled { outcome.status = .cancelled; return outcome }
            if !skillConflict {
                if let error = opened.skillError ?? (skill == nil ? ModuError("skill-unavailable", "Bundled skill is unavailable.") : nil) {
                    self.error = model.presentation.text.message(error.localizedDescription); skillConflict = true; return outcome
                }
            }
            guard !model.presentation.quitPending else { return outcome }
            do {
                try await model.completeSetup(candidate, loaded: opened.record)
                onReady()
            } catch {
                self.error = error.localizedDescription
                outcome.items.append(ItemResult(.workspace(path: candidate.path), status: .failed, error: .wrap(error)))
                outcome.summarize()
            }
            return outcome
        }
    }

    private func restoreSavedCandidate() async {
        guard candidate == nil, let path = model.defaults.string(forKey: "workspace") else { return }
        await checkCandidate(URL(fileURLWithPath: path), requireExistingRecord: true)
    }

    enum CLIActivity { case checking, installing }
}
