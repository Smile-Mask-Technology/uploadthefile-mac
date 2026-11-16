import Foundation
import Testing

@testable import UploadTheFileCore

@Suite("Safe links")
struct SafeLinkTests {
    private let production = URL(string: "https://uploadthefile.com")!
    private let local = URL(string: "http://localhost:3000")!

    @Test func httpsLinksOpen() {
        #expect(SafeLink.url(from: "https://launch-notes.upload.tf", site: production)?.absoluteString == "https://launch-notes.upload.tf")
        #expect(SafeLink.url(from: "HTTPS://Launch-Notes.upload.tf/a?b=1", site: production) != nil)
        #expect(SafeLink.isOpenable("https://launch-notes.upload.tf/", site: nil))
    }

    @Test func surroundingWhitespaceIsIgnored() {
        #expect(SafeLink.url(from: " https://launch-notes.upload.tf\n", site: production)?.host == "launch-notes.upload.tf")
    }

    @Test func otherSchemesNeverOpen() {
        for link in [
            "file:///etc/passwd", "smb://server/share", "ssh://host", "ftp://host/file", "javascript:alert(1)",
            "data:text/html,hi", "x-apple.systempreferences:com.apple.preference", "tel:123", "mailto:a@b.co",
            "vnc://host", "itms-apps://apps.apple.com/app/1", "launch-notes.upload.tf", "//launch-notes.upload.tf",
        ] {
            #expect(SafeLink.url(from: link, site: production) == nil, "\(link)")
            #expect(SafeLink.url(from: link, site: local) == nil, "\(link)")
        }
    }

    @Test func plainHTTPOpensOnlyForALocalHttpSite() {
        let link = "http://my-page.localhost:3000"
        #expect(SafeLink.url(from: link, site: production) == nil)
        #expect(SafeLink.url(from: link, site: nil) == nil)
        #expect(SafeLink.url(from: link, site: local)?.absoluteString == link)
    }

    @Test func aLinkWithoutAHostDoesNotOpen() {
        #expect(SafeLink.url(from: "https://", site: production) == nil)
        #expect(SafeLink.url(from: "https:///path", site: production) == nil)
        #expect(SafeLink.url(from: "", site: production) == nil)
    }
}
