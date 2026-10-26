import Foundation

extension InterfaceText {
    func message(_ value: String) -> String {
        guard language == "zh" else { return value }
        for translation in Self.messageTranslations {
            if let result = translation.apply(to: value) { return result }
        }
        return value
    }

    private static let messageTranslations: [MessageTranslation] = [
        ("Installed", "已安装"),
        ("Unavailable", "不可用"),
        ("Install modu-cli to continue.", "请安装 modu-cli 后继续。"),
        ("The app’s bundled CLI is missing or not executable.", "App 内置的 CLI 缺失或无法执行，请重新安装 Modu。"),
        ("Reinstall modu-cli to link ~/.local/bin/modu-cli to this app’s bundled CLI.", "请重新安装 modu-cli，将 ~/.local/bin/modu-cli 链接到当前 App 内置的 CLI。"),
        ("The app’s bundled CLI could not run.", "App 内置的 CLI 无法运行，请重新安装 Modu。"),
        ("Add ~/.local/bin to your login shell’s PATH and remove any conflicting modu-cli command, then retry. The command must resolve to %@. Shell configuration is not changed by Modu.", "请将 ~/.local/bin 加入登录 shell 的 PATH，并移除冲突的 modu-cli 命令后重试。该命令必须指向 %@。Modu 不会修改 shell 配置。"),
        ("Check ~/.local/bin ownership and permissions. Modu requires user-owned directories without group or world write access.", "请检查 ~/.local/bin 的所有者和权限。Modu 要求目录归当前用户所有，且用户组和其他用户没有写入权限。"),
        ("The existing non-Modu ~/.local/bin/modu-cli was kept. Move it before retrying.", "已有的非 Modu 文件 ~/.local/bin/modu-cli 已保留，请将其移走后重试。"),
        ("The login shell did not return a complete result. Check its startup configuration and retry.", "登录 shell 未返回完整结果，请检查其启动配置后重试。"),
        ("The existing non-regular workflow skill file was kept: %@", "已有的非普通工作流技能文件已保留：%@"),
        ("The existing non-directory modu-workflow, non-regular SKILL.md, or third-party link was kept.", "已有的非目录 modu-workflow、非普通文件 SKILL.md 或第三方链接已保留。"),
        ("Bundled skill is unavailable.", "内置工作流技能不可用。"),
        ("Use an HTTPS, SSH, or SCP-style Git URL without embedded credentials.", "请使用 HTTPS、SSH 或 SCP 格式的 Git 地址，且不要在地址中包含凭据。"),
        ("Group name must be one directory name and a valid Git branch name.", "分组名称必须是单个目录名，同时符合 Git 分支命名规则。"),
        ("Invalid group branch name: %@", "分组分支名称无效：%@"),
        ("Choose at least one repository.", "请至少选择一个仓库。"),
        ("Group members must reference distinct configured repositories.", "分组成员必须引用已配置的仓库，且不能重复。"),
        ("Group name conflicts with an existing group.", "分组名称与已有分组冲突。"),
        ("No complete, supported Git repository URLs were found in this YAML file.", "此 YAML 文件中没有完整且受支持的 Git 仓库地址。"),
        ("YAML contains an unresolved or recursive alias.", "YAML 包含无法解析或递归引用的别名。"),
        ("YAML contains a repository URL with embedded credentials. Remove credentials and retry.", "YAML 中的仓库地址包含凭据，请移除凭据后重试。"),
        ("Duplicate URL.", "地址重复。"),
        ("Different URLs derive the same repository name: %@", "不同地址生成了相同的仓库名称：%@"),
        ("Import requires an empty workspace. Choose another workspace in Settings. Existing files and configuration were not changed.", "导入需要空工作区，请在设置中选择其他工作区。现有文件和配置未被修改。"),
        ("Workspace record is missing: %@", "工作区记录缺失：%@"),
        ("Workspace root does not match its record.", "工作区根目录与其记录不一致。"),
        ("Could not save %@", "无法保存 %@"),
        ("Workspace not found: %@", "找不到工作区：%@"),
        ("No registered workspace contains the current directory. Use --workspace <root>.", "当前目录不属于任何已登记的工作区，请使用 --workspace <root> 指定工作区。"),
        ("Workspaces can’t be nested: %@", "工作区不能嵌套：%@"),
        ("Invalid version or canonical root path.", "配置版本或规范化根目录路径无效。"),
        ("Duplicate repository identity: %@", "仓库标识重复：%@"),
        ("Invalid group: %@", "分组配置无效：%@"),
        ("Expected one configuration document.", "配置文件必须包含一个配置文档。"),
        ("repositories must be a list.", "repositories 必须是列表。"),
        ("Repository must be a mapping.", "仓库配置必须是映射。"),
        ("groups must be a mapping.", "groups 必须是映射。"),
        ("Group must be a mapping.", "分组配置必须是映射。"),
        ("Unknown or duplicate configuration field.", "配置中包含未知或重复的字段。"),
        ("Could not open workspace lock.", "无法打开工作区锁。"),
        ("This workspace is in use by another Modu operation.", "此工作区正被其他 Modu 操作使用。"),
        ("Could not acquire workspace lock.", "无法获取工作区锁。"),
        ("Workspace tracks repositories/ or worktrees/. Remove those paths from Git outside Modu first.", "工作区正在跟踪 repositories/ 或 worktrees/，请先使用外部 Git 工具移除对这些路径的跟踪。"),
        ("Repository summary is unavailable.", "仓库摘要不可用。"),
        ("Resource is not configured.", "资源尚未配置。"),
        ("Repository is not configured.", "仓库尚未配置。"),
        ("Group is not configured.", "分组尚未配置。"),
        ("Member is not configured.", "成员尚未配置。"),
        ("Worktree registration is missing: %@", "工作树登记信息缺失：%@"),
        ("Worktree belongs to another repository.", "此工作树属于另一个仓库。"),
        ("Group root registration is missing.", "分组根工作树的登记信息缺失。"),
        ("Group root belongs to another repository.", "分组根工作树属于另一个仓库。"),
        ("Worktree HEAD is unavailable.", "工作树 HEAD 不可用。"),
        ("Workspace is not writable: %@", "工作区不可写入：%@"),
        ("Choose an ordinary Git main worktree or a directory outside another repository.", "请选择普通 Git 主工作树，或位于其他仓库之外的目录。"),
        ("Configuration save and verification failed. Resources were kept; inspect the workspace record before retrying.", "配置保存和校验失败，资源已保留。请检查工作区记录后重试。"),
        ("Workspace repository is unavailable: %@", "工作区仓库不可用：%@"),
        ("Repository name is already registered: %@", "仓库名称已登记：%@"),
        ("Repository target already exists: %@", "仓库目标路径已存在：%@"),
        ("Remote default branch does not identify a commit.", "远端默认分支未指向有效提交。"),
        ("Repository target is occupied.", "仓库目标路径已被占用。"),
        ("Remote has no valid default branch.", "远端没有有效的默认分支。"),
        ("Remote default branch is invalid.", "远端默认分支无效。"),
        ("Repository directory is missing.", "仓库目录缺失。"),
        ("Working tree has changes.", "工作树有更改。"),
        ("Detached HEAD.", "HEAD 处于分离状态。"),
        ("Could not read the current branch.", "无法读取当前分支。"),
        ("Base branch is unavailable. Fix origin/HEAD in an external Git tool and retry.", "基准分支不可用，请使用外部 Git 工具修复 origin/HEAD 后重试。"),
        ("Current branch is not the Base branch.", "当前分支不是基准分支。"),
        ("HEAD is unavailable.", "HEAD 不可用。"),
        ("Fetched Base branch is unavailable.", "拉取的基准分支不可用。"),
        ("Commit the workspace .gitignore before creating this group. The workspace has no first commit.", "工作区尚无首次提交，请先提交工作区的 .gitignore，再创建此分组。"),
        ("Group root HEAD is unavailable.", "分组根工作树的 HEAD 不可用。"),
        ("Linked worktrees for repositories containing submodules are not supported: %@", "不支持为包含子模块的仓库创建关联工作树：%@"),
        ("Worktree path already exists: %@", "工作树路径已存在：%@"),
        ("Worktree path is already registered.", "工作树路径已登记。"),
        ("No local starting commit. Update the main repository first: %@", "没有可用的本地起始提交，请先更新主仓库：%@"),
        ("Could not verify the new branch: %@", "无法验证新分支：%@"),
        ("The new branch changed during creation and was kept: %@", "新分支在创建过程中发生变化，已保留：%@"),
        ("origin/HEAD does not identify a valid comparison commit.", "origin/HEAD 未指向有效的比较提交。"),
        ("Could not read the branch comparison count.", "无法读取分支比较的提交数量。"),
        ("Deletion targets or checked-out branches changed. Nothing has been deleted. Review a new confirmation.", "删除目标或检出的分支已变化，尚未删除任何内容，请重新确认。"),
        ("Missing repository still has configured members.", "缺失的仓库仍有已配置的成员。"),
        ("Existing directory has no matching Git registration: %@", "现有目录没有匹配的 Git 登记信息：%@"),
        ("Worktree is locked: %@", "工作树已锁定：%@"),
        ("Registered worktree HEAD is unreadable: %@", "无法读取已登记工作树的 HEAD：%@"),
        ("Repository is still used by worktrees outside Modu’s configuration. Resolve them outside Modu first. No resources were changed.\n%@", "Modu 配置之外的工作树仍在使用此仓库，请先在 Modu 之外处理。资源未被修改。\n%@"),
        ("Could not inspect group directory.", "无法检查分组目录。"),
        ("Group contains an unmanaged Git repository: %@", "分组中包含未受管理的 Git 仓库：%@"),
        ("Group contains an unmanaged bare Git repository: %@", "分组中包含未受管理的裸 Git 仓库：%@"),
        ("Repository members must be removed first.", "请先移除仓库成员。"),
        ("Group still has members.", "分组仍有成员。"),
        ("Could not verify branch deletion: %@", "无法验证分支删除结果：%@"),
        ("Not processed because the operation stopped.", "操作已停止，此项尚未处理。"),
        ("Operation cancelled.", "操作已取消。"),
        ("Operation cancelled; completed resources were kept.", "操作已取消，已完成的资源已保留。"),
        ("Workspace change cancelled.", "已取消切换工作区。"),
        ("Symbolic links are not allowed in this temporary path: %@", "此临时路径不允许使用符号链接：%@"),
        ("Choose a path inside the temporary directory: %@", "请选择此临时目录内的路径：%@"),
        ("Expected a real directory: %@", "此路径必须是实际目录：%@"),
        ("Invalid resource path.", "资源路径无效。"),
        ("Directory missing: %@", "目录缺失：%@"),
        ("Choose a folder with empty repositories/ and worktrees/: %@", "请选择 repositories/ 和 worktrees/ 均为空的文件夹：%@"),
        ("Could not move to Trash: %@", "无法移入废纸篓：%@"),
        ("Trash completed without a verifiable destination: %@", "移入废纸篓的操作已完成，但无法确认目标位置：%@"),
        ("Repository remote must resolve to a local path inside the temporary directory: %@", "仓库远端必须指向此临时目录内的本地路径：%@"),
        ("Git returned no worktree registrations.", "Git 未返回任何工作树登记信息。"),
        ("Branch is already checked out: %@", "分支已被检出：%@"),
        ("Not a repository root: %@", "此路径不是仓库根目录：%@"),
        ("Not a repository root.", "此路径不是仓库根目录。"),
        ("Repository origin does not match the workspace record: %@", "仓库 origin 与工作区记录不一致：%@"),
        ("Invalid Git status record.", "Git 状态记录无效。"),
        ("Missing rename source path.", "重命名记录缺少原路径。"),
        ("HEAD does not identify a commit.", "HEAD 未指向有效提交。"),
        ("origin/HEAD does not identify a commit.", "origin/HEAD 未指向有效提交。"),
        ("Invalid commit object ID.", "提交对象 ID 无效。"),
        ("Could not check .gitignore rules.", "无法检查 .gitignore 规则。"),
        ("Could not check .gitignore: %@", "无法检查 .gitignore：%@"),
        (".gitignore must be a readable, writable regular file.", ".gitignore 必须是可读写的普通文件。"),
        ("Could not update .gitignore: %@", "无法更新 .gitignore：%@"),
        ("The group commit tracks a reserved resource path.", "分组提交正在跟踪保留的资源路径。"),
        ("Commit a regular workspace .gitignore before creating this group.", "请先提交普通文件类型的工作区 .gitignore，再创建此分组。"),
        ("Commit the workspace .gitignore before creating this group. Missing: %@", "请先提交工作区的 .gitignore，再创建此分组。缺少规则：%@"),
        ("Workspace change discard requires a regular file: %@", "丢弃工作区改动要求目标是普通文件：%@"),
        ("Changes were restored, but the temporary stash could not be located for cleanup.", "改动已恢复，但找不到用于清理的临时 stash。"),
        ("Workspace commit requires a regular file: %@", "工作区提交要求目标是普通文件：%@"),
        ("Could not check workspace file changes.", "无法检查工作区文件改动。"),
        ("Could not automatically commit workspace files. Saved resources and file changes were kept; the specified files may be staged. Check your Git identity, signing configuration and repository state, then retry. %@", "无法自动提交工作区文件。已保存的资源和文件变化已保留，指定文件可能已暂存。请检查 Git 身份、签名配置和仓库状态后重试。%@"),
        ("Could not stash workspace changes before updating the workflow skill; the bundled skill was not installed.%@", "更新工作流技能前无法将工作区改动存入 stash，内置技能未安装。%@"),
        ("Workspace changes and their index state were restored, but stash %@ could not be removed. Do not apply it again. %@", "工作区改动及暂存状态已恢复，但无法移除 stash %@。请勿再次应用它。%@"),
        ("Could not finish restoring workspace changes. Stash %@ was kept; completed workspace commits were kept. Check the working tree and index for conflicts before restoring it manually with git stash apply --index %@. %@", "无法完成工作区改动恢复。stash %@ 和已完成的工作区提交均已保留。请检查工作树及暂存区冲突，再使用 git stash apply --index %@ 手动恢复。%@"),
        ("Could not create output pipe.", "无法创建输出管道。"),
        ("Could not create error pipe.", "无法创建错误输出管道。"),
        ("Could not launch %@", "无法启动 %@"),
        ("Could not read process exit status.", "无法读取进程退出状态。"),
        ("Command exceeded its %@-second time limit.", "命令执行超过 %@ 秒的时间限制。"),
        ("Command output exceeded 32 MiB.", "命令输出超过 32 MiB。"),
        ("Could not create the Claude Code desktop link.", "无法创建 Claude Code 桌面链接。"),
        ("%@ is not installed.", "尚未安装 %@。"),
        ("The installed application or prepared update changed. Please check for updates again.", "已安装的应用或准备好的更新发生变化，请重新检查更新。"),
        ("The update installation plan is invalid.", "更新安装计划无效，请重新检查更新。"),
        ("Could not start the update installer.", "无法启动更新程序。"),
        ("The update installer did not become ready. Please try again.", "更新程序未能就绪，请重试。"),
        ("Could not monitor the application exit.", "无法监测应用退出。"),
        ("Could not monitor the running application.", "无法监测正在运行的应用。"),
        ("Could not wait for the application to exit.", "无法等待应用退出。"),
        ("The update installer has no valid process identifier.", "更新程序缺少有效的进程标识。"),
        ("The update installer stopped unexpectedly. Please try again.", "更新程序意外停止，请重试。"),
        ("The installer does not contain an Apple Silicon executable.", "安装包不包含适用于 Apple Silicon 的可执行文件。"),
        ("The installer does not contain the expected version of Modu.", "安装包中不是预期版本的 Modu。"),
        ("The installer is missing a required executable.", "安装包缺少必需的可执行文件。"),
        ("Could not replace Modu: %@", "无法替换 Modu：%@"),
        ("GitHub returned an invalid response.", "GitHub 返回了无效响应。"),
        ("GitHub request failed (HTTP %@). Please try again later.", "GitHub 请求失败（HTTP %@），请稍后重试。"),
        ("Git %@ failed (%@). %@", "Git %@ 执行失败（%@）。%@")
    ].map { MessageTranslation(english: $0.0, chinese: $0.1) }
}

private struct MessageTranslation {
    let pattern: NSRegularExpression
    let parts: [String]

    init(english: String, chinese: String) {
        let literals = english.components(separatedBy: "%@")
        parts = chinese.components(separatedBy: "%@")
        precondition(literals.count == parts.count)
        // Match whole messages and insert captures literally, preserving paths and raw diagnostics.
        let expression = literals.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)")
        pattern = try! NSRegularExpression(pattern: "\\A" + expression + "\\z", options: .dotMatchesLineSeparators)
    }

    func apply(to value: String) -> String? {
        guard let match = pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        var result = parts[0]
        for index in 1..<parts.count {
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            result += value[range] + parts[index]
        }
        return result
    }
}
