import SwiftUI
import AppKit
import ModuCore
import UniformTypeIdentifiers

struct SetupView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var cliReady = false
    @State private var cliMessage = ""
    @State private var candidate: URL?
    @State private var working = false
    @State var settingUp = false
    @State private var error: String?
    @State private var skillConflict = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                Text(model.t("Set Up Workspace", "设置工作区")).font(.system(size: 19, weight: .bold)).frame(maxWidth: .infinity, minHeight: 24)
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        stepGraphic("1.", icon: "ToolIcons/Terminal")
                        Text(model.t("Install modu-cli", "安装 modu-cli")).font(.system(size: 13))
                        Spacer(minLength: 8)
                        if cliReady {
                            HStack(spacing: 4) { DesignIcon(name: "Success", size: 20); Text(model.t("Installed", "已安装")).font(.system(size: 11)).foregroundStyle(DesignStyle.secondary) }
                        } else {
                            Button(model.t("Install", "安装")) { install() }.buttonStyle(.borderedProminent).disabled(working)
                        }
                    }.padding(.horizontal, 20).frame(height: 68)
                    Divider().padding(.horizontal, 20).frame(height: 11)
                    HStack(spacing: 16) {
                        stepGraphic("2.", icon: "DesignIcons/Finder").opacity(cliReady ? 1 : 0.4)
                        Text(model.t("Choose Workspace", "选择工作区")).font(.system(size: 13)).opacity(cliReady ? 1 : 0.4)
                        Spacer(minLength: 8)
                        if let candidate {
                            HStack(spacing: 4) {
                                DesignIcon(name: "Success", size: 20)
                                Text((candidate.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).help(candidate.path)
                                    .accessibilityIdentifier("workspaceCandidate").accessibilityValue(candidate.path)
                            }.frame(maxWidth: 210)
                        }
                        Button(model.t("Choose…", "选择…")) { choose() }.disabled(!cliReady || working)
                    }.padding(.horizontal, 20).frame(height: 68)
                }.formPlate()
                VStack(alignment: .leading, spacing: 8) {
                    if !cliMessage.isEmpty && !cliReady && cliMessage != "Install modu-cli to continue." { Text(cliMessage).textSelection(.enabled) }
                    if skillConflict {
                        Label(model.t("Workflow skill: Unavailable", "工作流技能：不可用"), systemImage: "exclamationmark.circle")
                    }
                    if let error { ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90) }
                    if working && !settingUp { ProgressView().controlSize(.small) }
                }.font(.system(size: 11)).foregroundStyle(DesignStyle.secondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 20)
            Divider()
            HStack {
                Button(model.hasSavedWorkspace ? model.t("Cancel", "取消") : model.t("Quit", "退出")) {
                    if model.hasSavedWorkspace { dismiss(); openWindow(id: "main") }
                    else { NSApp.terminate(nil) }
                }.disabled(working).keyboardShortcut(.cancelAction)
                Spacer()
                Button { continueSetup() } label: {
                    continueButtonLabel
                }
                .accessibilityLabel(continueButtonTitle)
                .keyboardShortcut(.defaultAction).disabled(!cliReady || candidate == nil || working)
            }.padding(.horizontal, 20).frame(height: 52)
        }.background(DesignStyle.background)
        .interactiveDismissDisabled(working)
        .sheet(isPresented: Binding(get: { model.resultHost == .setup && model.result != nil }, set: { if !$0 { model.dismissResult() } })) {
            if let result = model.result { ResultView(model: model, result: result) { model.dismissResult() } }
        }
        .task {
            let check = await model.installer.checkCLI(); cliReady = check.available; cliMessage = check.message
        }
    }

    var continueButtonLabel: some View {
        ZStack {
            Text(continueTitle).hidden()
            Text(model.t("Setting up…", "正在设置…")).padding(.leading, 18).hidden()
            HStack(spacing: 6) {
                if settingUp {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12).accessibilityHidden(true)
                }
                Text(continueButtonTitle)
            }
        }
    }

    var continueButtonTitle: String {
        settingUp ? model.t("Setting up…", "正在设置…") : continueTitle
    }

    private var continueTitle: String {
        skillConflict ? model.t("Continue Without Skill", "不安装技能并继续") : model.t("Continue", "继续")
    }

    private func stepGraphic(_ number: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Text(number).font(.system(size: 13, weight: .semibold)).foregroundStyle(DesignStyle.secondary)
            Image(icon).resizable().scaledToFit().frame(width: 24, height: 24).frame(width: 48).accessibilityHidden(true)
        }
    }

    private func install() {
        working = true; model.busy = true; model.resultHost = .setup; error = nil
        model.operation = Task {
            var outcome = OperationResult(command: "cli.install", workspace: nil)
            defer { finish(outcome) }
            do {
                guard let source = Bundle.main.url(forResource: "modu-cli", withExtension: nil) else { throw ModuError("cli-unavailable", "Bundled modu-cli is missing.") }
                let check = try await model.installer.installCLI(from: source)
                cliReady = check.available; cliMessage = check.message
                outcome.status = check.available ? "success" : "failed"; outcome.message = check.message
            } catch { self.error = error.localizedDescription; outcome.status = Task.isCancelled ? "cancelled" : "failed"; outcome.message = error.localizedDescription }
            if PathSafety.exists(model.installer.executable) {
                var item = ItemResult(.init(kind: "cli", path: model.installer.executable.path), status: outcome.status)
                item.effects = [.init("install-cli", model.installer.executable.path, state: cliReady ? "applied" : "unknown")]; outcome.items = [item]
            }
        }
    }
    private func choose() {
        Task {
            guard let url = await FilePanels.directory() else { return }
            await checkCandidate(url)
        }
    }
    private func checkCandidate(_ url: URL) async {
        working = true; error = nil; skillConflict = false; candidate = nil
        defer { working = false }
        do {
            let checked = try await model.service.candidate(url)
            guard !Task.isCancelled else { return }
            candidate = checked
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func continueSetup() {
        guard let candidate else { return }
        working = true; settingUp = true; model.busy = true; model.resultHost = .setup; error = nil
        model.operation = Task {
            let skill = skillConflict ? nil : Bundle.main.url(forResource: "SKILL", withExtension: "md")
            let opened = await model.service.openWorkspaceWithRecord(candidate, skill: skill, installer: model.installer)
            var outcome = opened.result
            defer { settingUp = false; finish(outcome) }
            if outcome.status != "success" {
                error = (outcome.message.map { [$0] } ?? []) .joined(separator: "\n") + outcome.items.map { ($0.message ?? "") + "\n" + $0.effects.map { "\($0.action): \($0.target)" }.joined(separator: "\n") }.joined(separator: "\n")
                return
            }
            if Task.isCancelled { outcome.status = "cancelled"; return }
            if !skillConflict {
                if let error = opened.skillError ?? (skill == nil ? ModuError("skill-unavailable", "Bundled skill is unavailable.") : nil) {
                    self.error = error.localizedDescription; skillConflict = true; return
                }
            }
            guard !model.quitPending else { return }
            do {
                try await model.switchTo(candidate, loaded: opened.record)
                openWindow(id: "main"); dismiss()
            } catch {
                self.error = error.localizedDescription
                outcome.items.append(ItemResult(.init(kind: "workspace", path: candidate.path), status: "failed", error: .wrap(error)))
                outcome.summarize()
            }
        }
    }
    private func finish(_ outcome: OperationResult) {
        working = false; model.busy = false; model.operation = nil; model.cancelling = false
        if model.quitPending {
            if outcome.items.allSatisfy({ $0.effects.isEmpty }) { NSApp.terminate(nil) }
            else { model.result = outcome }
        } else { model.resultHost = .main; model.refreshDetail() }
    }
}

@MainActor
enum FilePanels {
    static func directory(at directory: URL? = nil, prompt: String? = nil) async -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = directory
        if let prompt { panel.prompt = prompt }
        return await panel.begin() == .OK ? panel.url : nil
    }
    static func readYAML(prompt: String) async throws -> (name: String, text: String)? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "yaml")!, UTType(filenameExtension: "yml")!]; panel.allowsMultipleSelection = false
        panel.prompt = prompt
        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        return (url.lastPathComponent, try String(contentsOf: url, encoding: .utf8))
    }
    static func saveYAML(_ text: String, name: String) async throws {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "yaml")!]; panel.nameFieldStringValue = name + ".yaml"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
