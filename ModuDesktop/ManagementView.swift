import SwiftUI
import AppKit
import ModuCore

struct ManagementView: View {
    @Bindable var model: AppModel
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
            if let presentation = model.managementProgress {
                OperationProgressView(model: model, title: progressTitle, context: presentation.importFileName ?? (group.isEmpty ? nil : "worktrees/\(group)"), keepsCompletedItems: sheet != .add || presentation.importFileName != nil, presentation: presentation)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.headline).frame(minHeight: 22)
                        if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(DesignStyle.secondary).fixedSize(horizontal: false, vertical: true) }
                    }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
                    Divider()
                    VStack(alignment: .leading, spacing: 16) {
                        switch sheet {
                        case .add: addForm
                        case .create, .edit: groupForm
                        case .delete: deletionForm
                        }
                        if let error = error ?? model.formError {
                            FormErrorView(message: error,
                                          title: sheet == .add && model.formErrorDetails != nil ? model.t("Can’t add repository", "无法添加仓库") : nil,
                                          details: model.formErrorDetails,
                                          detailsTitle: model.t("Details", "详细信息"))
                        }
                    }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
                    Divider()
                    actions.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
                }.frame(width: DesignStyle.sheetWidth)
            }
        }
        .font(.body).background(DesignStyle.background).fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(model.busy)
        .onAppear {
            focused = true
            if sheet != .delete { model.formError = nil }
            if sheet == .edit, let name = model.selection?.group { group = name; selected = Set(model.pendingEdit?.0 == name ? model.pendingEdit!.1 : model.workspace?.groups[name]?.repositories ?? []) }
        }
    }

    private var addForm: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(model.t("Repository URL", "仓库 URL")).fixedSize()
                TextField("https://github.com/user/project", text: $url).focused($focused).accessibilityIdentifier("repositoryURL")
                    .accessibilityLabel(model.t("Repository URL", "仓库 URL")).onChange(of: url) { fieldError = nil; model.formError = nil }
                    .multilineTextAlignment(.trailing)
            }.padding(.horizontal, 16).frame(height: 36)
            if let fieldError { FormErrorView(message: fieldError).padding(.horizontal, 16).padding(.bottom, 8) }
            Divider().padding(.leading, 16)
            HStack(spacing: 16) {
                Text(model.t("Display Name", "显示名称")).fixedSize()
                TextField(model.t("Optional", "可选"), text: $displayName).multilineTextAlignment(.trailing)
                    .accessibilityLabel(model.t("Display Name", "显示名称"))
            }.padding(.horizontal, 16).frame(height: 36)
        }.textFieldStyle(.plain).formPlate()
    }

    private var groupForm: some View {
        let repositories = matchingRepositories
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.t("Group Name", "分组名称")).frame(height: 18)
                Group {
                    if sheet == .edit { Text(group).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).foregroundStyle(DesignStyle.secondary) }
                    else {
                        TextField("feature-name", text: $group).textFieldStyle(.plain).focused($focused).accessibilityIdentifier("groupName")
                            .accessibilityLabel(model.t("Group Name", "分组名称")).onChange(of: group) { fieldError = nil }
                    }
                }.padding(.horizontal, 12).frame(height: 36).formPlate()
                if let fieldError { FormErrorView(message: fieldError) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.t("Repositories", "仓库"))
                    Spacer()
                    if !repositorySearch.isEmpty {
                        Text(model.t("\(repositories.count) matches", "匹配 \(repositories.count) 个")).foregroundStyle(DesignStyle.secondary)
                            .accessibilityIdentifier("repositoryMatches")
                    }
                    Text("\(selected.count) / \(model.sortedRepositories.count) " + model.t("selected", "已选择")).foregroundStyle(DesignStyle.secondary)
                        .accessibilityIdentifier("repositorySelectionCount")
                }.frame(height: 18)
                RepositorySearchField(text: $repositorySearch, focused: $repositorySearchFocused, placeholder: model.t("Search repositories", "搜索仓库"))
                    .frame(height: 22)
                    .background {
                        Button(model.t("Search repositories", "搜索仓库")) { focused = false; repositorySearchFocused = true }
                            .keyboardShortcut("f").hidden().accessibilityHidden(true)
                    }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(repositories) { repo in
                            HStack {
                                Toggle(repo.displayName, isOn: Binding(get: { selected.contains(repo.id) }, set: { if $0 { selected.insert(repo.id) } else { selected.remove(repo.id) } })).toggleStyle(.checkbox)
                                    .accessibilityIdentifier("repository-\(repo.id)")
                                Spacer(minLength: 8)
                                if sheet == .edit { WorkingTreeStatus(model: model, status: memberStatus(repo.id)) }
                            }.padding(.horizontal, 16).frame(height: 28)
                                .overlay(alignment: .bottom) { if repo.id != repositories.last?.id { Divider().opacity(0.3) } }
                        }
                    }
                }.frame(maxWidth: .infinity).overlay {
                    if repositories.isEmpty {
                        HStack(spacing: 8) {
                            Text(model.t("No matching repositories", "没有匹配的仓库")).foregroundStyle(DesignStyle.secondary)
                            Button(model.t("Clear Search", "清除搜索")) { repositorySearch = "" }.buttonStyle(.link)
                                .accessibilityIdentifier("clearRepositorySearch")
                        }
                    }
                }.frame(height: CGFloat(min(model.sortedRepositories.count, 7) * 28)).formPlate()
            }
        }
    }

    var matchingRepositories: [Repository] {
        let query = repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.sortedRepositories.filter { query.isEmpty || $0.displayName.localizedStandardContains(query) }
    }

    var selectedMembers: [String] {
        model.sortedRepositories.filter { selected.contains($0.id) }.map(\.id)
    }

    private var deletionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.deletionPresentation.editingGroup { Text(model.t("The group workspace worktree will be kept.", "将保留分组根工作树。")) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(deletionDisplayResources) { resource in deletionRow(resource) }
                }.padding(.vertical, 4)
            }.frame(height: CGFloat(min(deletionDisplayResources.count, 7) * 28 + 8)).formPlate().textSelection(.enabled)
        }
    }

    func deletionRow(_ resource: Resource) -> some View {
        let target = model.deletionPresentation.targets.first { $0.resource == resource }
        return HStack(spacing: 12) {
            Text(resource.path).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .help(target?.path ?? model.workspace?.rootURL.appending(path: resource.path).path ?? resource.path)
            Spacer(minLength: 0)
            WorkingTreeStatus(model: model, status: "Clean").hidden().overlay(alignment: .trailing) {
                if !model.deletionPresentation.loading, let target { WorkingTreeStatus(model: model, status: deletionStatus(target)) }
            }.fixedSize()
        }.padding(.horizontal, 16).frame(height: 28)
    }

    var deletionDisplayResources: [Resource] {
        let resources = model.deletionPresentation.resources
        return resources.filter { $0.kind != "member" } + resources.filter { $0.kind == "member" }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if sheet == .add {
                Button { Task { do { if let file = try await FilePanels.readYAML(prompt: model.t("Import", "导入")) { model.importRepositories(file.text, filename: file.name) } } catch { self.error = error.localizedDescription } } } label: { Text(model.t("Import YAML…", "导入 YAML…")).padding(.horizontal, 4) }
            }
            if sheet == .delete && model.deletionPresentation.editingGroup { Button(model.t("Back to Edit", "返回编辑")) { model.sheet = .edit } }
            Spacer()
            Button(role: .cancel) { model.sheet = nil } label: { Text(model.t("Cancel", "取消")).padding(.horizontal, 4) }.keyboardShortcut(.cancelAction)
            Button(role: sheet == .delete ? .destructive : nil) { submit() } label: { Text(actionTitle).padding(.horizontal, 4) }
                .keyboardShortcut(sheet == .delete || repositorySearchFocused ? nil : .defaultAction).disabled(disabled)
        }.controlSize(.regular)
    }

    private var title: String {
        switch sheet {
        case .add: model.t("Add Repository", "添加仓库")
        case .create: model.t("Create Worktree Group", "创建工作树组")
        case .edit: model.t("Edit Worktree Group", "编辑工作树组")
        case .delete:
            switch model.deletionPresentation.request {
            case .repository: model.t("Delete Repository?", "删除仓库？")
            case .group: model.t("Delete Worktree Group?", "删除工作树组？")
            default: model.t("Delete Linked Worktree?", "删除关联工作树？")
            }
        }
    }

    private var subtitle: String? {
        if sheet == .delete {
            switch model.deletionPresentation.request {
            case .group: return model.t("The group workspace worktree, its members, and their current local branches (including unmerged commits) will be permanently deleted.", "将永久删除分组根工作树、成员工作树及它们当前的本地分支（包括未合并提交）。")
            case .repository: return model.t("The repository will move to Trash. Its linked worktrees and their current local branches (including unmerged commits) will be permanently deleted.", "仓库将移入废纸篓；关联工作树及其当前本地分支（包括未合并提交）将永久删除。")
            default: return model.t("The linked worktree and its current local branch (including unmerged commits) will be permanently deleted.", "将永久删除关联工作树及其当前本地分支（包括未合并提交）。")
            }
        }
        return nil
    }

    private var progressTitle: String {
        if model.managementProgress?.importFileName != nil { return model.t("Importing repositories…", "正在导入仓库…") }
        switch sheet {
        case .add: return model.t("Adding repository…", "正在添加仓库…")
        case .create: return model.t("Creating worktree group…", "正在创建工作树组…")
        case .edit: return model.t("Updating worktree group…", "正在更新工作树组…")
        case .delete: return model.t("Deleting…", "正在删除…")
        }
    }

    func deletionStatus(_ target: DeletionTarget) -> String {
        if !target.exists { return "Other" }
        if target.risks.contains("Working tree is clean.") { return "Clean" }
        if target.resource.kind != "repository" { return "Dirty" }
        return model.states[target.resource.id]?.dirty == true ? "Dirty" : "Clean"
    }
    private var actionTitle: String { switch sheet { case .add: model.t("Add", "添加"); case .create: model.t("Create", "创建"); case .edit: model.t("Save Changes", "保存更改"); case .delete: model.deletionPresentation.editingGroup ? model.t("Save Changes", "保存更改") : model.t("Delete", "删除") } }
    private var disabled: Bool { switch sheet { case .add: url.isEmpty; case .create: group.isEmpty || selected.isEmpty; case .edit: selected == Set(model.workspace?.groups[group]?.repositories ?? []); case .delete: !model.canConfirmDelete } }
    private func memberStatus(_ repo: String) -> String {
        guard model.workspace?.groups[group]?.repositories.contains(repo) == true else { return "Unset" }
        let state = model.states[Resource.member(group, repo).id]
        if state?.available != true { return "Other" }
        return state?.dirty == true ? "Dirty" : "Clean"
    }
    private func submit() {
        error = nil; fieldError = nil; model.formError = nil
        let members = selectedMembers
        switch sheet {
        case .add:
            do { _ = try RepositoryIdentity(url.trimmingCharacters(in: .whitespacesAndNewlines)); model.add(url, name: displayName) } catch { fieldError = error.localizedDescription }
        case .create:
            do { try PathSafety.groupName(group); model.create(group, members: members) } catch { fieldError = error.localizedDescription }
        case .edit: model.edit(group, members: members)
        case .delete: model.confirmDelete()
        }
    }
}

struct FormErrorView: View {
    let message: String
    var title: String? = nil
    var details: String? = nil
    var detailsTitle = "Details"
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.red) }
            ScrollView {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 90)
            if let details {
                DisclosureGroup(detailsTitle) {
                    ScrollView {
                        Text(details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RepositorySearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        field.sendsSearchStringImmediately = true
        field.maximumRecents = 0
        field.font = .systemFont(ofSize: 13)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("repositorySearch")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if focused, field.currentEditor() == nil {
            // SwiftUI releases the name field's focus after this update.
            DispatchQueue.main.async {
                guard context.coordinator.parent.focused, field.currentEditor() == nil else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: RepositorySearchField
        init(parent: RepositorySearchField) { self.parent = parent }

        @objc func search(_ field: NSSearchField) { parent.text = field.stringValue }
        func controlTextDidBeginEditing(_ notification: Notification) { if !parent.focused { parent.focused = true } }
        func controlTextDidEndEditing(_ notification: Notification) { if parent.focused { parent.focused = false } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            commandSelector == #selector(NSResponder.insertNewline(_:))
        }
    }
}

struct WorkingTreeStatus: View {
    var model: AppModel
    let status: String
    var body: some View {
        HStack(spacing: 4) {
            DesignIcon(name: status == "Clean" ? "Success" : status == "Unset" ? "Unset" : "Warning", size: 16)
            Text(model.statusText(status)).font(.system(size: 13, design: .monospaced))
        }.foregroundStyle(status == "Clean" ? Color.green : status == "Dirty" ? Color.orange : DesignStyle.secondary)
    }
}

struct OperationProgressView: View {
    var model: AppModel
    let title: String
    var context: String?
    var keepsCompletedItems = true
    var presentation: ManagementProgressPresentation? = nil
    private var progress: OperationProgress? { presentation?.progress ?? model.progress }
    private var phaseText: String { model.operationProgressPhaseText(for: progress) }
    private var summaryText: String? { model.operationProgressSummaryText(for: progress) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let context {
                    Text(context).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(context)
                }
            }
            HStack(spacing: 12) {
                ProgressView().controlSize(.small).frame(width: 20, height: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(progress?.target ?? " ").font(.system(.body, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).help(progress?.target ?? "")
                    Text(phaseText).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 36)
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let progress, progress.total > 0 {
                        ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    } else { ProgressView() }
                }.progressViewStyle(.linear).controlSize(.small)
                    .accessibilityLabel(title).accessibilityValue(summaryText ?? phaseText)
                Text(summaryText ?? " ").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityHidden(summaryText == nil)
            }
            Divider()
            HStack(spacing: 12) {
                if keepsCompletedItems {
                    Text(model.t("Completed items are kept when cancelled.", "取消后保留已完成项。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(model.t("Cancel", "取消")) { model.cancel() }.keyboardShortcut(.cancelAction)
                    .disabled(!model.busy || model.cancelling || progress?.cancellable == false)
            }.controlSize(.regular)
        }.font(.body).padding(24).frame(width: DesignStyle.sheetWidth).background(DesignStyle.background).interactiveDismissDisabled(model.busy)
    }
}

struct ResultView: View {
    var model: AppModel
    var result: OperationResult
    var retry: (() -> Void)? = nil
    var dismiss: () -> Void
    var body: some View {
        if result.reasonCode == "workspace-not-empty" {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.t("Can’t import into this workspace", "无法导入此工作区")).font(.headline)
                if let workspace = result.workspace { Text(model.t("Workspace: ", "工作区：") + (workspace as NSString).abbreviatingWithTildeInPath).textSelection(.enabled) }
                Text(model.t("The workspace must have no registered repositories or worktree groups, and no content in its repositories or worktrees folders.", "工作区不能包含已登记的仓库或工作树组，repositories 和 worktrees 目录也必须为空。"))
                Text(model.t("Choose another workspace in Settings, then try again. Your files and configuration have not been changed.", "请在设置中选择其他工作区后重试。你的文件和配置未被修改。"))
                Divider()
                Button(model.t("OK", "好"), action: dismiss).keyboardShortcut(.defaultAction).frame(maxWidth: .infinity, alignment: .trailing)
            }.font(.body).padding(24).frame(width: DesignStyle.sheetWidth).background(DesignStyle.background)
        } else {
            resultContents
        }
    }
    private var resultSymbol: String {
        switch result.status {
        case "success": "checkmark.circle"
        case "cancelled": "stop.circle"
        case "skipped": "info.circle"
        case "failed": "xmark.circle"
        default: "exclamationmark.triangle"
        }
    }
    private var resultColor: Color {
        switch result.status {
        case "success": .green
        case "failed": .red
        case "cancelled", "skipped": .secondary
        default: .orange
        }
    }
    private var resultContents: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: resultSymbol).foregroundStyle(resultColor).accessibilityHidden(true)
                    Text(model.resultTitle(result)).font(.headline)
                }
                if let summary = model.resultSummaryText(result) {
                    Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if result.command == "workspace.open", let workspace = result.workspace { Text(workspace).font(.system(.caption, design: .monospaced)) }
                    if let message = result.message { Text(message) }
                    ForEach(Array(result.items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 5) {
                            if result.command != "workspace.open" {
                                Text(item.resource.path).font(.system(.body, design: .monospaced))
                                if result.command != "repo.add" || result.items.count > 1 || result.status != "failed" {
                                    Text(model.resultStatus(item)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            let message = model.resultMessage(item, overallMessage: result.message, command: result.command)
                            if let message { Text(message).foregroundStyle(.secondary) }
                            ForEach(model.effectSummaries(item, workspace: result.workspace), id: \.self) { Text($0).font(.caption) }
                            if let trash = item.trashPath { Text(model.t("Trash: ", "废纸篓：") + trash).font(.system(.caption, design: .monospaced)) }
                            let errorDetails = item.message.flatMap { raw in message != nil && message != raw ? Git.sanitize(raw) : nil }
                            if !item.effects.isEmpty || errorDetails != nil {
                                DisclosureGroup(model.t("Details", "详细信息")) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let errorDetails { Text(errorDetails) }
                                        ForEach(Array(item.effects.enumerated()), id: \.offset) { _, effect in
                                            Text("\(effect.action): \(effect.target) [\(effect.state)]")
                                        }
                                    }.font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                                }.foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(maxHeight: 360)
            Divider()
            HStack {
                if let retry {
                    Button(model.t("Choose Another…", "重新选择…"), action: retry)
                    Spacer()
                    Button(model.t("Cancel", "取消"), role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
                } else {
                    Button(model.t("OK", "好"), action: dismiss).keyboardShortcut(.defaultAction)
                }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.body).padding(24).frame(width: DesignStyle.sheetWidth).background(DesignStyle.background)
    }
}
