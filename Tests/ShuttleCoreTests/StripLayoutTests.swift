import Testing
import WeftCore
@testable import ShuttleCore

@Suite struct StripLayoutTests {
    @Test func testColumnOffsetsAndTotalWidth() {
        let col1 = Column(windowIds: [1], width: .proportion(0.5))
        let col2 = Column(windowIds: [2], width: .proportion(0.5))
        let strip = Strip(columns: [col1, col2])

        let viewportWidth = 1000.0
        let gap = 16.0

        let total = strip.totalWidth(viewportWidth: viewportWidth, gap: gap)
        #expect(total == 500.0 + 500.0 + 16.0)

        let offsets = strip.columnOffsets(viewportWidth: viewportWidth, gap: gap)
        #expect(offsets.count == 2)
        #expect(offsets[0] == 0.0)
        #expect(offsets[1] == 516.0)
    }

    @Test func testCenterOffset() {
        let col1 = Column(windowIds: [1], width: .proportion(0.5)) // width = 500
        let col2 = Column(windowIds: [2], width: .proportion(0.5)) // width = 500
        let strip = Strip(columns: [col1, col2])

        let viewportWidth = 1000.0
        let gap = 16.0

        // Col 0: offset 0, width 500 -> center is 250 -> centerOffset = 250 - 500 = -250
        let center0 = strip.centerOffset(forColumnAt: 0, viewportWidth: viewportWidth, gap: gap)
        #expect(center0 == -250.0)

        // Col 1: offset 516, width 500 -> center is 766 -> centerOffset = 766 - 500 = 266
        let center1 = strip.centerOffset(forColumnAt: 1, viewportWidth: viewportWidth, gap: gap)
        #expect(center1 == 266.0)
    }

    @Test func testNearestColumnIndex() {
        let col1 = Column(windowIds: [1], width: .proportion(0.5)) // 0..500, center = 250
        let col2 = Column(windowIds: [2], width: .proportion(0.5)) // 516..1016, center = 766
        let col3 = Column(windowIds: [3], width: .proportion(0.5)) // 1032..1532, center = 1282
        let strip = Strip(columns: [col1, col2, col3])

        let viewportWidth = 1000.0
        let gap = 16.0

        // Viewport centered near column 0 (offset = -200 -> center = 300) -> col 0 (center 250)
        let n0 = strip.nearestColumnIndex(forRibbonOffset: -200.0, viewportWidth: viewportWidth, gap: gap)
        #expect(n0 == 0)

        // Viewport centered near column 1 (offset = 250 -> center = 750) -> col 1 (center 766)
        let n1 = strip.nearestColumnIndex(forRibbonOffset: 250.0, viewportWidth: viewportWidth, gap: gap)
        #expect(n1 == 1)

        // Viewport centered near column 2 (offset = 800 -> center = 1300) -> col 2 (center 1282)
        let n2 = strip.nearestColumnIndex(forRibbonOffset: 800.0, viewportWidth: viewportWidth, gap: gap)
        #expect(n2 == 2)
    }

    @Test func testColumnLookupByWindowID() {
        let col1 = Column(windowIds: [10, 11])
        let col2 = Column(windowIds: [20])
        let strip = Strip(columns: [col1, col2])

        let found11 = strip.column(forWindowID: 11)
        #expect(found11?.index == 0)

        let found20 = strip.column(forWindowID: 20)
        #expect(found20?.index == 1)

        let found99 = strip.column(forWindowID: 99)
        #expect(found99 == nil)
    }

    @Test func testCenterOffsetBounds() {
        let col1 = Column(windowIds: [1], width: .proportion(0.5))
        let col2 = Column(windowIds: [2], width: .proportion(0.5))
        let strip = Strip(columns: [col1, col2])

        let bounds = strip.centerOffsetBounds(viewportWidth: 1000.0, gap: 16.0)
        #expect(bounds != nil)
        #expect(bounds?.min == -250.0)
        #expect(bounds?.max == 266.0)
    }

    @Test func testFocusNavigation() {
        var strip = Strip(columns: [
            Column(windowIds: [10]),
            Column(windowIds: [20]),
            Column(windowIds: [30])
        ])

        #expect(strip.focusedColumnIndex == 0)
        #expect(strip.focusLeft() == false) // Clamped at 0

        #expect(strip.focusRight() == true)
        #expect(strip.focusedColumnIndex == 1)
        #expect(strip.focusedWindowId == 20)

        #expect(strip.focusRight() == true)
        #expect(strip.focusedColumnIndex == 2)
        #expect(strip.focusedWindowId == 30)

        #expect(strip.focusRight() == false) // Clamped at 2

        #expect(strip.focusLeft() == true)
        #expect(strip.focusedColumnIndex == 1)
        #expect(strip.focusedWindowId == 20)
    }

    @Test func testVerticalFocusNavigation() {
        var strip = Strip(columns: [
            Column(windowIds: [100, 101, 102], width: .proportion(0.5))
        ], focusedColumnIndex: 0, focusedWindowId: 100)

        #expect(strip.focusedWindowId == 100)
        #expect(strip.focusUp() == false) // already at top

        #expect(strip.focusDown() == true)
        #expect(strip.focusedWindowId == 101)

        #expect(strip.focusDown() == true)
        #expect(strip.focusedWindowId == 102)

        #expect(strip.focusDown() == false) // already at bottom

        #expect(strip.focusUp() == true)
        #expect(strip.focusedWindowId == 101)
    }

    @Test func testVerticalWindowReordering() {
        var strip = Strip(columns: [
            Column(windowIds: [10, 20, 30], width: .proportion(0.5))
        ], focusedColumnIndex: 0, focusedWindowId: 20)

        #expect(strip.moveFocusedWindowUp() == true)
        #expect(strip.columns[0].windowIds == [20, 10, 30])

        #expect(strip.moveFocusedWindowUp() == false) // now at top

        #expect(strip.moveFocusedWindowDown() == true)
        #expect(strip.columns[0].windowIds == [10, 20, 30])
    }

    @Test func testSplitAndConsumeColumns() {
        var strip = Strip(columns: [
            Column(windowIds: [100, 200], width: .proportion(0.5))
        ], focusedColumnIndex: 0, focusedWindowId: 200)

        // Split 200 into new column
        #expect(strip.splitFocusedWindowIntoNewColumn() == true)
        #expect(strip.columns.count == 2)
        #expect(strip.columns[0].windowIds == [100])
        #expect(strip.columns[1].windowIds == [200])
        #expect(strip.focusedColumnIndex == 1)
        #expect(strip.focusedWindowId == 200)

        // Consume left column back into stack
        #expect(strip.consumeAdjacentColumnIntoStack(toRight: false) == true)
        #expect(strip.columns.count == 1)
        #expect(strip.columns[0].windowIds == [200, 100])
        #expect(strip.focusedColumnIndex == 0)
    }

    @Test func testCycleColumnWidthPresetAndMaximize() {
        var strip = Strip(columns: [
            Column(windowIds: [1], width: .proportion(0.333))
        ])

        let vp = 1200.0

        // 0.333 -> 0.5
        strip.cycleColumnWidthPreset(viewportWidth: vp)
        #expect(strip.columns[0].width == .proportion(0.5))

        // 0.5 -> 0.666
        strip.cycleColumnWidthPreset(viewportWidth: vp)
        #expect(strip.columns[0].width == .proportion(0.666))

        // 0.666 -> 1.0
        strip.cycleColumnWidthPreset(viewportWidth: vp)
        #expect(strip.columns[0].width == .proportion(1.0))

        // 1.0 -> 0.333
        strip.cycleColumnWidthPreset(viewportWidth: vp)
        #expect(strip.columns[0].width == .proportion(0.333))

        // Maximize toggle
        strip.toggleMaximizeColumn(viewportWidth: vp)
        #expect(strip.columns[0].width == .proportion(1.0))

        strip.toggleMaximizeColumn(viewportWidth: vp)
        #expect(strip.columns[0].width == .proportion(0.5))
    }

    @Test func testMoveColumn() {
        var strip = Strip(columns: [
            Column(windowIds: [1]),
            Column(windowIds: [2]),
            Column(windowIds: [3])
        ], focusedColumnIndex: 1)

        #expect(strip.moveFocusedColumnLeft() == true)
        #expect(strip.focusedColumnIndex == 0)
        #expect(strip.columns[0].windowIds == [2])
        #expect(strip.columns[1].windowIds == [1])

        #expect(strip.moveFocusedColumnLeft() == false) // already at 0

        #expect(strip.moveFocusedColumnRight() == true)
        #expect(strip.focusedColumnIndex == 1)
        #expect(strip.columns[1].windowIds == [2])
    }

    @Test func testInsertAndRemoveWindow() {
        var strip = Strip()
        strip.insertWindow(100, asNewColumn: true)
        #expect(strip.columns.count == 1)
        #expect(strip.focusedWindowId == 100)

        strip.insertWindow(200, asNewColumn: true)
        #expect(strip.columns.count == 2)
        #expect(strip.focusedWindowId == 200)

        // Insert 300 into same column 1 (stacked)
        strip.insertWindow(300, inColumnAt: 1, asNewColumn: false)
        #expect(strip.columns.count == 2)
        #expect(strip.columns[1].windowIds == [200, 300])

        // Remove 200
        let rem200 = strip.removeWindow(200)
        #expect(rem200 == true)
        #expect(strip.columns[1].windowIds == [300])

        // Remove 300 -> empty column pruned
        let rem300 = strip.removeWindow(300)
        #expect(rem300 == true)
        #expect(strip.columns.count == 1)
        #expect(strip.focusedWindowId == 100)
    }

    @Test func testWindowFrameCalculation() {
        let col1 = Column(windowIds: [1], width: .proportion(0.5)) // width = 500
        let col2 = Column(windowIds: [2, 3], width: .proportion(0.5)) // stacked windows, width = 500
        let strip = Strip(columns: [col1, col2])

        let viewport = Frame(x: 0, y: 0, width: 1000, height: 800)
        let frames = strip.calculateWindowFrames(viewport: viewport, ribbonOffset: 0.0, gap: 20.0)

        // Col 1, Win 1
        let f1 = frames[1]
        #expect(f1 != nil)
        #expect(f1?.x == 0.0)
        #expect(f1?.y == 0.0)
        #expect(f1?.width == 500.0)
        #expect(f1?.height == 800.0)

        // Col 2, Win 2 & 3 (stacked with 20pt gap: (800 - 20) / 2 = 390 each)
        let f2 = frames[2]
        #expect(f2 != nil)
        #expect(f2?.x == 520.0)
        #expect(f2?.y == 0.0)
        #expect(f2?.width == 500.0)
        #expect(f2?.height == 390.0)

        let f3 = frames[3]
        #expect(f3 != nil)
        #expect(f3?.x == 520.0)
        #expect(f3?.y == 410.0)
        #expect(f3?.width == 500.0)
        #expect(f3?.height == 390.0)
    }
}
