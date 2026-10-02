import Foundation
import ModuCore

extension AppModel {
    var operationProgressPhaseText: String {
        operationProgressPhaseText(for: progress)
    }

    func operationProgressPhaseText(for progress: OperationProgress?) -> String {
        if cancelling, progress?.cancellable != false { return t("Cancelling…", "正在取消…") }
        return progress.map { statusText($0.phase) } ?? t("Working…", "正在处理…")
    }

    var operationProgressSummaryText: String? {
        operationProgressSummaryText(for: progress)
    }

    func operationProgressSummaryText(for progress: OperationProgress?) -> String? {
        guard let progress, progress.total > 0 else { return nil }
        var parts = [t("\(progress.completed) of \(progress.total) processed", "已处理 \(progress.completed) / \(progress.total)")]
        if let counts = progress.counts {
            if counts.skipped > 0 { parts.append(t("Skipped \(counts.skipped)", "已跳过 \(counts.skipped)")) }
            if counts.failed > 0 { parts.append(t("Failed \(counts.failed)", "失败 \(counts.failed)")) }
        }
        return parts.joined(separator: " · ")
    }

    var repositoryUpdateProgressText: String {
        let title = cancelling ? t("Cancelling…", "正在取消…") : openingWorkspace ? t("Reloading workspace", "正在重新加载工作区") : t("Updating repositories", "正在更新仓库")
        guard let progress, progress.total > 0 else { return title }
        return "\(title) · \(progress.completed)/\(progress.total)"
    }

    func resultTitle(_ result: OperationResult) -> String {
        if result.command == "workspace.open", result.status != "success" { return t("Can’t open workspace", "无法打开工作区") }
        if result.command == "repo.add", result.status == "failed" {
            if result.items.first?.data?["disposition"] == "added" { return t("Repository added with an issue", "仓库已添加，但有一项问题") }
            return t("Can’t add repository", "无法添加仓库")
        }
        if result.status == "skipped" {
            if result.command == "repo.import-yaml" { return t("No repositories were added", "没有新增仓库") }
            if result.command == "repo.update" { return t("No repositories were updated", "没有仓库被更新") }
        }
        let tasks: [String: (String, String)] = [
            "repo.add": ("Repository addition", "添加仓库"), "repo.update": ("Repository update", "更新仓库"),
            "repo.remove": ("Repository deletion", "删除仓库"), "repo.import-yaml": ("Repository import", "导入仓库"),
            "workspace.import-yaml": ("Workspace import", "导入工作区"), "workspace.open": ("Workspace opening", "打开工作区"),
            "workspace.inspect": ("Resource check", "检查资源"), "worktree.create": ("Group creation", "创建分组"),
            "worktree.update": ("Group update", "更新分组"), "worktree.remove": ("Worktree deletion", "删除工作树"),
            "cli.install": ("CLI installation", "安装 CLI")
        ]
        let task = tasks[result.command] ?? ("Operation", "操作")
        let status = result.status == "success" && !result.items.isEmpty && result.items.allSatisfy { $0.data?["disposition"] == "up-to-date" } ? "up-to-date" : result.status
        return t(task.0, task.1) + " · " + statusText(status)
    }

    func resultSummaryText(_ result: OperationResult) -> String? {
        guard result.items.count > 1 else { return nil }
        var counts: [String: Int] = [:]
        for item in result.items {
            counts[item.reasonCode == "not-processed" ? "not-processed" : item.status, default: 0] += 1
        }
        return ["success", "skipped", "failed", "cancelled", "not-processed"].compactMap { status in
            guard let count = counts[status], count > 0 else { return nil }
            let label = status == "success" && result.command == "repo.import-yaml" ? "added" : status
            return statusText(label) + " \(count)"
        }.joined(separator: " · ")
    }

    func statusText(_ value: String) -> String {
        let labels: [String: (String, String)] = [
            "success": ("Completed", "已完成"), "partial-success": ("Partially completed", "部分完成"),
            "failed": ("Failed", "失败"), "skipped": ("Skipped", "已跳过"), "cancelled": ("Cancelled", "已取消"),
            "not-processed": ("Not processed", "未处理"),
            "added": ("Added", "已添加"), "already-exists": ("Already exists", "已存在"), "up-to-date": ("Already up to date", "已是最新"), "updated": ("Updated", "已更新"),
            "Clean": ("Clean", "无更改"), "Dirty": ("Dirty", "有更改"), "Other": ("Other", "不可用"), "Unset": ("Unset", "未加入"),
            "Added": ("Added", "新增"), "Moved": ("Moved", "移动"), "Modified": ("Modified", "修改"), "Deleted": ("Deleted", "删除"), "Untracked": ("Untracked", "未跟踪"), "Conflict": ("Conflict", "冲突"),
            "Checking repository…": ("Checking repository…", "正在检查仓库…"), "Cloning…": ("Cloning…", "正在克隆…"),
            "Updating repositories…": ("Updating repositories…", "正在更新仓库…"),
            "Creating…": ("Creating…", "正在创建…"), "Creating workspace worktree…": ("Creating workspace worktree…", "正在创建工作区工作树…"),
            "Saving…": ("Saving…", "正在保存…"), "Cleaning up…": ("Cleaning up…", "正在清理…"), "Deleting…": ("Deleting…", "正在删除…"),
            "Importing repositories…": ("Importing repositories…", "正在导入仓库…"), "Created": ("Created", "已创建"),
            "update-ignore": ("Updated .gitignore", "已更新 .gitignore"), "git-init": ("Initialized Git", "已初始化 Git"),
            "install-skill": ("Installed workflow skill", "已安装工作流技能"), "commit-workspace-files": ("Committed workspace files", "已提交工作区文件"),
            "create-directory": ("Created directory", "已创建目录"), "save-configuration": ("Saved configuration", "已保存配置"),
            "clone": ("Clone", "克隆"), "create-worktree": ("Create worktree", "创建工作树"), "create-branch": ("Create branch", "创建分支"),
            "remove-worktree": ("Remove worktree", "移除工作树"), "remove-declaration": ("Remove declaration", "移除记录"), "delete-branch": ("Delete branch", "删除分支"),
            "move-to-trash": ("Move to Trash", "移入废纸篓"), "update-refs": ("Update refs", "更新引用"), "fast-forward": ("Fast-forward", "快进"),
            "applied": ("Applied", "已生效"), "reverted": ("Cleaned up", "已清理"), "unknown": ("Unconfirmed", "无法确认")
        ]
        guard let label = labels[value] else { return value }
        return t(label.0, label.1)
    }
    func resultStatus(_ item: ItemResult) -> String {
        if item.reasonCode == "not-processed" { return statusText("not-processed") }
        guard let disposition = item.data?["disposition"], disposition != item.status else { return statusText(item.status) }
        if item.status == "success" { return statusText(disposition) }
        return statusText(item.status) + " · " + statusText(disposition)
    }
    func resultMessage(_ item: ItemResult, overallMessage: String?, command: String? = nil) -> String? {
        guard let message = item.message, !message.isEmpty,
              ![overallMessage, item.status, item.data?["disposition"], statusText(item.status), resultStatus(item)].contains(message) else { return nil }
        if command == "repo.add" || command == "repo.import-yaml", item.status == "failed" {
            return repositoryAdditionMessage(reasonCode: item.reasonCode, message: message, added: item.data?["disposition"] == "added")
        }
        return message
    }
    func repositoryAdditionMessage(reasonCode: String?, message: String, added: Bool = false) -> String {
        switch reasonCode {
        case "git-failed":
            if message.localizedCaseInsensitiveContains("repository not found") || message.localizedCaseInsensitiveContains("does not appear to be a git repository") {
                return t("Repository not found or access denied. Check the URL and your access permissions.", "仓库不存在或无权访问，请检查地址和访问权限。")
            }
            if message.hasPrefix("Git ls-remote") {
                return t("Couldn’t access the repository. Check the URL, network connection, and access permissions.", "无法访问仓库，请检查地址、网络连接和访问权限。")
            }
            if message.hasPrefix("Git clone") {
                return t("Couldn’t clone the repository. Check your network connection and access permissions, then try again.", "无法克隆仓库，请检查网络连接和访问权限后重试。")
            }
            return t("Couldn’t finish setting up the repository. See Details for the Git error.", "无法完成仓库设置，请展开详细信息查看 Git 错误。")
        case "authentication-failed":
            return t("Couldn’t authenticate with the repository. Check your Git credentials or SSH access.", "仓库认证失败，请检查 Git 凭据或 SSH 访问权限。")
        case "remote-head-unavailable":
            return t("The repository has no valid default branch. Check its default branch and try again.", "仓库没有有效的默认分支，请检查默认分支后重试。")
        case "ignore-unavailable", "ignore-write-failed":
            guard added else { return message }
            return t("The repository was added, but .gitignore couldn’t be updated. Check the file’s permissions and type.", "仓库已添加，但无法更新 .gitignore，请检查文件权限和类型。")
        case "workspace-commit-failed":
            return t("Workspace files couldn’t be committed automatically. Saved resources and file changes were kept. Check your Git configuration and see Details for the error, then retry.", "无法自动提交工作区文件。已保存的资源和文件变化已保留，请检查 Git 配置并展开详细信息查看错误后重试。")
        case "cleanup-failed":
            return t("The repository couldn’t be added, and cleanup failed. See Details for the remaining files.", "仓库添加失败，且未能完成清理，请展开详细信息查看残留文件。")
        default: return message
        }
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
