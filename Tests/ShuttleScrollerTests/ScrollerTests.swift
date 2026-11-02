import Testing
import ShuttleCore
import WeftCore
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

@Suite struct ScrollerRegressionTests {
    @Test func snapToNearestMovesFocusedWindowWithColumn() {
        var strip = Strip(columns: [Column(windowIds: [1]), Column(windowIds: [2])])
        let scroller = Scroller()
        scroller.setOffset(-250)
        scroller.pan(delta: 400, in: strip, viewportWidth: 1000, gap: 16)

        scroller.snapToNearest(in: &strip, viewportWidth: 1000, gap: 16)

        #expect(strip.focusedColumnIndex == 1)
        #expect(strip.focusedWindowId == 2)
    }

    @Test func flingOnEmptyStripReturns() {
        // Used to re-take the scroller's non-recursive lock and deadlock.
        var strip = Strip()
        let scroller = Scroller()
        scroller.fling(initialVelocity: 2000, in: &strip, viewportWidth: 1000, gap: 16)
        #expect(scroller.isSettled)
    }

    @Test func neverModeRevealsInsteadOfCentering() {
        var strip = Strip(columns: [Column(windowIds: [1]), Column(windowIds: [2]), Column(windowIds: [3])])
        let scroller = Scroller(centerMode: .never)
        scroller.setOffset(0)

        _ = scroller.focusRight(in: &strip, viewportWidth: 1000, gap: 16)
        #expect(scroller.targetOffset == 16)
        _ = scroller.focusRight(in: &strip, viewportWidth: 1000, gap: 16)
        #expect(scroller.targetOffset == 532)
        // Column 1 (516..1016) starts 16 left of offset 532: align its left edge.
        _ = scroller.focusLeft(in: &strip, viewportWidth: 1000, gap: 16)
        #expect(scroller.targetOffset == 516)
    }

    @Test func snappingToWhereTheRibbonIsDoesNotWakeTheAnimator() {
        let strip = Strip(columns: [Column(windowIds: [1])])
        let scroller = Scroller()
        scroller.setOffset(-250)
        scroller.snapToColumn(at: 0, in: strip, viewportWidth: 1000, gap: 16)
        #expect(scroller.isSettled)
    }
}

@Suite struct ClosingColumnTests {
    private func strip(_ count: Int, width: Double = 0.5) -> Strip {
        Strip(columns: (1...count).map { Column(windowIds: [UInt32($0)], width: .proportion(width)) })
    }

    @Test(arguments: [CenterMode.always, .never])
    func closingTheLastColumnBringsBackTheOneBeforeIt(mode: CenterMode) {
        var s = strip(3)
        s.focusColumn(at: 2)
        let scroller = Scroller(centerMode: mode)
        // Columns two and three on screen: 516..1016 and 1032..1532.
        scroller.setOffset(532)

        s.removeWindow(3)
        scroller.fitColumn(at: s.focusedColumnIndex, in: s, viewportWidth: 1000, gap: 16)

        // What is left is 1016 wide, so its right edge meets the viewport's.
        #expect(s.focusedWindowId == 2)
        #expect(scroller.targetOffset == 16)
        #expect(scroller.isSettled == false)
    }

    @Test func closingKeepsTheFocusedColumnOnScreen() {
        var s = strip(4)
        s.focusColumn(at: 3)
        let scroller = Scroller()
        scroller.setOffset(1298)

        s.removeWindow(4)
        scroller.fitColumn(at: s.focusedColumnIndex, in: s, viewportWidth: 1000, gap: 16)

        // Column three spans 1032..1532, and the viewport now ends at 1532.
        #expect(scroller.targetOffset == 532)
    }

    @Test func columnsNarrowerThanTheViewportSitInTheMiddle() {
        var s = strip(3, width: 0.25)
        s.focusColumn(at: 2)
        let scroller = Scroller()
        scroller.setOffset(200)

        s.removeWindow(3)
        scroller.fitColumn(at: s.focusedColumnIndex, in: s, viewportWidth: 1000, gap: 16)

        // 516 wide in 1000.
        #expect(scroller.targetOffset == -242)
    }

    @Test func fullscreenColumnStaysAlignedWithTheDisplay() {
        var s = strip(3)
        s.focusColumn(at: 1)
        s.toggleFullscreenFocusedWindow()
        let scroller = Scroller()

        s.removeWindow(3)
        scroller.fitColumn(at: s.focusedColumnIndex, in: s, viewportWidth: 1000, gap: 16)

        // Column two starts at 516; the fullscreen offset is that plus the outer gap.
        #expect(scroller.targetOffset == 532)
    }
}

@Suite struct SingleColumnTests {
    @Test func loneColumnIsCenteredEvenInNeverMode() {
        let strip = Strip(columns: [Column(windowIds: [1])])
        let scroller = Scroller(centerMode: .never)
        scroller.setOffset(300)
        scroller.snapToColumn(at: 0, in: strip, viewportWidth: 1000, gap: 16)
        // 500 wide in 1000: centered means offset -250.
        #expect(scroller.targetOffset == -250)
    }

    @Test func loneColumnFillsWhenAskedAndGivesWidthBack() {
        var strip = Strip(columns: [Column(windowIds: [1], width: .proportion(0.5))])
        strip.fillsWhenAlone = true
        let area = Frame(x: 16, y: 16, width: 968, height: 668)
        #expect(strip.calculateWindowFrames(viewport: area, ribbonOffset: 0, gap: 16)[1]?.width == 968)

        strip.insertWindow(2, width: .proportion(0.5))
        let frames = strip.calculateWindowFrames(viewport: area, ribbonOffset: 0, gap: 16)
        #expect(frames[1]?.width == 484)
        #expect(frames[2]?.width == 484)
    }
}
