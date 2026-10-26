import SwiftUI
import ModuCore

struct AppUpdateView: View {
    var model: AppUpdateModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(DesignStyle.windowTitle)
            Text(model.t("Installed version: \(ModuVersion.current)", "当前版本：\(ModuVersion.current)"))
                .font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
            if model.working {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(progressText)
                }
            } else if model.update != nil {
                Text(model.t("Install the update and automatically restart Modu. Your workspaces are preserved.", "安装更新后将自动重新启动 Modu，工作区数据会保留。"))
            } else if model.checked {
                Text(model.t("You’re running the latest version of Modu.", "你正在使用最新版本的 Modu。"))
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Link(model.t("Release Notes", "发布说明"), destination: model.update?.releaseURL ?? AppUpdateService.releasesURL)
                Spacer()
                if model.restartPending {
                    Text(model.t("Waiting for Modu to quit…", "正在等待 Modu 退出…")).foregroundStyle(DesignStyle.secondary)
                } else if model.working {
                    Button(model.t("Cancel", "取消")) { model.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button(model.t("Close", "关闭")) { dismissWindow(id: "updates") }.keyboardShortcut(.cancelAction)
                    if model.update != nil {
                        Button(model.t("Install and Restart", "安装并重启")) { model.installAndRestart() }.keyboardShortcut(.defaultAction)
                    } else {
                        Button(model.t("Check Again", "重新检查")) { model.check() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .font(DialogTypography.body)
        .padding(24).frame(width: 520, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        .background(WindowCloseHandler(shouldQuit: { model.cancel(); return model.restartPending }))
        .onDisappear { model.cancel() }
    }

    private var progressText: String {
        if model.restartPending { return model.t("Ready to install. Modu will restart after quitting.", "更新已就绪，Modu 退出后将安装并重新启动。") }
        if model.downloading { return model.t("Downloading installer…", "正在下载安装包…") }
        if model.installing { return model.t("Preparing update…", "正在准备更新…") }
        return model.t("Checking GitHub Releases…", "正在检查 GitHub Releases…")
    }

    private var title: String {
        if let update = model.update { return model.t("Modu \(update.version) is available", "Modu \(update.version) 已发布") }
        return model.t("Check for Updates", "检查更新")
    }
}
