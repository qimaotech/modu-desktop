import Foundation

public indirect enum UserMessage: Sendable, Equatable {
    case duplicateURL
    case repositoryNameCollision(String)
    case branchReuseComparisonUnavailable(String, String, UserMessage, isWorkspace: Bool)
    case branchReuseBehind(String, Int, String, isWorkspace: Bool)
    case unmanagedWorktrees([String])
    case workspaceChangesWereRestored
    case workspaceChangeCancelled
    case diagnostic(String)
    case joined([UserMessage], separator: String)
    case workspaceRepositoryIsUnavailable(UserMessage)
    case repositoryNameIsAlreadyRegistered(String)
    case repositoryTargetAlreadyExists(String)
    case remoteDefaultBranchDoesNotIdentifyCommit
    case repositoryTargetIsOccupied
    case remoteHasNoValidDefaultBranch
    case remoteDefaultBranchIsInvalid
    case repositoryRemoteMustResolveLocalPathInsideTemporary(String)
    case repositoryDirectoryIsMissing
    case workingTreeHasChanges
    case detachedHEAD
    case couldNotReadCurrentBranch
    case baseBranchIsUnavailableFixOriginHEADIn
    case currentBranchIsNotBaseBranch
    case headIsUnavailable
    case fetchedBaseBranchIsUnavailable
    case deletionTargetsOrCheckedOutBranchesChangedNothing
    case repositoryIsNotConfigured
    case groupIsNotConfigured
    case memberIsNotConfigured
    case missingRepositoryStillHasConfiguredMembers
    case existingDirectoryHasNoMatchingGitRegistration(String)
    case worktreeIsLocked(String)
    case registeredWorktreeHEADIsUnreadable(String)
    case couldNotInspectGroupDirectory
    case groupContainsUnmanagedGitRepository(String)
    case groupContainsUnmanagedBareGitRepository(String)
    case repositoryMembersMustBeRemovedFirst
    case groupStillHasMembers
    case couldNotVerifyBranchDeletion(String)
    case chooseAtLeastOneRepository
    case groupMembersMustReferenceDistinctConfiguredRepositories
    case groupNameConflictsWithExistingGroup
    case commitWorkspaceGitignoreBeforeCreatingGroupWorkspaceHas
    case groupRootHEADIsUnavailable
    case linkedWorktreesForRepositoriesContainingSubmodulesAreNot(String)
    case worktreePathAlreadyExists(String)
    case worktreePathIsAlreadyRegistered
    case noLocalStartingCommitUpdateMainRepositoryFirst(String)
    case couldNotVerifyNewBranch(String)
    case newBranchChangedDuringCreationAndWasKept(String)
    case originHEADDoesNotIdentifyValidComparisonCommit
    case couldNotReadBranchComparisonCount
    case notRepositoryRoot
    case noCompleteSupportedGitRepositoryURLsWereFound
    case yamlContainsUnresolvedOrRecursiveAlias
    case yamlContainsRepositoryURLWithEmbeddedCredentialsRemove
    case importRequiresEmptyWorkspaceChooseAnotherWorkspaceIn
    case workspaceRecordIsMissing(String)
    case workspaceTracksRepositoriesOrWorktreesRemovePathsFrom
    case repositorySummaryIsUnavailable
    case resourceIsNotConfigured
    case worktreeRegistrationIsMissing(String)
    case worktreeBelongsAnotherRepository
    case groupRootRegistrationIsMissing
    case groupRootBelongsAnotherRepository
    case worktreeHEADIsUnavailable
    case workspaceIsNotWritable(String)
    case chooseOrdinaryGitMainWorktreeOrDirectoryOutside
    case configurationSaveAndVerificationFailedResourcesWereKept
    case operationCancelledCompletedResourcesWereKept
    case useHTTPSSSHOrSCPStyleGitURL
    case notProcessedBecauseOperationStopped
    case appSBundledCLIIsMissingOrNot
    case reinstallModuCliLinkLocalBinModuCli
    case appSBundledCLICouldNotRun
    case loginShellCouldNotFindModuCliAdd
    case moduCliResolvesDifferentCommandAdjustPATHOrder(String, String)
    case checkLocalBinOwnershipAndPermissionsModuRequires
    case existingNonModuLocalBinModuCliWas
    case existingNonRegularWorkflowSkillFileWasKept(String)
    case existingNonDirectoryModuWorkflowNonRegularSKILL
    case loginShellCouldNotCompleteCLICheckCheck
    case latestReleaseHasNoCompatibleModuInstaller
    case downloadedInstallerIsIncompletePleaseTryAgain
    case releaseContainsUnsupportedInstallerChecksum
    case installerChecksumDoesNotMatchPleaseTryAgain
    case githubReturnedInvalidResponse
    case githubRequestFailedHTTPPleaseTryAgainLater(Int)
    case releaseVersionCouldNotBeCompared
    case updateInstallationPlanIsInvalid
    case releaseHasNoInstallerChecksum
    case moduCannotUpdateInLocationInstallInWritable
    case couldNotStartUpdateInstaller
    case updateInstallerDidNotBecomeReadyPleaseTry
    case installedApplicationOrPreparedUpdateChangedPleaseCheck
    case updateInstallerHasNoValidProcessIdentifier
    case updateInstallerStoppedUnexpectedlyPleaseTryAgain
    case installerDoesNotContainAppleSiliconExecutable
    case installerDoesNotContainExpectedVersionOfModu
    case installerIsMissingRequiredExecutable
    case updateRequiresNewerVersionOfMacOS
    case couldNotReplaceModu(UserMessage)
    case context(String, UserMessage)
    case moduDidNotExitInTimeUpdateWas
    case couldNotMonitorApplicationExit
    case couldNotMonitorRunningApplication
    case couldNotWaitForApplicationExit
    case expectedPreparedWorkspaceInsideOwnedTemporaryMockDirectory
    case mockWorkspaceHasNotBeenPreparedSuccessfully
    case expectedRegularMockDataFile(String)
    case symbolicLinksAreNotAllowedInTemporaryPath(String)
    case choosePathInsideTemporaryDirectory(String)
    case expectedRealDirectory(String)
    case invalidResourcePath
    case directoryMissing(String)
    case chooseFolderWithEmptyRepositoriesAndWorktrees(String)
    case groupNameMustBeOneDirectoryNameAnd
    case couldNotMoveTrash(String, UserMessage)
    case trashCompletedWithoutVerifiableDestination(String)
    case workspaceRootDoesNotMatchRecord
    case couldNotSave(String, UserMessage)
    case workspaceNotFound(String)
    case noRegisteredWorkspaceContainsCurrentDirectoryUseWorkspace
    case workspacesCanTBeNested(String)
    case invalidVersionOrCanonicalRootPath
    case duplicateRepositoryIdentity(String)
    case invalidGroup(String)
    case couldNotOpenWorkspaceLock
    case expectedOneConfigurationDocument
    case repositoriesMustBeList
    case repositoryMustBeMapping
    case groupsMustBeMapping
    case groupMustBeMapping
    case unknownOrDuplicateConfigurationField
    case gitReturnedNoWorktreeRegistrations
    case branchIsAlreadyCheckedOut(String)
    case notRepositoryRoot2(String)
    case repositoryOriginDoesNotMatchWorkspaceRecord(String)
    case invalidGroupBranchName(String)
    case invalidGitStatusRecord
    case missingRenameSourcePath
    case headDoesNotIdentifyCommit
    case originHEADDoesNotIdentifyCommit
    case invalidCommitObjectID
    case couldNotCheckGitignoreRules
    case couldNotCheckGitignore(UserMessage)
    case gitignoreMustBeReadableWritableRegularFile
    case couldNotUpdateGitignore(UserMessage)
    case groupCommitTracksReservedResourcePath
    case commitRegularWorkspaceGitignoreBeforeCreatingGroup
    case commitWorkspaceGitignoreBeforeCreatingGroupMissing(String)
    case git(String, UserMessage)
    case gitFailed(String, Int, UserMessage)
    case workspaceChangeDiscardRequiresRegularFile(String)
    case couldNotStashWorkspaceChangesBeforeUpdatingWorkflow(UserMessage, UserMessage)
    case changesWereRestoredButTemporaryStashCouldNot
    case workspaceChangesAndIndexStateWereRestoredBut(String, UserMessage)
    case couldNotFinishRestoringWorkspaceChangesStashWas(String, String, UserMessage)
    case workspaceCommitRequiresRegularFile(String)
    case couldNotCheckWorkspaceFileChanges
    case couldNotAutomaticallyCommitWorkspaceFilesSavedResources(UserMessage)
    case operationCancelled
    case couldNotCreateOutputPipe
    case couldNotCreateErrorPipe
    case couldNotLaunch(String, UserMessage)
    case couldNotReadProcessExitStatus
    case commandExceededSecondTimeLimit(Int)
    case commandOutputExceeded32MiB
    case bundledSkillIsUnavailable
    case mockWorkspaceRequiresMock
    case useBuildScriptPrepareMockLinkedWorktreeSelected
    case mockScenariosAreOnlyAvailableInDebugBuilds
    case isNotInstalled(String)
    case couldNotCreateClaudeCodeDesktopLink
    case couldNotCreateMockPreferences
    case couldNotIdentifyTestHostForCleanup
    case installed
    case workspaceIsInUseByAnotherModuOperation
    case couldNotAcquireWorkspaceLock
    case mainRepositoryWillBeMovedTrash
    case onlyRepositoryDeclarationWillBeRemoved
    case workingTreeIsClean
    case changedPathsWillBeMovedTrash(Int)
    case changedPathsWillBePermanentlyDeleted(Int)
    case ignoredFilesWillBePermanentlyDeleted
    case commitsAreNotReachableFromLocallyKnownRemote(Int)
    case detachedHEADNoBranchDelete
    case currentLocalBranchWillBePermanentlyDeletedIncluding(String)
    case directoryAndRegistrationAreMissingOnlyDeclarationWill
    case cleanupFailed(UserMessage)
    case branchTargetCompletedEffectsAreRetained(String)

    // CLI diagnostics must remain independent of the App's selected language.
    public var englishDescription: String {
        switch self {
        case .workspaceChangesWereRestored: return "Workspace changes were restored."
        case .workspaceChangeCancelled: return "Workspace change cancelled."
        case .branchReuseBehind(let branch, let count, let base, _): return "Reused branch '\(branch)' is \(count) \(count == 1 ? "commit" : "commits") behind '\(base)'. Its commits were kept."
        case .unmanagedWorktrees(let paths): return "Repository is still used by worktrees outside Modu’s configuration. Resolve them outside Modu first. No resources were changed.\n" + paths.joined(separator: "\n")
        case .branchReuseComparisonUnavailable(let arg1, let arg2, let arg3, _): return "Reused branch '\(arg1)', but its comparison with '\(arg2)' is unavailable. \(arg3.englishDescription)"
        case .repositoryNameCollision(let arg1): return "Different URLs derive the same repository name: \(arg1)"
        case .duplicateURL: return "Duplicate URL."
        case .diagnostic(let value): return value
        case .joined(let values, let separator): return values.map(\.englishDescription).joined(separator: separator)
        case .workspaceRepositoryIsUnavailable(let arg1): return "Workspace repository is unavailable: \(arg1.englishDescription)"
        case .repositoryNameIsAlreadyRegistered(let arg1): return "Repository name is already registered: \(arg1)"
        case .repositoryTargetAlreadyExists(let arg1): return "Repository target already exists: \(arg1)"
        case .remoteDefaultBranchDoesNotIdentifyCommit: return "Remote default branch does not identify a commit."
        case .repositoryTargetIsOccupied: return "Repository target is occupied."
        case .remoteHasNoValidDefaultBranch: return "Remote has no valid default branch."
        case .remoteDefaultBranchIsInvalid: return "Remote default branch is invalid."
        case .repositoryRemoteMustResolveLocalPathInsideTemporary(let arg1): return "Repository remote must resolve to a local path inside the temporary directory: \(arg1)"
        case .repositoryDirectoryIsMissing: return "Repository directory is missing."
        case .workingTreeHasChanges: return "Working tree has changes."
        case .detachedHEAD: return "Detached HEAD."
        case .couldNotReadCurrentBranch: return "Could not read the current branch."
        case .baseBranchIsUnavailableFixOriginHEADIn: return "Base branch is unavailable. Fix origin/HEAD in an external Git tool and retry."
        case .currentBranchIsNotBaseBranch: return "Current branch is not the Base branch."
        case .headIsUnavailable: return "HEAD is unavailable."
        case .fetchedBaseBranchIsUnavailable: return "Fetched Base branch is unavailable."
        case .deletionTargetsOrCheckedOutBranchesChangedNothing: return "Deletion targets or checked-out branches changed. Nothing has been deleted. Review a new confirmation."
        case .repositoryIsNotConfigured: return "Repository is not configured."
        case .groupIsNotConfigured: return "Group is not configured."
        case .memberIsNotConfigured: return "Member is not configured."
        case .missingRepositoryStillHasConfiguredMembers: return "Missing repository still has configured members."
        case .existingDirectoryHasNoMatchingGitRegistration(let arg1): return "Existing directory has no matching Git registration: \(arg1)"
        case .worktreeIsLocked(let arg1): return "Worktree is locked: \(arg1)"
        case .registeredWorktreeHEADIsUnreadable(let arg1): return "Registered worktree HEAD is unreadable: \(arg1)"
        case .couldNotInspectGroupDirectory: return "Could not inspect group directory."
        case .groupContainsUnmanagedGitRepository(let arg1): return "Group contains an unmanaged Git repository: \(arg1)"
        case .groupContainsUnmanagedBareGitRepository(let arg1): return "Group contains an unmanaged bare Git repository: \(arg1)"
        case .repositoryMembersMustBeRemovedFirst: return "Repository members must be removed first."
        case .groupStillHasMembers: return "Group still has members."
        case .couldNotVerifyBranchDeletion(let arg1): return "Could not verify branch deletion: \(arg1)"
        case .chooseAtLeastOneRepository: return "Choose at least one repository."
        case .groupMembersMustReferenceDistinctConfiguredRepositories: return "Group members must reference distinct configured repositories."
        case .groupNameConflictsWithExistingGroup: return "Group name conflicts with an existing group."
        case .commitWorkspaceGitignoreBeforeCreatingGroupWorkspaceHas: return "Commit the workspace .gitignore before creating this group. The workspace has no first commit."
        case .groupRootHEADIsUnavailable: return "Group root HEAD is unavailable."
        case .linkedWorktreesForRepositoriesContainingSubmodulesAreNot(let arg1): return "Linked worktrees for repositories containing submodules are not supported: \(arg1)"
        case .worktreePathAlreadyExists(let arg1): return "Worktree path already exists: \(arg1)"
        case .worktreePathIsAlreadyRegistered: return "Worktree path is already registered."
        case .noLocalStartingCommitUpdateMainRepositoryFirst(let arg1): return "No local starting commit. Update the main repository first: \(arg1)"
        case .couldNotVerifyNewBranch(let arg1): return "Could not verify the new branch: \(arg1)"
        case .newBranchChangedDuringCreationAndWasKept(let arg1): return "The new branch changed during creation and was kept: \(arg1)"
        case .originHEADDoesNotIdentifyValidComparisonCommit: return "origin/HEAD does not identify a valid comparison commit."
        case .couldNotReadBranchComparisonCount: return "Could not read the branch comparison count."
        case .notRepositoryRoot: return "Not a repository root."
        case .noCompleteSupportedGitRepositoryURLsWereFound: return "No complete, supported Git repository URLs were found in this YAML file."
        case .yamlContainsUnresolvedOrRecursiveAlias: return "YAML contains an unresolved or recursive alias."
        case .yamlContainsRepositoryURLWithEmbeddedCredentialsRemove: return "YAML contains a repository URL with embedded credentials. Remove credentials and retry."
        case .importRequiresEmptyWorkspaceChooseAnotherWorkspaceIn: return "Import requires an empty workspace. Choose another workspace in Settings. Existing files and configuration were not changed."
        case .workspaceRecordIsMissing(let arg1): return "Workspace record is missing: \(arg1)"
        case .workspaceTracksRepositoriesOrWorktreesRemovePathsFrom: return "Workspace tracks repositories/ or worktrees/. Remove those paths from Git outside Modu first."
        case .repositorySummaryIsUnavailable: return "Repository summary is unavailable."
        case .resourceIsNotConfigured: return "Resource is not configured."
        case .worktreeRegistrationIsMissing(let arg1): return "Worktree registration is missing: \(arg1)"
        case .worktreeBelongsAnotherRepository: return "Worktree belongs to another repository."
        case .groupRootRegistrationIsMissing: return "Group root registration is missing."
        case .groupRootBelongsAnotherRepository: return "Group root belongs to another repository."
        case .worktreeHEADIsUnavailable: return "Worktree HEAD is unavailable."
        case .workspaceIsNotWritable(let arg1): return "Workspace is not writable: \(arg1)"
        case .chooseOrdinaryGitMainWorktreeOrDirectoryOutside: return "Choose an ordinary Git main worktree or a directory outside another repository."
        case .configurationSaveAndVerificationFailedResourcesWereKept: return "Configuration save and verification failed. Resources were kept; inspect the workspace record before retrying."
        case .operationCancelledCompletedResourcesWereKept: return "Operation cancelled; completed resources were kept."
        case .useHTTPSSSHOrSCPStyleGitURL: return "Use an HTTPS, SSH, or SCP-style Git URL without embedded credentials."
        case .notProcessedBecauseOperationStopped: return "Not processed because the operation stopped."
        case .appSBundledCLIIsMissingOrNot: return "The app’s bundled CLI is missing or not executable."
        case .reinstallModuCliLinkLocalBinModuCli: return "Reinstall modu-cli to link ~/.local/bin/modu-cli to this app’s bundled CLI."
        case .appSBundledCLICouldNotRun: return "The app’s bundled CLI could not run."
        case .loginShellCouldNotFindModuCliAdd: return "The login shell could not find modu-cli. Add ~/.local/bin to its PATH, then retry. Shell configuration is not changed by Modu."
        case .moduCliResolvesDifferentCommandAdjustPATHOrder(let arg1, let arg2): return "modu-cli resolves to a different command. Adjust your PATH order or resolve the conflicting command, then retry.\nCurrent: \(arg1)\nExpected: \(arg2)"
        case .checkLocalBinOwnershipAndPermissionsModuRequires: return "Check ~/.local/bin ownership and permissions. Modu requires user-owned directories without group or world write access."
        case .existingNonModuLocalBinModuCliWas: return "The existing non-Modu ~/.local/bin/modu-cli was kept. Move it before retrying."
        case .existingNonRegularWorkflowSkillFileWasKept(let arg1): return "The existing non-regular workflow skill file was kept: \(arg1)"
        case .existingNonDirectoryModuWorkflowNonRegularSKILL: return "The existing non-directory modu-workflow, non-regular SKILL.md, or third-party link was kept."
        case .loginShellCouldNotCompleteCLICheckCheck: return "The login shell could not complete the CLI check. Check its startup configuration and retry."
        case .latestReleaseHasNoCompatibleModuInstaller: return "The latest release has no compatible Modu installer."
        case .downloadedInstallerIsIncompletePleaseTryAgain: return "The downloaded installer is incomplete. Please try again."
        case .releaseContainsUnsupportedInstallerChecksum: return "The release contains an unsupported installer checksum."
        case .installerChecksumDoesNotMatchPleaseTryAgain: return "The installer checksum does not match. Please try again."
        case .githubReturnedInvalidResponse: return "GitHub returned an invalid response."
        case .githubRequestFailedHTTPPleaseTryAgainLater(let arg1): return "GitHub request failed (HTTP \(arg1)). Please try again later."
        case .releaseVersionCouldNotBeCompared: return "The release version could not be compared."
        case .updateInstallationPlanIsInvalid: return "The update installation plan is invalid."
        case .releaseHasNoInstallerChecksum: return "The release has no installer checksum."
        case .moduCannotUpdateInLocationInstallInWritable: return "Modu cannot update in this location. Install it in a writable Applications folder and try again."
        case .couldNotStartUpdateInstaller: return "Could not start the update installer."
        case .updateInstallerDidNotBecomeReadyPleaseTry: return "The update installer did not become ready. Please try again."
        case .installedApplicationOrPreparedUpdateChangedPleaseCheck: return "The installed application or prepared update changed. Please check for updates again."
        case .updateInstallerHasNoValidProcessIdentifier: return "The update installer has no valid process identifier."
        case .updateInstallerStoppedUnexpectedlyPleaseTryAgain: return "The update installer stopped unexpectedly. Please try again."
        case .installerDoesNotContainAppleSiliconExecutable: return "The installer does not contain an Apple Silicon executable."
        case .installerDoesNotContainExpectedVersionOfModu: return "The installer does not contain the expected version of Modu."
        case .installerIsMissingRequiredExecutable: return "The installer is missing a required executable."
        case .updateRequiresNewerVersionOfMacOS: return "This update requires a newer version of macOS."
        case .couldNotReplaceModu(let arg1): return "Could not replace Modu: \(arg1.englishDescription)"
        case .context(let arg1, let arg2): return "\(arg1): \(arg2.englishDescription)"
        case .moduDidNotExitInTimeUpdateWas: return "Modu did not exit in time. The update was not installed. Please try again."
        case .couldNotMonitorApplicationExit: return "Could not monitor the application exit."
        case .couldNotMonitorRunningApplication: return "Could not monitor the running application."
        case .couldNotWaitForApplicationExit: return "Could not wait for the application to exit."
        case .expectedPreparedWorkspaceInsideOwnedTemporaryMockDirectory: return "Expected a prepared workspace inside an owned temporary mock directory."
        case .mockWorkspaceHasNotBeenPreparedSuccessfully: return "Mock workspace has not been prepared successfully."
        case .expectedRegularMockDataFile(let arg1): return "Expected a regular mock data file: \(arg1)"
        case .symbolicLinksAreNotAllowedInTemporaryPath(let arg1): return "Symbolic links are not allowed in this temporary path: \(arg1)"
        case .choosePathInsideTemporaryDirectory(let arg1): return "Choose a path inside the temporary directory: \(arg1)"
        case .expectedRealDirectory(let arg1): return "Expected a real directory: \(arg1)"
        case .invalidResourcePath: return "Invalid resource path."
        case .directoryMissing(let arg1): return "Directory missing: \(arg1)"
        case .chooseFolderWithEmptyRepositoriesAndWorktrees(let arg1): return "Choose a folder with empty repositories/ and worktrees/: \(arg1)"
        case .groupNameMustBeOneDirectoryNameAnd: return "Group name must be one directory name and a valid Git branch name."
        case .couldNotMoveTrash(let arg1, let arg2): return "Could not move to Trash: \(arg1). \(arg2.englishDescription)"
        case .trashCompletedWithoutVerifiableDestination(let arg1): return "Trash completed without a verifiable destination: \(arg1)"
        case .workspaceRootDoesNotMatchRecord: return "Workspace root does not match its record."
        case .couldNotSave(let arg1, let arg2): return "Could not save \(arg1): \(arg2.englishDescription)"
        case .workspaceNotFound(let arg1): return "Workspace not found: \(arg1)"
        case .noRegisteredWorkspaceContainsCurrentDirectoryUseWorkspace: return "No registered workspace contains the current directory. Use --workspace <root>."
        case .workspacesCanTBeNested(let arg1): return "Workspaces can’t be nested: \(arg1)"
        case .invalidVersionOrCanonicalRootPath: return "Invalid version or canonical root path."
        case .duplicateRepositoryIdentity(let arg1): return "Duplicate repository identity: \(arg1)"
        case .invalidGroup(let arg1): return "Invalid group: \(arg1)"
        case .couldNotOpenWorkspaceLock: return "Could not open workspace lock."
        case .expectedOneConfigurationDocument: return "Expected one configuration document."
        case .repositoriesMustBeList: return "repositories must be a list."
        case .repositoryMustBeMapping: return "Repository must be a mapping."
        case .groupsMustBeMapping: return "groups must be a mapping."
        case .groupMustBeMapping: return "Group must be a mapping."
        case .unknownOrDuplicateConfigurationField: return "Unknown or duplicate configuration field."
        case .gitReturnedNoWorktreeRegistrations: return "Git returned no worktree registrations."
        case .branchIsAlreadyCheckedOut(let arg1): return "Branch is already checked out: \(arg1)"
        case .notRepositoryRoot2(let arg1): return "Not a repository root: \(arg1)"
        case .repositoryOriginDoesNotMatchWorkspaceRecord(let arg1): return "Repository origin does not match the workspace record: \(arg1)"
        case .invalidGroupBranchName(let arg1): return "Invalid group branch name: \(arg1)"
        case .invalidGitStatusRecord: return "Invalid Git status record."
        case .missingRenameSourcePath: return "Missing rename source path."
        case .headDoesNotIdentifyCommit: return "HEAD does not identify a commit."
        case .originHEADDoesNotIdentifyCommit: return "origin/HEAD does not identify a commit."
        case .invalidCommitObjectID: return "Invalid commit object ID."
        case .couldNotCheckGitignoreRules: return "Could not check .gitignore rules."
        case .couldNotCheckGitignore(let arg1): return "Could not check .gitignore: \(arg1.englishDescription)"
        case .gitignoreMustBeReadableWritableRegularFile: return ".gitignore must be a readable, writable regular file."
        case .couldNotUpdateGitignore(let arg1): return "Could not update .gitignore: \(arg1.englishDescription)"
        case .groupCommitTracksReservedResourcePath: return "The group commit tracks a reserved resource path."
        case .commitRegularWorkspaceGitignoreBeforeCreatingGroup: return "Commit a regular workspace .gitignore before creating this group."
        case .commitWorkspaceGitignoreBeforeCreatingGroupMissing(let arg1): return "Commit the workspace .gitignore before creating this group. Missing: \(arg1)"
        case .git(let arg1, let arg2): return "Git \(arg1): \(arg2.englishDescription)"
        case .gitFailed(let arg1, let arg2, let arg3): return "Git \(arg1) failed (\(arg2)). \(arg3.englishDescription)"
        case .workspaceChangeDiscardRequiresRegularFile(let arg1): return "Workspace change discard requires a regular file: \(arg1)"
        case .couldNotStashWorkspaceChangesBeforeUpdatingWorkflow(let arg1, let arg2): return "Could not stash workspace changes before updating the workflow skill; the bundled skill was not installed.\(arg1.englishDescription) \(arg2.englishDescription)"
        case .changesWereRestoredButTemporaryStashCouldNot: return "Changes were restored, but the temporary stash could not be located for cleanup."
        case .workspaceChangesAndIndexStateWereRestoredBut(let arg1, let arg2): return "Workspace changes and their index state were restored, but stash \(arg1) could not be removed. Do not apply it again. \(arg2.englishDescription)"
        case .couldNotFinishRestoringWorkspaceChangesStashWas(let arg1, let arg2, let arg3): return "Could not finish restoring workspace changes. Stash \(arg1) was kept; completed workspace commits were kept. Check the working tree and index for conflicts before restoring it manually with git stash apply --index \(arg2). \(arg3.englishDescription)"
        case .workspaceCommitRequiresRegularFile(let arg1): return "Workspace commit requires a regular file: \(arg1)"
        case .couldNotCheckWorkspaceFileChanges: return "Could not check workspace file changes."
        case .couldNotAutomaticallyCommitWorkspaceFilesSavedResources(let arg1): return "Could not automatically commit workspace files. Saved resources and file changes were kept; the specified files may be staged. Check your Git identity, signing configuration and repository state, then retry. \(arg1.englishDescription)"
        case .operationCancelled: return "Operation cancelled."
        case .couldNotCreateOutputPipe: return "Could not create output pipe."
        case .couldNotCreateErrorPipe: return "Could not create error pipe."
        case .couldNotLaunch(let arg1, let arg2): return "Could not launch \(arg1): \(arg2.englishDescription)"
        case .couldNotReadProcessExitStatus: return "Could not read process exit status."
        case .commandExceededSecondTimeLimit(let arg1): return "Command exceeded its \(arg1)-second time limit."
        case .commandOutputExceeded32MiB: return "Command output exceeded 32 MiB."
        case .bundledSkillIsUnavailable: return "Bundled skill is unavailable."
        case .mockWorkspaceRequiresMock: return "--mock-workspace requires --mock."
        case .useBuildScriptPrepareMockLinkedWorktreeSelected: return "Use the build script to prepare --mock linked-worktree-selected --mock-workspace <root>."
        case .mockScenariosAreOnlyAvailableInDebugBuilds: return "Mock scenarios are only available in Debug builds."
        case .isNotInstalled(let arg1): return "\(arg1) is not installed."
        case .couldNotCreateClaudeCodeDesktopLink: return "Could not create the Claude Code desktop link."
        case .couldNotCreateMockPreferences: return "Could not create mock preferences."
        case .couldNotIdentifyTestHostForCleanup: return "Could not identify the test host for cleanup."
        case .installed: return "Installed"
        case .workspaceIsInUseByAnotherModuOperation: return "This workspace is in use by another Modu operation."
        case .couldNotAcquireWorkspaceLock: return "Could not acquire workspace lock."
        case .mainRepositoryWillBeMovedTrash: return "Main repository will be moved to Trash."
        case .onlyRepositoryDeclarationWillBeRemoved: return "Only the repository declaration will be removed."
        case .workingTreeIsClean: return "Working tree is clean."
        case .changedPathsWillBeMovedTrash(let arg1): return "\(arg1) changed paths will be moved to Trash."
        case .changedPathsWillBePermanentlyDeleted(let arg1): return "\(arg1) changed paths will be permanently deleted."
        case .ignoredFilesWillBePermanentlyDeleted: return "Ignored files will be permanently deleted."
        case .commitsAreNotReachableFromLocallyKnownRemote(let arg1): return "\(arg1) commits are not reachable from locally known remote-tracking refs."
        case .detachedHEADNoBranchDelete: return "Detached HEAD — no branch to delete."
        case .currentLocalBranchWillBePermanentlyDeletedIncluding(let arg1): return "Current local branch '\(arg1)' will be permanently deleted, including unmerged commits."
        case .directoryAndRegistrationAreMissingOnlyDeclarationWill: return "Directory and registration are missing; only the declaration will be removed. No branch will be deleted."
        case .cleanupFailed(let arg1): return "Cleanup failed: \(arg1.englishDescription)"
        case .branchTargetCompletedEffectsAreRetained(let arg1): return "Branch target: \(arg1). Completed effects are retained."
        }
    }
}
