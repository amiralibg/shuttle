import Testing
import ShuttleCore
@testable import ShuttleScroller

@Suite struct ScrollerTests {
    @Test func testSpringConvergence() {
        let scroller = Scroller()
        #expect(scroller.isSettled == true)

        // Set target offset
        scroller.scroll(by: 300.0)
        #expect(scroller.targetOffset == 300.0)
        #expect(scroller.isSettled == false)

        // Advance spring physics over several 16ms (60Hz) frames
        var dtTotal = 0.0
        for _ in 0..<60 {
            scroller.tick(dt: 0.016)
            dtTotal += 0.016
            if scroller.isSettled { break }
        }

        #expect(scroller.isSettled == true)
        #expect(abs(scroller.currentOffset - 300.0) < 0.5)
        #expect(scroller.velocity == 0.0)
    }

    @Test func testKeyboardColumnNavigation() {
        var strip = Strip(columns: [
            Column(windowIds: [1], width: .proportion(0.5)),
            Column(windowIds: [2], width: .proportion(0.5)),
            Column(windowIds: [3], width: .proportion(0.5))
        ])

        let scroller = Scroller()
        let viewportWidth = 1000.0
        let gap = 16.0

        // Initially focus column 0
        #expect(strip.focusedColumnIndex == 0)

        // Focus right to column 1
        let moved = scroller.focusRight(in: &strip, viewportWidth: viewportWidth, gap: gap)
        #expect(moved == true)
        #expect(strip.focusedColumnIndex == 1)
        #expect(scroller.isSettled == false)

        // Center of column 1:
        // offset[1] = 500 + 16 = 516. Col width = 500. Center = 516 + 250 = 766.
        // Target offset = 766 - 500 = 266
        #expect(scroller.targetOffset == 266.0)

        // Tick to settle
        for _ in 0..<60 {
            scroller.tick(dt: 0.016)
            if scroller.isSettled { break }
        }
        #expect(scroller.isSettled == true)
        #expect(abs(scroller.currentOffset - 266.0) < 0.5)

        // Focus left back to column 0
        let movedBack = scroller.focusLeft(in: &strip, viewportWidth: viewportWidth, gap: gap)
        #expect(movedBack == true)
        #expect(strip.focusedColumnIndex == 0)
        #expect(scroller.targetOffset == -250.0)
    }

    @Test func testPanAndSnapToNearest() {
        var strip = Strip(columns: [
            Column(windowIds: [1], width: .proportion(0.5)),
            Column(windowIds: [2], width: .proportion(0.5))
        ])

        let scroller = Scroller()
        let viewportWidth = 1000.0
        let gap = 16.0

        // Start centered at column 0 (-250)
        scroller.setOffset(-250.0)
        #expect(scroller.isSettled == true)

        // Interactive pan towards column 1 by +400pt
        scroller.pan(delta: 400.0, in: strip, viewportWidth: viewportWidth, gap: gap)
        #expect(scroller.currentOffset == 150.0)
        #expect(scroller.isSettled == false)

        // Snap to nearest column (150 is closer to Col 1's 266 than Col 0's -250)
        let snapped = scroller.snapToNearest(in: &strip, viewportWidth: viewportWidth, gap: gap)
        #expect(snapped == true)
        #expect(strip.focusedColumnIndex == 1)
        #expect(scroller.targetOffset == 266.0)

        // Let spring settle
        for _ in 0..<60 {
            scroller.tick(dt: 0.016)
            if scroller.isSettled { break }
        }
        #expect(scroller.isSettled == true)
        #expect(abs(scroller.currentOffset - 266.0) < 0.5)
    }

    @Test func testFlingGesture() {
        var strip = Strip(columns: [
            Column(windowIds: [1], width: .proportion(0.5)),
            Column(windowIds: [2], width: .proportion(0.5)),
            Column(windowIds: [3], width: .proportion(0.5))
        ])

        let scroller = Scroller()
        let viewportWidth = 1000.0
        let gap = 16.0

        // Centered at Col 0 (-250.0)
        scroller.setOffset(-250.0)

        // Fling forward with high positive velocity (+4000 pt/s)
        scroller.fling(initialVelocity: 4000.0, in: &strip, viewportWidth: viewportWidth, gap: gap)
        #expect(scroller.isSettled == false)
        // Projected offset = -250 + (4000 / 8) = 250 -> close to Col 1 (266)
        #expect(strip.focusedColumnIndex == 1)
        #expect(scroller.targetOffset == 266.0)
    }

    @Test func testColumnExpandAndShrink() {
        var strip = Strip(columns: [
            Column(windowIds: [1], width: .proportion(0.5))
        ])

        let scroller = Scroller()
        let viewportWidth = 1000.0
        let gap = 16.0

        // Expand by 20%
        scroller.expandFocusedColumn(in: &strip, by: 0.2, viewportWidth: viewportWidth, gap: gap)
        let expandedW = strip.columns[0].width.resolve(viewportWidth: viewportWidth)
        #expect(expandedW == 700.0) // 500 + 200

        // Shrink by 10%
        scroller.shrinkFocusedColumn(in: &strip, by: 0.1, viewportWidth: viewportWidth, gap: gap)
        let shrunkW = strip.columns[0].width.resolve(viewportWidth: viewportWidth)
        #expect(shrunkW == 600.0) // 700 - 100
    }
}
