import Foundation
import Testing
@testable import MonoDeckCore

struct VersionTests {
    @Test func bundledAppAndCLIShareConfiguredVersion() async throws {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == MonoDeckVersion.current)
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == MonoDeckVersion.buildNumber)
        let executable = try #require(Bundle.main.url(forResource: "mono-deck", withExtension: nil))
        let result = try await CommandRunner().run(executable.path, ["--version"], timeout: 10)
        #expect(result.status == 0)
        #expect(result.text == MonoDeckVersion.current)
    }
}
