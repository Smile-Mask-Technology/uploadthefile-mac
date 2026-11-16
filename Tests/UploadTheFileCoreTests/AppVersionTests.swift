import Testing
import UptfKit

@testable import UploadTheFileCore

@Suite("App version")
struct AppVersionTests {
    @Test func theBundleVersionIsShown() {
        #expect(AppVersion.display(infoDictionary: ["CFBundleShortVersionString": "0.1.1"]) == "0.1.1")
        #expect(AppVersion.menuTitle(infoDictionary: ["CFBundleShortVersionString": "0.2.0"]) == "Version 0.2.0")
    }

    @Test func withoutABundleVersionThePackageVersionIsShown() {
        #expect(AppVersion.display(infoDictionary: nil) == UptfKitVersion.value)
        #expect(AppVersion.display(infoDictionary: ["CFBundleShortVersionString": "  "]) == UptfKitVersion.value)
        #expect(AppVersion.display(infoDictionary: ["CFBundleShortVersionString": 3]) == UptfKitVersion.value)
    }
}
