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
                        Text(title).font(DialogTypography.title).frame(minHeight: 22)
                        if let subtitle { Text(subtitle).font(DialogTypography.body).foregroundStyle(DesignStyle.secondary).fixedSize(horizontal: false, vertical: true) }
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
                                          title: sheet == .add && management.formErrorDetails != nil ? presentation.text.string(.uiCanTAddRepository) : nil,
                                          details: management.formErrorDetails,
                                          detailsTitle: presentation.text.string(.uiDetails))
                        }
                    }.padding(.horizontal, 24).padding(.top, sheet == .importRepositories ? 0 : 20).padding(.bottom, 24)
                    if sheet != .importRepositories { Divider() }
                    actions.padding(.horizontal, 24).padding(.top, sheet == .importRepositories ? 0 : 16).padding(.bottom, 24)
                }.frame(width: DesignStyle.sheetWidth)
            }
        }
        .font(DialogTypography.body).background(sheet == .importRepositories ? Color.clear : DesignStyle.background).fixedSize(horizontal: false, vertical: true)
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
                Text(presentation.text.string(.uiRepositoryURL)).fixedSize()
                TextField(String("https://github.com/user/project"), text: $url).focused($focused).accessibilityIdentifier("repositoryURL")
                    .accessibilityLabel(presentation.text.string(.uiRepositoryURL)).onChange(of: url) { fieldError = nil; management.formError = nil }
                    .multilineTextAlignment(.trailing)
            }.padding(.horizontal, 16).frame(height: 36)
            if let fieldError { FormErrorView(message: fieldError).padding(.horizontal, 16).padding(.bottom, 8) }
            Divider().padding(.leading, 16)
            HStack(spacing: 16) {
                Text(presentation.text.string(.uiDisplayName)).fixedSize()
                TextField(presentation.text.string(.uiOptional), text: $displayName).multilineTextAlignment(.trailing)
                    .accessibilityLabel(presentation.text.string(.uiDisplayName))
            }.padding(.horizontal, 16).frame(height: 36)
        }.textFieldStyle(.plain).formPlate()
    }

    private var groupForm: some View {
        let repositories = matchingRepositories
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.text.string(.uiGroupName)).frame(height: 18)
                Group {
                    if sheet == .edit { Text(group).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).foregroundStyle(DesignStyle.secondary) }
                    else {
                        TextField(String("feature-name"), text: $group).textFieldStyle(.plain).focused($focused).accessibilityIdentifier("groupName")
                            .accessibilityLabel(presentation.text.string(.uiGroupName)).onChange(of: group) { fieldError = nil }
                    }
                }.padding(.horizontal, 12).frame(height: 36).formPlate()
                if let fieldError { FormErrorView(message: fieldError) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(presentation.text.string(.uiRepositories))
                    Spacer()
                    if !repositorySearch.isEmpty {
                        Text(presentation.text.string(.uiMatches(Int(repositories.count)))).font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
                            .accessibilityIdentifier("repositoryMatches")
                    }
                    Text(presentation.text.string(.uiOfSelected2(selected.count, workspace.sortedRepositories.count))).font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
                        .accessibilityIdentifier("repositorySelectionCount")
                }.frame(height: 18)
                RepositorySearchField(text: $repositorySearch, focused: $repositorySearchFocused, placeholder: presentation.text.string(.uiSearchRepositories))
                    .frame(height: 22)
                    .background {
                        Button(presentation.text.string(.uiSearchRepositories)) { focused = false; repositorySearchFocused = true }
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
                            Text(presentation.text.string(.uiNoMatchingRepositories)).foregroundStyle(DesignStyle.secondary)
                            Button(presentation.text.string(.uiClearSearch)) { repositorySearch = "" }.buttonStyle(.link)
                                .accessibilityIdentifier("clearRepositorySearch")
                        }.font(DialogTypography.auxiliary)
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
            if management.deletionPresentation.editingGroup { Text(presentation.text.string(.uiGroupWorkspaceWorktreeWillBeKept)).font(DialogTypography.auxiliary) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(deletionDisplayResources) { resource in deletionRow(resource) }
                }.padding(.vertical, 4)
            }.frame(height: CGFloat(min(deletionDisplayResources.count, 7) * 28 + 8)).formPlate().textSelection(.enabled)
        }
    }

    func deletionRow(_ resource: Resource) -> some View {
        let target = management.deletionPresentation.targets.first { $0.resource == resource }
        let risks = target?.riskMessages.map(presentation.text.message).joined(separator: "\n") ?? ""
        return HStack(spacing: 12) {
            Text(resource.path).font(DialogTypography.path).lineLimit(1).truncationMode(.middle)
                .help([target?.path ?? workspace.record?.rootURL.appending(path: resource.path).path ?? resource.path, risks].filter { !$0.isEmpty }.joined(separator: "\n"))
                .accessibilityHint(risks)
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
                Menu {
                    Button { Task { await chooseLocalRepositories() } } label: {
                        Label(presentation.text.string(.uiLocalRepositories2), systemImage: "folder")
                    }
                    Button { Task { await chooseRepositoryYAML() } } label: {
                        Label(presentation.text.string(.uiYamlFile), systemImage: "doc")
                    }
                } label: { Text(presentation.text.string(.uiImport)).padding(.horizontal, 4) }
                .fixedSize()
            }
            if sheet == .importRepositories { Button(presentation.text.string(.uiBack)) { management.sheet = .add } }
            if sheet == .delete && management.deletionPresentation.editingGroup { Button(presentation.text.string(.uiBackEdit)) { management.sheet = .edit } }
            Spacer()
            Button(role: .cancel) { management.sheet = nil } label: { Text(presentation.text.string(.uiCancel)).padding(.horizontal, 4) }.keyboardShortcut(.cancelAction)
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
        case .add: presentation.text.string(.uiAddRepository2)
        case .importRepositories: presentation.text.string(.uiImportRepositories)
        case .create: presentation.text.string(.uiCreateWorktreeGroup2)
        case .edit: presentation.text.string(.uiEditWorktreeGroup2)
        case .delete:
            switch management.deletionPresentation.request {
            case .repository: presentation.text.string(.uiDeleteRepository)
            case .group: presentation.text.string(.uiDeleteWorktreeGroup)
            default: presentation.text.string(.uiDeleteLinkedWorktree)
            }
        }
    }

    private var subtitle: String? {
        if sheet == .importRepositories { return presentation.text.string(.uiChooseRepositoriesCloneIntoWorkspace) }
        if sheet == .delete {
            switch management.deletionPresentation.request {
            case .group: return presentation.text.string(.uiGroupWorkspaceWorktreeMembersAndCurrentLocalBranches)
            case .repository: return presentation.text.string(.uiRepositoryWillMoveTrashLinkedWorktreesAndCurrent)
            default: return presentation.text.string(.uiLinkedWorktreeAndCurrentLocalBranchIncludingUnmerged)
            }
        }
        return nil
    }

    private var progressTitle: String {
        if management.progressPresentation?.scanningRepositories == true { return presentation.text.string(.uiScanningLocalRepositories) }
        if management.progressPresentation?.importFileName != nil { return presentation.text.string(.uiImportingRepositories) }
        switch sheet {
        case .add: return presentation.text.string(.uiAddingRepository)
        case .importRepositories: return presentation.text.string(.uiImportingRepositories)
        case .create: return presentation.text.string(.uiCreatingWorktreeGroup)
        case .edit: return presentation.text.string(.uiUpdatingWorktreeGroup)
        case .delete: return presentation.text.string(.uiDeleting)
        }
    }

    func deletionStatus(_ target: DeletionTarget) -> String {
        guard target.exists, let dirty = target.dirty else { return "Other" }
        return dirty ? "Dirty" : "Clean"
    }
    private var actionTitle: String { switch sheet { case .add: presentation.text.string(.uiAdd); case .importRepositories: presentation.text.string(.uiImport); case .create: presentation.text.string(.uiCreate); case .edit: presentation.text.string(.uiSaveChanges); case .delete: management.deletionPresentation.editingGroup ? presentation.text.string(.uiSaveChanges) : presentation.text.string(.uiDelete2) } }
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
            do { _ = try RepositoryIdentity(url.trimmingCharacters(in: .whitespacesAndNewlines)); management.add(url, name: displayName) } catch { fieldError = presentation.text.message(error) }
        case .importRepositories: management.confirmRepositoryImport()
        case .create:
            do { try PathSafety.groupName(group); management.create(group, members: members) } catch { fieldError = presentation.text.message(error) }
        case .edit: management.edit(group, members: members)
        case .delete: management.confirmDelete()
        }
    }

    private func chooseRepositoryYAML() async {
        let root = workspace.record?.rootURL
        error = nil; fieldError = nil; management.formError = nil
        do {
            guard let file = try await FilePanels.readYAML(prompt: presentation.text.string(.uiImport)),
                  management.sheet == .add, workspace.record?.rootURL == root else { return }
            management.prepareRepositoryImport(file.text, filename: file.name)
        } catch {
            guard management.sheet == .add, workspace.record?.rootURL == root else { return }
            management.presentError(error)
        }
    }

    private func chooseLocalRepositories() async {
        let root = workspace.record?.rootURL
        error = nil; fieldError = nil; management.formError = nil
        guard let directories = await FilePanels.repositoryDirectories(
            prompt: presentation.text.string(.uiScan),
            message: presentation.text.string(.uiSelectOneOrMoreFoldersFindGitRepositories)),
              management.sheet == .add, workspace.record?.rootURL == root else { return }
        management.prepareLocalRepositoryImport(directories)
    }
}
