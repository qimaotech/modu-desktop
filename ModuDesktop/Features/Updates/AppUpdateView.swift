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
                    Text(model.downloading ? model.t("Downloading installer…", "正在下载安装包…") : model.t("Checking GitHub Releases…", "正在检查 GitHub Releases…"))
                }
            } else if model.installerURL != nil {
                Text(model.t("Quit Modu, then drag Modu.app from the disk image into Applications to replace the installed version. Your workspaces are preserved.", "请退出 Modu，再将磁盘映像中的 Modu.app 拖入 Applications 替换现有应用。工作区数据会保留。"))
            } else if model.update != nil {
                Text(model.t("Download the installer and open it to install the new version.", "下载安装包并打开后，即可手动安装新版本。"))
            } else if model.checked {
                Text(model.t("You’re running the latest version of Modu.", "你正在使用最新版本的 Modu。"))
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Link(model.t("Release Notes", "发布说明"), destination: model.update?.releaseURL ?? AppUpdateService.releasesURL)
                Spacer()
                if model.working {
                    Button(model.t("Cancel", "取消")) { model.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button(model.t("Close", "关闭")) { dismissWindow(id: "updates") }.keyboardShortcut(.cancelAction)
                    if model.installerURL != nil {
                        Button(model.t("Show in Finder", "在 Finder 中显示")) { model.revealInstaller() }
                        Button(model.t("Open Installer", "打开安装包")) { model.openInstaller() }.keyboardShortcut(.defaultAction)
                    } else if model.update != nil {
                        Button(model.t("Download Update", "下载更新")) { model.download() }.keyboardShortcut(.defaultAction)
                    } else {
                        Button(model.t("Check Again", "重新检查")) { model.check() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .font(DialogTypography.body)
        .padding(24).frame(width: 520, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        .background(WindowCloseHandler(shouldQuit: { model.cancel(); return false }))
        .onDisappear { model.cancel() }
    }

    private var title: String {
        if let update = model.update { return model.t("Modu \(update.version) is available", "Modu \(update.version) 已发布") }
        return model.t("Check for Updates", "检查更新")
    }
}
