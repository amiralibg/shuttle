import Testing
import WeftCore
@testable import ShuttleCore

@Suite struct DisplayGeometryTests {
    // This Mac: a 4K display above the built-in one, offset to the left.
    let laptop = Frame(x: 0, y: 0, width: 1710, height: 1112)
    let samsung = Frame(x: -1019, y: -2160, width: 3840, height: 2160)

    @Test func verticalArrangementNeighbours() {
        let displays = [samsung, laptop]
        #expect(DisplayGeometry.neighbour(of: 1, .up, in: displays) == 0)
        #expect(DisplayGeometry.neighbour(of: 0, .down, in: displays) == 1)
        #expect(DisplayGeometry.neighbour(of: 1, .down, in: displays) == nil)
        #expect(DisplayGeometry.neighbour(of: 1, .next, in: displays) == 0)
    }

    @Test func sideBySidePrefersOverlappingDisplay() {
        let left = Frame(x: -1920, y: 0, width: 1920, height: 1080)
        let center = Frame(x: 0, y: 0, width: 2560, height: 1440)
        let highRight = Frame(x: 2560, y: -2000, width: 1920, height: 1080) // up and to the right, no overlap
        let right = Frame(x: 2560, y: 200, width: 1920, height: 1080)
        let displays = [left, center, highRight, right]
        #expect(DisplayGeometry.neighbour(of: 1, .left, in: displays) == 0)
        #expect(DisplayGeometry.neighbour(of: 1, .right, in: displays) == 3)
    }

    @Test func parkingAvoidsOtherDisplays() {
        // Laptop's bottom-right is clear: nothing below or right of it.
        let spot = DisplayGeometry.parkingSpot(width: 800, height: 600, on: laptop, others: [samsung])
        #expect(spot.x == 1709 && spot.y == 1111)

        // A display to the right that reaches below the laptop's bottom would
        // show a bottom-right park, so bottom-left is used.
        let tallRight = Frame(x: 1710, y: -500, width: 2000, height: 2500)
        let left = DisplayGeometry.parkingSpot(width: 800, height: 600, on: laptop, others: [tallRight])
        #expect(left.x == -799 && left.y == 1111)
    }

    @Test func samsungParksClearOfLaptop() {
        let spot = DisplayGeometry.parkingSpot(width: 1900, height: 2100, on: samsung, others: [laptop])
        let parked = Frame(x: spot.x, y: spot.y, width: 1900, height: 2100)
        #expect(!DisplayGeometry.intersects(parked, laptop))
        #expect(DisplayGeometry.display(containing: parked, in: [samsung, laptop]) == 0)
    }

    @Test func displayContainingPicksLargestOverlap() {
        let straddling = Frame(x: 100, y: -300, width: 800, height: 1000) // 300 on Samsung, 700 on laptop
        #expect(DisplayGeometry.display(containing: straddling, in: [samsung, laptop]) == 1)
        #expect(DisplayGeometry.display(containing: Frame(x: 9000, y: 9000, width: 10, height: 10), in: [samsung, laptop]) == nil)
    }
}

@Suite struct FullscreenTests {
    // Area inside 16pt outer gaps of a 1000x700 viewport.
    let area = Frame(x: 16, y: 16, width: 968, height: 668)

    @Test func fullscreenWindowFillsDisplayAndPushesNeighboursOff() {
        var strip = Strip(columns: [Column(windowIds: [1]), Column(windowIds: [2]), Column(windowIds: [3])],
                          focusedColumnIndex: 1, focusedWindowId: 2)
        let toggled = strip.toggleFullscreenFocusedWindow()
        #expect(toggled)

        let offset = strip.centerOffset(forColumnAt: 1, viewportWidth: area.width, gap: 16)!
        let frames = strip.calculateWindowFrames(viewport: area, ribbonOffset: offset, gap: 16)
        #expect(frames[2] == Frame(x: 0, y: 0, width: 1000, height: 700))
        // Neighbours end at or start beyond the display edges.
        #expect(frames[1]!.x + frames[1]!.width <= 0)
        #expect(frames[3]!.x >= 1000)
    }

    @Test func togglingTwiceRestoresAndClosingClears() {
        var strip = Strip(columns: [Column(windowIds: [1])])
        strip.toggleFullscreenFocusedWindow()
        #expect(strip.fullscreenWindowId == 1)
        strip.toggleFullscreenFocusedWindow()
        #expect(strip.fullscreenWindowId == nil)
        strip.toggleFullscreenFocusedWindow()
        strip.removeWindow(1)
        #expect(strip.fullscreenWindowId == nil)
    }
}

@Suite struct MultiDisplayBindingTests {
    @Test func monitorAndFullscreenDefaults() {
        let binds = ShuttleConfig.default.keybindings
        #expect(binds["alt-shift-f"] == "window fullscreen")
        #expect(binds["ctrl-alt-up"] == "monitor focus up")
        #expect(binds["ctrl-alt-shift-j"] == "monitor move-column down")
    }
}
