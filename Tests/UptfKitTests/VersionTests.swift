import Testing

@testable import UptfKit

/// The version string is compared as plain text by the release script (with VERSION, with the app
/// bundle's version and with `uptf --version`; a test in BundleResourceTests ties it to VERSION)
/// and goes into the User-Agent of every request. It has to be a bare version number.
@Suite("Library version")
struct VersionTests {
    @Test func versionIsABareMajorMinorPatchNumber() {
        let value = UptfKitVersion.value
        let isVersionNumber = value.wholeMatch(of: #/\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?/#) != nil
        #expect(isVersionNumber,
                "“\(value)” is not like 1.2.3 or 1.2.3-beta.1; a leading v, a space or a newline would break the release checks")
    }
}
