import Testing
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
}
