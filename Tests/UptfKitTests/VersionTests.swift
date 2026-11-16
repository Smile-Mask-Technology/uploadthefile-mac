import Testing

@testable import UptfKit

@Test func versionIsSet() {
    #expect(!UptfKitVersion.value.isEmpty)
}
