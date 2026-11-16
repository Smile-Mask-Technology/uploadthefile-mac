import Foundation
import Testing

@testable import UploadTheFileCore

/// The popover crashed when files were dropped on its list: its size followed SwiftUI's ideal size,
/// which changed on every frame of the drop, and AppKit gave up on the layout loop. These pin the
/// rules that replace it; they need no screen.
@Suite("Popover sizing")
struct PopoverSizingTests {
    @Test func widthIsFixed() {
        #expect(PopoverSizing.width == 340)
    }

    @Test func firstMeasurementIsApplied() {
        #expect(PopoverSizing.nextHeight(current: nil, measured: 260.2, isDragActive: false) == 261)
    }

    @Test func heightsAreWholePoints() {
        #expect(PopoverSizing.nextHeight(current: 200, measured: 300.01, isDragActive: false) == 301)
    }

    @Test func nothingChangesDuringADrag() {
        #expect(PopoverSizing.nextHeight(current: nil, measured: 300, isDragActive: true) == nil)
        #expect(PopoverSizing.nextHeight(current: 200, measured: 400, isDragActive: true) == nil)
    }

    @Test func aPointOrLessIsIgnored() {
        #expect(PopoverSizing.nextHeight(current: 300, measured: 300, isDragActive: false) == nil)
        #expect(PopoverSizing.nextHeight(current: 300, measured: 300.4, isDragActive: false) == nil)  // rounds to 301
        #expect(PopoverSizing.nextHeight(current: 300, measured: 299.5, isDragActive: false) == nil)  // rounds to 300
        #expect(PopoverSizing.nextHeight(current: 300, measured: 302, isDragActive: false) == 302)
        #expect(PopoverSizing.nextHeight(current: 300, measured: 280, isDragActive: false) == 280)
    }

    @Test func heightStaysInsideTheLimits() {
        #expect(PopoverSizing.nextHeight(current: 300, measured: 20, isDragActive: false) == PopoverSizing.minHeight)
        #expect(PopoverSizing.nextHeight(current: 300, measured: 5_000, isDragActive: false) == PopoverSizing.maxHeight)
        // A small screen lowers the ceiling, but never below the minimum.
        #expect(PopoverSizing.nextHeight(current: 300, measured: 5_000, isDragActive: false, maxHeight: 500) == 500)
        #expect(PopoverSizing.nextHeight(current: 300, measured: 5_000, isDragActive: false, maxHeight: 50) == PopoverSizing.minHeight)
        // A tall screen does not raise it.
        #expect(PopoverSizing.nextHeight(current: 300, measured: 5_000, isDragActive: false, maxHeight: 4_000) == PopoverSizing.maxHeight)
    }

    @Test func nonsenseMeasurementsAreIgnored() {
        for value in [0.0, -10, .nan, .infinity] {
            #expect(PopoverSizing.nextHeight(current: 300, measured: value, isDragActive: false) == nil)
            #expect(PopoverSizing.nextHeight(current: nil, measured: value, isDragActive: false) == nil)
        }
    }

    /// The loop that crashed the app: a resize changes the measurement a little, which asks for
    /// another resize, and so on. With the threshold the window settles after one step.
    @Test func aMeasurementThatMovesWithTheWindowSettles() {
        var height: Double?
        var resizes = 0
        var measured = 300.0
        for step in 0..<200 {
            if let next = PopoverSizing.nextHeight(current: height, measured: measured, isDragActive: false) {
                height = next
                resizes += 1
                // The content reacts to every resize with sub-point layout noise.
                measured = next + (step.isMultiple(of: 2) ? 0.6 : -0.6)
            }
        }
        #expect(resizes == 1)
    }

    @Test func aDropThatKeepsChangingTheContentResizesOnceAfterItEnds() {
        var height: Double? = 200
        var resizes = 0
        // Every frame of the drop the content is a different height.
        for frame in 0..<60 {
            let measured = 200 + Double(frame) * 3
            if let next = PopoverSizing.nextHeight(current: height, measured: measured, isDragActive: true) {
                height = next
                resizes += 1
            }
        }
        #expect(resizes == 0)
        // The drag is over; the last measurement counts.
        if let next = PopoverSizing.nextHeight(current: height, measured: 377, isDragActive: false) {
            height = next
            resizes += 1
        }
        #expect(resizes == 1)
        #expect(height == 377)
    }
}
