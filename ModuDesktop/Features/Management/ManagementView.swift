import SwiftUI
import AppKit
import ModuCore

struct ManagementView: View {
    @Bindable var management: ManagementModel
    var workspace: WorkspaceModel
    var operations: OperationLifecycle
    var presentation: OperationPresentation
    let sheet: ManagementSheet
    @State private var url = ""
    @State private var displayName = ""
    @State private var group = ""
    @State var selected = Set<String>()
    @State var repositorySearch = ""
    @State private var repositorySearchFocused = false
    @State private var error: String?
    @State private var fieldError: String?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let progress = management.progressPresentation {
                OperationProgressView(operations: operations, operationPresentation: presentation, title: progressTitle, context: progress.importFileName ?? (group.isEmpty ? nil : "worktrees/\(group)"), keepsCompletedItems: sheet != .add || progress.importFileName != nil, presentation: progress)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.headline).frame(minHeight: 22)
                        if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(DesignStyle.secondary).fixedSize(horizontal: false, vertical: true) }
                    }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
                    if sheet != .importRepositories { Divider() }
                    VStack(alignment: .leading, spacing: 16) {
                        switch sheet {
                        case .add: addForm
                        case .importRepositories: RepositoryImportForm(management: management, text: presentation.text)
                        case .create, .edit: groupForm
                        case .delete: deletionForm
                        }
                        if let error = error ?? management.formError {
                            FormErrorView(message: error,
                                          title: sheet == .add && management.formErrorDetails != nil ? presentation.text.t("Can’t add repository", "无法添加仓库") : nil,
                                          details: management.formErrorDetails,
                                          detailsTitle: presentation.text.t("Details", "详细信息"))
                        }
                    }.padding(.horizontal, 24).padding(.top, sheet == .importRepositories ? 0 : 20).padding(.bottom, 24)
                    if sheet != .importRepositories { Divider() }
                    actions.padding(.horizontal, 24).padding(.top, sheet == .importRepositories ? 0 : 16).padding(.bottom, 24)
                }.frame(width: DesignStyle.sheetWidth)
            }
        }
        .font(.body).background(sheet == .importRepositories ? Color.clear : DesignStyle.background).fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(operations.busy)
        .onAppear {
            focused = true
            if sheet != .delete { management.formError = nil }
            if sheet == .edit, let name = workspace.selection?.group { group = name; selected = Set(management.pendingEdit?.0 == name ? management.pendingEdit!.1 : workspace.record?.groups[name]?.repositories ?? []) }
        }
    }

    private var addForm: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(presentation.text.t("Repository URL", "仓库 URL")).fixedSize()
                TextField("https://github.com/user/project", text: $url).focused($focused).accessibilityIdentifier("repositoryURL")
                    .accessibilityLabel(presentation.text.t("Repository URL", "仓库 URL")).onChange(of: url) { fieldError = nil; management.formError = nil }
                    .multilineTextAlignment(.trailing)
            }.padding(.horizontal, 16).frame(height: 36)
            if let fieldError { FormErrorView(message: fieldError).padding(.horizontal, 16).padding(.bottom, 8) }
            Divider().padding(.leading, 16)
            HStack(spacing: 16) {
                Text(presentation.text.t("Display Name", "显示名称")).fixedSize()
                TextField(presentation.text.t("Optional", "可选"), text: $displayName).multilineTextAlignment(.trailing)
                    .accessibilityLabel(presentation.text.t("Display Name", "显示名称"))
            }.padding(.horizontal, 16).frame(height: 36)
        }.textFieldStyle(.plain).formPlate()
    }

    private var groupForm: some View {
        let repositories = matchingRepositories
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.text.t("Group Name", "分组名称")).frame(height: 18)
                Group {
                    if sheet == .edit { Text(group).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).foregroundStyle(DesignStyle.secondary) }
                    else {
                        TextField("feature-name", text: $group).textFieldStyle(.plain).focused($focused).accessibilityIdentifier("groupName")
                            .accessibilityLabel(presentation.text.t("Group Name", "分组名称")).onChange(of: group) { fieldError = nil }
                    }
                }.padding(.horizontal, 12).frame(height: 36).formPlate()
                if let fieldError { FormErrorView(message: fieldError) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(presentation.text.t("Repositories", "仓库"))
                    Spacer()
                    if !repositorySearch.isEmpty {
                        Text(presentation.text.t("\(repositories.count) matches", "匹配 \(repositories.count) 个")).foregroundStyle(DesignStyle.secondary)
                            .accessibilityIdentifier("repositoryMatches")
                    }
                    Text("\(selected.count) / \(workspace.sortedRepositories.count) " + presentation.text.t("selected", "已选择")).foregroundStyle(DesignStyle.secondary)
                        .accessibilityIdentifier("repositorySelectionCount")
                }.frame(height: 18)
                RepositorySearchField(text: $repositorySearch, focused: $repositorySearchFocused, placeholder: presentation.text.t("Search repositories", "搜索仓库"))
                    .frame(height: 22)
                    .background {
                        Button(presentation.text.t("Search repositories", "搜索仓库")) { focused = false; repositorySearchFocused = true }
                            .keyboardShortcut("f").hidden().accessibilityHidden(true)
                    }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(repositories) { repo in
                            HStack {
                                Toggle(repo.displayName, isOn: Binding(get: { selected.contains(repo.id) }, set: { if $0 { selected.insert(repo.id) } else { selected.remove(repo.id) } })).toggleStyle(.checkbox)
                                    .accessibilityIdentifier("repository-\(repo.id)")
                                Spacer(minLength: 8)
                                if sheet == .edit { WorkingTreeStatus(text: presentation.text, status: memberStatus(repo.id)) }
                            }.padding(.horizontal, 16).frame(height: 28)
                                .overlay(alignment: .bottom) { if repo.id != repositories.last?.id { Divider().opacity(0.3) } }
                        }
                    }
                }.frame(maxWidth: .infinity).overlay {
                    if repositories.isEmpty {
                        HStack(spacing: 8) {
                            Text(presentation.text.t("No matching repositories", "没有匹配的仓库")).foregroundStyle(DesignStyle.secondary)
                            Button(presentation.text.t("Clear Search", "清除搜索")) { repositorySearch = "" }.buttonStyle(.link)
                                .accessibilityIdentifier("clearRepositorySearch")
                        }
                    }
                }.frame(height: CGFloat(min(workspace.sortedRepositories.count, 7) * 28)).formPlate()
            }
        }
    }

    var matchingRepositories: [Repository] {
        let query = repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspace.sortedRepositories.filter { query.isEmpty || $0.displayName.localizedStandardContains(query) }
    }

    var selectedMembers: [String] {
        workspace.sortedRepositories.filter { selected.contains($0.id) }.map(\.id)
    }

    private var deletionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if management.deletionPresentation.editingGroup { Text(presentation.text.t("The group workspace worktree will be kept.", "将保留分组根工作树。")) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(deletionDisplayResources) { resource in deletionRow(resource) }
                }.padding(.vertical, 4)
            }.frame(height: CGFloat(min(deletionDisplayResources.count, 7) * 28 + 8)).formPlate().textSelection(.enabled)
        }
    }

    func deletionRow(_ resource: Resource) -> some View {
        let target = management.deletionPresentation.targets.first { $0.resource == resource }
        return HStack(spacing: 12) {
            Text(resource.path).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .help(target?.path ?? workspace.record?.rootURL.appending(path: resource.path).path ?? resource.path)
            Spacer(minLength: 0)
            WorkingTreeStatus(text: presentation.text, status: "Clean").hidden().overlay(alignment: .trailing) {
                if !management.deletionPresentation.loading, let target { WorkingTreeStatus(text: presentation.text, status: deletionStatus(target)) }
            }.fixedSize()
        }.padding(.horizontal, 16).frame(height: 28)
    }

    var deletionDisplayResources: [Resource] {
        let resources = management.deletionPresentation.resources
        return resources.filter { $0.kind != .member } + resources.filter { $0.kind == .member }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if sheet == .add {
                Button { Task { await chooseRepositoryYAML() } } label: { Text(presentation.text.t("Import YAML…", "导入 YAML…")).padding(.horizontal, 4) }
            }
            if sheet == .importRepositories { Button(presentation.text.t("Back", "返回")) { management.sheet = .add } }
            if sheet == .delete && management.deletionPresentation.editingGroup { Button(presentation.text.t("Back to Edit", "返回编辑")) { management.sheet = .edit } }
            Spacer()
            Button(role: .cancel) { management.sheet = nil } label: { Text(presentation.text.t("Cancel", "取消")).padding(.horizontal, 4) }.keyboardShortcut(.cancelAction)
            if sheet == .importRepositories { submitButton.buttonStyle(.borderedProminent) }
            else { submitButton }
        }.controlSize(.regular)
    }

    private var submitButton: some View {
        Button(role: sheet == .delete ? .destructive : nil) { submit() } label: { Text(actionTitle).padding(.horizontal, 4) }
            .keyboardShortcut(sheet == .delete || repositorySearchFocused ? nil : .defaultAction).disabled(disabled)
    }

    private var title: String {
        switch sheet {
        case .add: presentation.text.t("Add Repository", "添加仓库")
        case .importRepositories: presentation.text.t("Import Repositories", "导入仓库")
        case .create: presentation.text.t("Create Worktree Group", "创建工作树分组")
        case .edit: presentation.text.t("Edit Worktree Group", "编辑工作树分组")
        case .delete:
            switch management.deletionPresentation.request {
            case .repository: presentation.text.t("Delete Repository?", "删除仓库？")
            case .group: presentation.text.t("Delete Worktree Group?", "删除工作树分组？")
            default: presentation.text.t("Delete Linked Worktree?", "删除关联工作树？")
            }
        }
    }

    private var subtitle: String? {
        if sheet == .importRepositories { return presentation.text.t("Choose repositories to clone into this workspace.", "选择要克隆到此工作区的仓库。") }
        if sheet == .delete {
            switch management.deletionPresentation.request {
            case .group: return presentation.text.t("The group workspace worktree, its members, and their current local branches (including unmerged commits) will be permanently deleted.", "将永久删除分组根工作树、成员工作树及它们当前的本地分支（包括未合并提交）。")
            case .repository: return presentation.text.t("The repository will move to Trash. Its linked worktrees and their current local branches (including unmerged commits) will be permanently deleted.", "仓库将移入废纸篓；关联工作树及其当前本地分支（包括未合并提交）将永久删除。")
            default: return presentation.text.t("The linked worktree and its current local branch (including unmerged commits) will be permanently deleted.", "将永久删除关联工作树及其当前本地分支（包括未合并提交）。")
            }
        }
        return nil
    }

    private var progressTitle: String {
        if management.progressPresentation?.importFileName != nil { return presentation.text.t("Importing repositories…", "正在导入仓库…") }
        switch sheet {
        case .add: return presentation.text.t("Adding repository…", "正在添加仓库…")
        case .importRepositories: return presentation.text.t("Importing repositories…", "正在导入仓库…")
        case .create: return presentation.text.t("Creating worktree group…", "正在创建工作树分组…")
        case .edit: return presentation.text.t("Updating worktree group…", "正在更新工作树分组…")
        case .delete: return presentation.text.t("Deleting…", "正在删除…")
        }
    }

    func deletionStatus(_ target: DeletionTarget) -> String {
        guard target.exists, let dirty = target.dirty else { return "Other" }
        return dirty ? "Dirty" : "Clean"
    }
    private var actionTitle: String { switch sheet { case .add: presentation.text.t("Add", "添加"); case .importRepositories: presentation.text.t("Import", "导入"); case .create: presentation.text.t("Create", "创建"); case .edit: presentation.text.t("Save Changes", "保存更改"); case .delete: management.deletionPresentation.editingGroup ? presentation.text.t("Save Changes", "保存更改") : presentation.text.t("Delete", "删除") } }
    private var disabled: Bool { switch sheet { case .add: url.isEmpty; case .importRepositories: !management.canConfirmRepositoryImport; case .create: group.isEmpty || selected.isEmpty; case .edit: selected == Set(workspace.record?.groups[group]?.repositories ?? []); case .delete: !management.canConfirmDelete } }
    private func memberStatus(_ repo: String) -> String {
        guard workspace.record?.groups[group]?.repositories.contains(repo) == true else { return "Unset" }
        let state = workspace.states[Resource.member(group, repo).id]
        if state?.available != true { return "Other" }
        return state?.dirty == true ? "Dirty" : "Clean"
    }
    private func submit() {
        error = nil; fieldError = nil; management.formError = nil
        let members = selectedMembers
        switch sheet {
        case .add:
            do { _ = try RepositoryIdentity(url.trimmingCharacters(in: .whitespacesAndNewlines)); management.add(url, name: displayName) } catch { fieldError = error.localizedDescription }
        case .importRepositories: management.confirmRepositoryImport()
        case .create:
            do { try PathSafety.groupName(group); management.create(group, members: members) } catch { fieldError = error.localizedDescription }
        case .edit: management.edit(group, members: members)
        case .delete: management.confirmDelete()
        }
    }

    private func chooseRepositoryYAML() async {
        let root = workspace.record?.rootURL
        error = nil; fieldError = nil; management.formError = nil
        do {
            guard let file = try await FilePanels.readYAML(prompt: presentation.text.t("Import", "导入")),
                  management.sheet == .add, workspace.record?.rootURL == root else { return }
            management.prepareRepositoryImport(file.text, filename: file.name)
        } catch {
            guard management.sheet == .add, workspace.record?.rootURL == root else { return }
            self.error = error.localizedDescription
        }
    }
}
