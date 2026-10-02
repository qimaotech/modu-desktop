import Foundation
import Testing
@testable import ModuCore

struct VersionTests {
    @Test func bundledAppAndCLIShareConfiguredVersion() async throws {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == ModuVersion.current)
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == ModuVersion.buildNumber)
        let executable = try #require(Bundle.main.url(forResource: "modu-cli", withExtension: nil))
        let result = try await CommandRunner().run(executable.path, ["--version"], timeout: 10)
        #expect(result.status == 0)
        #expect(result.text == ModuVersion.current)
    }
}
