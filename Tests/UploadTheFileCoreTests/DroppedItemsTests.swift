import Foundation
import Testing

@testable import UploadTheFileCore

@Suite("Dropped items")
struct DroppedItemsTests {
    private let report = URL(fileURLWithPath: "/Users/alex/Documents/report.pdf")
    private let photo = URL(fileURLWithPath: "/Users/alex/Pictures/photo.png")
    private let site = URL(fileURLWithPath: "/Users/alex/Sites/trailhead", isDirectory: true)
    private let web = URL(string: "https://example.com/report.pdf")!

    @Test func keepsFileURLsInOrder() {
        let urls = DroppedItems.publishableFileURLs(from: [photo, report, site])
        #expect(urls.map(\.path) == [photo.path, report.path, site.path])
    }

    @Test func ignoresItemsThatAreNotFiles() {
        let urls = DroppedItems.publishableFileURLs(from: [web, report, URL(string: "mailto:a@b.co")!])
        #expect(urls.map(\.path) == [report.path])
    }

    @Test func dropsDuplicatesAndKeepsTheFirst() {
        let again = URL(fileURLWithPath: "/Users/alex/Documents/./report.pdf")
        let urls = DroppedItems.publishableFileURLs(from: [report, photo, again, report])
        #expect(urls.map(\.path) == [report.path, photo.path])
    }

    @Test func emptyAndWebOnlyDragsGiveNothing() {
        #expect(DroppedItems.publishableFileURLs(from: []).isEmpty)
        #expect(DroppedItems.publishableFileURLs(from: [web]).isEmpty)
    }

    @Test func acceptsADragWithAtLeastOneFile() {
        #expect(DroppedItems.isAcceptable([report]))
        #expect(DroppedItems.isAcceptable([web, photo]))
    }

    @Test func rejectsADragWithoutFiles() {
        #expect(!DroppedItems.isAcceptable([]))
        #expect(!DroppedItems.isAcceptable([web]))
    }
}
