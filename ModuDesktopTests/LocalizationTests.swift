import Foundation
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct LocalizationTests {
    @Test func systemLanguageUsesOnlyTheFirstPreference() {
        for identifier in ["zh", "zh_CN", "zh-Hans-CN", "zh-Hant-TW", "zh-HK"] {
            #expect(AppLanguage.system.resolve(preferredLanguages: [identifier]) == .simplifiedChinese)
        }
        for identifiers in [["en-US"], ["en-GB"], ["fr-FR", "zh-Hans-CN"], ["ja-JP"], [""]] {
            #expect(AppLanguage.system.resolve(preferredLanguages: identifiers) == .english)
        }
        #expect(AppLanguage.system.resolve(preferredLanguages: []) == .english)
        #expect(AppLanguage.english.resolve(preferredLanguages: ["zh-CN"]) == .english)
        #expect(AppLanguage.simplifiedChinese.resolve(preferredLanguages: ["en-US"]) == .simplifiedChinese)
    }

    @Test func languageChangesApplyOnlyToTheNextLaunch() throws {
        try withDefaults { defaults in
            let preferences = AppPreferences(defaults: defaults, preferredLanguages: ["fr-FR", "zh-CN"])
            #expect(preferences.appLanguage == .system && preferences.activeLocale == .english)
            preferences.appLanguage = .simplifiedChinese
            #expect(defaults.string(forKey: "appLanguage") == "zh_CN")
            #expect(preferences.activeLocale == .english && preferences.languageChangeRequiresRestart)
            #expect(preferences.text.string(.uiLanguage) == "Language")
            let relaunched = AppPreferences(defaults: defaults, preferredLanguages: ["fr-FR"])
            #expect(relaunched.activeLocale == .simplifiedChinese && !relaunched.languageChangeRequiresRestart)
            #expect(relaunched.text.string(.uiLanguage) == "语言")
            relaunched.appLanguage = .system
            #expect(relaunched.activeLocale == .simplifiedChinese && relaunched.languageChangeRequiresRestart)
        }
    }

    @Test func startupLanguageIsVolatileAndPreservesOtherArguments() throws {
        try withDefaults { defaults in
            let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
            let suite = try #require(defaults.string(forKey: "testSuite"))
            let persisted = defaults.persistentDomain(forName: suite)
            var arguments = original
            arguments["unrelatedArgument"] = "kept"
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            AppLocalization.configure(.simplifiedChinese, defaults: defaults)
            #expect(defaults.stringArray(forKey: "AppleLanguages")?.first == "zh-Hans-CN")
            #expect(defaults.string(forKey: "AppleLocale") == "zh_CN")
            #expect(defaults.string(forKey: "unrelatedArgument") == "kept")
            #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:]).isEqual(to: persisted ?? [:]))
        }
    }

    @Test func compiledResourcesContainBothLanguages() throws {
        let bundle = Bundle(for: AppModel.self)
        for (identifier, expected) in [("en-US", "Language"), ("zh-Hans-CN", "语言")] {
            let directory = try #require(bundle.url(forResource: identifier, withExtension: "lproj"))
            let localized = try #require(Bundle(url: directory))
            #expect(localized.localizedString(forKey: "ui.language", value: nil, table: "Localizable") == expected)
        }
    }

    @Test func configurationErrorsKeepTheirPathAndLocalizableCause() async throws {
        let fixture = try await Fixture(createRemote: false)
        defer { fixture.remove() }
        var record = WorkspaceRecord(root: fixture.root.path)
        try fixture.service.store.save(record)
        record.version = 2
        let file = fixture.service.store.recordURL(fixture.root)
        try JSONEncoder().encode(record).write(to: file)
        do {
            _ = try fixture.service.store.load(fixture.root)
            Issue.record("Invalid configuration should fail.")
        } catch {
            let failure = ModuError.wrap(error)
            #expect(failure.code == "invalid-configuration")
            #expect(failure.message == file.path + ": Invalid version or canonical root path.")
            let text = InterfaceText(locale: .simplifiedChinese).message(failure)
            #expect(text.contains(file.path) && text.contains("配置版本或规范化根目录路径无效"))
            #expect(!text.contains("Invalid version"))
        }
    }

    @Test func structuredFailuresAndRiskPluralsPreserveTheCLIContract() throws {
        let path = "/tmp/含空格 %@/repo"
        let message = UserMessage.joined([.context(path, .operationCancelledCompletedResourcesWereKept), .cleanupFailed(.workingTreeHasChanges)], separator: "\n")
        let error = ModuError("cleanup-failed", message)
        let item = ItemResult(.repository("repo"), status: .failed, error: error)
        let result = OperationResult(command: "repo.remove", workspace: path, status: .failed, items: [item], error: error)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(object["schema-version"] as? Int == 1 && object["userMessage"] == nil && object["user-message"] == nil)
        #expect(object["message"] as? String == message.englishDescription)
        let encodedItem = try #require((object["items"] as? [[String: Any]])?.first)
        #expect(encodedItem["userMessage"] == nil && encodedItem["message"] as? String == error.message)
        let decoded = try JSONDecoder().decode(OperationResult.self, from: JSONEncoder().encode(result))
        #expect(decoded.userMessage == nil && decoded.items.first?.userMessage == nil)
        let risk = UserMessage.changedPathsWillBePermanentlyDeleted(1)
        let target = DeletionTarget(resource: .member("feature", "repo"), path: path, branch: "feature", detached: false,
                                    registered: true, exists: true, risks: [risk.englishDescription], riskMessages: [risk])
        let targetData = try JSONEncoder().encode(target)
        let targetObject = try #require(JSONSerialization.jsonObject(with: targetData) as? [String: Any])
        #expect(targetObject["riskMessages"] == nil && targetObject["risks"] as? [String] == [risk.englishDescription])
        #expect(try JSONDecoder().decode(DeletionTarget.self, from: targetData) == target)
        let chinese = InterfaceText(locale: .simplifiedChinese).message(item)
        #expect(chinese.contains(path) && chinese.contains("已完成的资源已保留") && chinese.contains("清理失败"))
        let english = InterfaceText(locale: .english)
        #expect(english.message(.changedPathsWillBePermanentlyDeleted(1)) == "1 changed path will be permanently deleted.")
        #expect(english.message(.changedPathsWillBePermanentlyDeleted(2)) == "2 changed paths will be permanently deleted.")
        #expect(InterfaceText(locale: .simplifiedChinese).message(.changedPathsWillBePermanentlyDeleted(2)).contains("2 个更改路径"))
        #expect(!InterfaceText(locale: .simplifiedChinese).message(.diagnostic("raw external error")).contains("raw external error"))
        #expect(english.message(.branchReuseBehind("feature", 1, "origin/main", isWorkspace: false)).contains("1 commit behind"))
        #expect(InterfaceText(locale: .simplifiedChinese).message(.branchReuseBehind("feature", 2, "workspace HEAD", isWorkspace: true)).contains("工作区 HEAD"))
        let recovery = UserMessage.joined([.joined([], separator: ""), .workspaceChangesWereRestored], separator: " ")
        let stashFailure = UserMessage.couldNotStashWorkspaceChangesBeforeUpdatingWorkflow(recovery, .workingTreeHasChanges)
        #expect(stashFailure.englishDescription.contains("installed. Workspace changes were restored. Working tree has changes."))
        #expect(InterfaceText(locale: .simplifiedChinese).message(stashFailure).contains("工作区改动已恢复"))
    }

    @Test func commitDatesUseTheSelectedLocaleAndCurrentTimeZone() {
        let commit = GitCommit(id: "id", subject: "subject", author: "author", date: "2026-10-27T13:05:00Z")
        let utc = TimeZone(secondsFromGMT: 0)!
        let china = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        #expect(commit.displayDate(locale: .english, timeZone: utc).contains("Oct"))
        #expect(commit.displayDate(locale: .simplifiedChinese, timeZone: utc).contains("2026"))
        #expect(commit.displayDate(locale: .english, timeZone: utc) != commit.displayDate(locale: .english, timeZone: china))
        let invalid = GitCommit(id: "id", subject: "subject", author: "author", date: "invalid")
        #expect(invalid.displayDate(locale: .english) == "invalid")
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ModuLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(suite, forKey: "testSuite")
        try body(defaults)
    }
}
