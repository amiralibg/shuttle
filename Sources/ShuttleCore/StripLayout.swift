import Foundation
import WeftCore

/// Represents the width of a column in the scrolling strip.
public enum ColumnWidth: Equatable, Sendable {
    /// Proportion of viewport width (e.g. 0.5 for half screen, 1.0 for full screen).
    case proportion(Double)
    /// Fixed width in points.
    case fixed(Double)

    public func resolve(viewportWidth: Double) -> Double {
        switch self {
        case .proportion(let p):
            return max(100.0, viewportWidth * p)
        case .fixed(let w):
            return max(100.0, min(w, viewportWidth * 2.0))
        }
    }
}

/// A single column in the horizontal strip, containing one or more vertically stacked windows.
public struct Column: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var windowIds: [UInt32]
    public var width: ColumnWidth

    public init(id: UUID = UUID(), windowIds: [UInt32] = [], width: ColumnWidth = .proportion(0.5)) {
        self.id = id
        self.windowIds = windowIds
        self.width = width
    }
}

/// An infinite horizontal ribbon of columns for a single workspace/space.
public struct Strip: Equatable, Sendable {
    public var columns: [Column]
    public var focusedColumnIndex: Int
    public var focusedWindowId: UInt32?
    /// The window filling the whole display, gaps and all (niri's
    /// `fullscreen-window`). Its column takes the viewport plus both outer
    /// gaps on the ribbon, which pushes every neighbour off screen.
    public var fullscreenWindowId: UInt32?
    /// A strip with one column lays it out at the full viewport width; the
    /// column keeps its own width for when a second one arrives.
    public var fillsWhenAlone = false

    public init(columns: [Column] = [], focusedColumnIndex: Int = 0, focusedWindowId: UInt32? = nil) {
        self.fullscreenWindowId = nil
        self.columns = columns
        self.focusedColumnIndex = focusedColumnIndex
        self.focusedWindowId = focusedWindowId
        if self.focusedWindowId == nil && !columns.isEmpty && focusedColumnIndex < columns.count {
            self.focusedWindowId = columns[focusedColumnIndex].windowIds.first
        }
    }

    /// The column holding focus, if the strip has any.
    public var focusedColumn: Column? {
        columns.indices.contains(focusedColumnIndex) ? columns[focusedColumnIndex] : nil
    }

    /// Whether `column` holds the fullscreen window.
    public func isFullscreen(_ column: Column) -> Bool {
        fullscreenWindowId.map(column.windowIds.contains) ?? false
    }

    /// A column's width on the ribbon: its own, or the whole display for the
    /// fullscreen one (`viewportWidth` is the area inside the outer gaps).
    public func width(of column: Column, viewportWidth: Double, gap: Double) -> Double {
        if isFullscreen(column) { return viewportWidth + 2 * gap }
        if fillsWhenAlone && columns.count == 1 { return viewportWidth }
        return column.width.resolve(viewportWidth: viewportWidth)
    }

    /// Total layout width of the strip given viewport dimensions and gap sizes.
    public func totalWidth(viewportWidth: Double, gap: Double) -> Double {
        guard !columns.isEmpty else { return 0 }
        let colsWidth = columns.reduce(0.0) { $0 + width(of: $1, viewportWidth: viewportWidth, gap: gap) }
        let gapsWidth = Double(columns.count - 1) * gap
        return colsWidth + gapsWidth
    }

    /// Calculates column X positions along the ribbon.
    public func columnOffsets(viewportWidth: Double, gap: Double) -> [Double] {
        var offsets: [Double] = []
        var current: Double = 0.0
        for col in columns {
            offsets.append(current)
            current += width(of: col, viewportWidth: viewportWidth, gap: gap) + gap
        }
        return offsets
    }

    /// Toggles fullscreen for the focused window. Returns false with nothing focused.
    @discardableResult
    public mutating func toggleFullscreenFocusedWindow() -> Bool {
        guard let wid = focusedWindowId else { return false }
        fullscreenWindowId = fullscreenWindowId == wid ? nil : wid
        return true
    }

    /// Calculates the ribbon offset required to center the specified column in the viewport.
    public func centerOffset(forColumnAt index: Int, viewportWidth: Double, gap: Double) -> Double? {
        let offsets = columnOffsets(viewportWidth: viewportWidth, gap: gap)
        guard index >= 0 && index < offsets.count else { return nil }
        let colWidth = width(of: columns[index], viewportWidth: viewportWidth, gap: gap)
        let colCenter = offsets[index] + (colWidth / 2.0)
        return colCenter - (viewportWidth / 2.0)
    }

    /// The smallest scroll from `currentOffset` that shows the whole column, or
    /// its center when it is wider than the viewport. niri's
    /// `center-focused-column "never"`.
    public func revealOffset(forColumnAt index: Int, currentOffset: Double, viewportWidth: Double, gap: Double) -> Double? {
        let offsets = columnOffsets(viewportWidth: viewportWidth, gap: gap)
        guard index >= 0 && index < offsets.count else { return nil }
        let left = offsets[index]
        let colWidth = width(of: columns[index], viewportWidth: viewportWidth, gap: gap)
        if colWidth >= viewportWidth {
            return left + colWidth / 2.0 - viewportWidth / 2.0
        }
        if left < currentOffset { return left }
        if left + colWidth > currentOffset + viewportWidth { return left + colWidth - viewportWidth }
        return currentOffset
    }

    /// The minimum (leftmost) and maximum (rightmost) center offsets for the strip.
    public func centerOffsetBounds(viewportWidth: Double, gap: Double) -> (min: Double, max: Double)? {
        guard !columns.isEmpty else { return nil }
        guard let first = centerOffset(forColumnAt: 0, viewportWidth: viewportWidth, gap: gap),
              let last = centerOffset(forColumnAt: columns.count - 1, viewportWidth: viewportWidth, gap: gap) else {
            return nil
        }
        return (min: min(first, last), max: max(first, last))
    }

    /// Finds the index and column containing the given window ID.
    public func column(forWindowID windowID: UInt32) -> (index: Int, column: Column)? {
        for (idx, col) in columns.enumerated() {
            if col.windowIds.contains(windowID) {
                return (idx, col)
            }
        }
        return nil
    }

    /// Finds the index of the column whose center is nearest to the current viewport center.
    public func nearestColumnIndex(forRibbonOffset offset: Double, viewportWidth: Double, gap: Double) -> Int? {
        guard !columns.isEmpty else { return nil }
        let offsets = columnOffsets(viewportWidth: viewportWidth, gap: gap)
        let viewportCenter = offset + (viewportWidth / 2.0)

        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude

        for (idx, col) in columns.enumerated() {
            let colWidth = width(of: col, viewportWidth: viewportWidth, gap: gap)
            let colCenter = offsets[idx] + (colWidth / 2.0)
            let dist = abs(colCenter - viewportCenter)
            if dist < bestDist {
                bestDist = dist
                bestIdx = idx
            }
        }
        return bestIdx
    }

    // MARK: - Horizontal Focus Navigation

    /// Moves focus to the column on the left if available.
    @discardableResult
    public mutating func focusLeft() -> Bool {
        guard focusedColumnIndex > 0 else { return false }
        focusedColumnIndex -= 1
        syncFocusedWindow()
        return true
    }

    /// Moves focus to the column on the right if available.
    @discardableResult
    public mutating func focusRight() -> Bool {
        guard focusedColumnIndex + 1 < columns.count else { return false }
        focusedColumnIndex += 1
        syncFocusedWindow()
        return true
    }

    /// Focuses a specific column index clamped to valid range.
    @discardableResult
    public mutating func focusColumn(at index: Int) -> Bool {
        guard !columns.isEmpty else { return false }
        let clamped = max(0, min(index, columns.count - 1))
        guard clamped != focusedColumnIndex else { return false }
        focusedColumnIndex = clamped
        syncFocusedWindow()
        return true
    }

    // MARK: - Vertical Focus Navigation (Stack Navigation)

    /// Moves focus to the window above the current focused window in the same column.
    @discardableResult
    public mutating func focusUp() -> Bool {
        guard focusedColumnIndex >= 0 && focusedColumnIndex < columns.count else { return false }
        let wins = columns[focusedColumnIndex].windowIds
        guard wins.count > 1, let curWid = focusedWindowId, let idx = wins.firstIndex(of: curWid), idx > 0 else {
            return false
        }
        focusedWindowId = wins[idx - 1]
        return true
    }

    /// Moves focus to the window below the current focused window in the same column.
    @discardableResult
    public mutating func focusDown() -> Bool {
        guard focusedColumnIndex >= 0 && focusedColumnIndex < columns.count else { return false }
        let wins = columns[focusedColumnIndex].windowIds
        guard wins.count > 1, let curWid = focusedWindowId, let idx = wins.firstIndex(of: curWid), idx + 1 < wins.count else {
            return false
        }
        focusedWindowId = wins[idx + 1]
        return true
    }

    /// Moves the focused window up within its vertical stack.
    @discardableResult
    public mutating func moveFocusedWindowUp() -> Bool {
        guard focusedColumnIndex >= 0 && focusedColumnIndex < columns.count else { return false }
        var wins = columns[focusedColumnIndex].windowIds
        guard wins.count > 1, let curWid = focusedWindowId, let idx = wins.firstIndex(of: curWid), idx > 0 else {
            return false
        }
        wins.swapAt(idx, idx - 1)
        columns[focusedColumnIndex].windowIds = wins
        return true
    }

    /// Moves the focused window down within its vertical stack.
    @discardableResult
    public mutating func moveFocusedWindowDown() -> Bool {
        guard focusedColumnIndex >= 0 && focusedColumnIndex < columns.count else { return false }
        var wins = columns[focusedColumnIndex].windowIds
        guard wins.count > 1, let curWid = focusedWindowId, let idx = wins.firstIndex(of: curWid), idx + 1 < wins.count else {
            return false
        }
        wins.swapAt(idx, idx + 1)
        columns[focusedColumnIndex].windowIds = wins
        return true
    }

    // MARK: - Column Manipulation

    /// Moves the currently focused column one position to the left.
    @discardableResult
    public mutating func moveFocusedColumnLeft() -> Bool {
        guard focusedColumnIndex > 0 && focusedColumnIndex < columns.count else { return false }
        columns.swapAt(focusedColumnIndex, focusedColumnIndex - 1)
        focusedColumnIndex -= 1
        return true
    }

    /// Moves the currently focused column one position to the right.
    @discardableResult
    public mutating func moveFocusedColumnRight() -> Bool {
        guard focusedColumnIndex >= 0 && focusedColumnIndex + 1 < columns.count else { return false }
        columns.swapAt(focusedColumnIndex, focusedColumnIndex + 1)
        focusedColumnIndex += 1
        return true
    }

    /// Takes the currently focused window from a stacked column and splits it out into its own column.
    @discardableResult
    public mutating func splitFocusedWindowIntoNewColumn(width: ColumnWidth = .proportion(0.5)) -> Bool {
        guard focusedColumnIndex >= 0 && focusedColumnIndex < columns.count else { return false }
        guard columns[focusedColumnIndex].windowIds.count > 1, let wid = focusedWindowId else { return false }

        // Remove from current column
        columns[focusedColumnIndex].windowIds.removeAll(where: { $0 == wid })
        syncFocusedWindow()

        // Insert new column to the right
        let newCol = Column(windowIds: [wid], width: width)
        let insertIdx = focusedColumnIndex + 1
        columns.insert(newCol, at: insertIdx)
        focusedColumnIndex = insertIdx
        focusedWindowId = wid
        return true
    }

    /// Consumes the adjacent column into the current column stack.
    @discardableResult
    public mutating func consumeAdjacentColumnIntoStack(toRight: Bool) -> Bool {
        guard focusedColumnIndex >= 0 && focusedColumnIndex < columns.count else { return false }
        let targetIdx = toRight ? focusedColumnIndex + 1 : focusedColumnIndex - 1
        guard targetIdx >= 0 && targetIdx < columns.count else { return false }

        let adjacentWindows = columns[targetIdx].windowIds
        columns[focusedColumnIndex].windowIds.append(contentsOf: adjacentWindows)
        columns.remove(at: targetIdx)

        if !toRight {
            focusedColumnIndex -= 1
        }
        if let wid = focusedWindowId, !columns[focusedColumnIndex].windowIds.contains(wid) {
            syncFocusedWindow()
        }
        return true
    }

    /// Inserts a window into the strip (either in an existing column or creating a new column).
    public mutating func insertWindow(
        _ windowID: UInt32, inColumnAt index: Int? = nil, asNewColumn: Bool = true,
        width: ColumnWidth = .proportion(0.5)
    ) {
        removeWindow(windowID)
        if asNewColumn {
            let targetIdx = index ?? (columns.isEmpty ? 0 : focusedColumnIndex + 1)
            let clamped = max(0, min(targetIdx, columns.count))
            let newCol = Column(windowIds: [windowID], width: width)
            columns.insert(newCol, at: clamped)
            focusedColumnIndex = clamped
            focusedWindowId = windowID
        } else {
            let targetIdx = index ?? focusedColumnIndex
            guard !columns.isEmpty && targetIdx >= 0 && targetIdx < columns.count else {
                columns.append(Column(windowIds: [windowID], width: width))
                focusedColumnIndex = columns.count - 1
                focusedWindowId = windowID
                return
            }
            columns[targetIdx].windowIds.append(windowID)
            focusedColumnIndex = targetIdx
            focusedWindowId = windowID
        }
    }

    /// Removes a window from any column in the strip, pruning empty columns.
    @discardableResult
    public mutating func removeWindow(_ windowID: UInt32) -> Bool {
        var removed = false
        var colIdx = 0
        while colIdx < columns.count {
            if let idx = columns[colIdx].windowIds.firstIndex(of: windowID) {
                columns[colIdx].windowIds.remove(at: idx)
                removed = true
            }
            if columns[colIdx].windowIds.isEmpty {
                columns.remove(at: colIdx)
                // A column left of focus going away shifts focus's index, not its column.
                if colIdx < focusedColumnIndex {
                    focusedColumnIndex -= 1
                }
                if focusedColumnIndex >= columns.count {
                    focusedColumnIndex = max(0, columns.count - 1)
                }
            } else {
                colIdx += 1
            }
        }
        if focusedWindowId == windowID {
            syncFocusedWindow()
        }
        if fullscreenWindowId == windowID {
            fullscreenWindowId = nil
        }
        return removed
    }

    /// Cycles the width of the focused column through standard preset proportions (1/3 -> 1/2 -> 2/3 -> 1.0).
    public mutating func cycleColumnWidthPreset(viewportWidth: Double) {
        guard focusedColumnIndex >= 0 && focusedColumnIndex < columns.count else { return }
        let currentW = columns[focusedColumnIndex].width.resolve(viewportWidth: viewportWidth)
        let ratio = currentW / viewportWidth

        let nextRatio: Double
        if ratio < 0.40 {
            nextRatio = 0.50
        } else if ratio < 0.58 {
            nextRatio = 0.666
        } else if ratio < 0.85 {
            nextRatio = 1.0
        } else {
            nextRatio = 0.333
        }

        columns[focusedColumnIndex].width = .proportion(nextRatio)
    }

    /// Toggles the focused column between full viewport width (1.0) and half width (0.5).
    public mutating func toggleMaximizeColumn(viewportWidth: Double) {
        guard focusedColumnIndex >= 0 && focusedColumnIndex < columns.count else { return }
        let currentW = columns[focusedColumnIndex].width.resolve(viewportWidth: viewportWidth)
        let ratio = currentW / viewportWidth

        if ratio > 0.95 {
            columns[focusedColumnIndex].width = .proportion(0.5)
        } else {
            columns[focusedColumnIndex].width = .proportion(1.0)
        }
    }

    /// Expands the width of the currently focused column.
    public mutating func expandFocusedColumn(by deltaProportion: Double = 0.1, viewportWidth: Double) {
        guard focusedColumnIndex >= 0 && focusedColumnIndex < columns.count else { return }
        let currentW = columns[focusedColumnIndex].width.resolve(viewportWidth: viewportWidth)
        let newFixed = min(viewportWidth * 1.5, currentW + (viewportWidth * deltaProportion))
        columns[focusedColumnIndex].width = .fixed(newFixed)
    }

    /// Shrinks the width of the currently focused column.
    public mutating func shrinkFocusedColumn(by deltaProportion: Double = 0.1, viewportWidth: Double) {
        guard focusedColumnIndex >= 0 && focusedColumnIndex < columns.count else { return }
        let currentW = columns[focusedColumnIndex].width.resolve(viewportWidth: viewportWidth)
        let newFixed = max(150.0, currentW - (viewportWidth * deltaProportion))
        columns[focusedColumnIndex].width = .fixed(newFixed)
    }

    // MARK: - Frame Calculation

    /// Computes the exact screen frames for all windows in the strip given a viewport frame, ribbon scroll offset, and gap.
    public func calculateWindowFrames(viewport: Frame, ribbonOffset: Double, gap: Double) -> [UInt32: Frame] {
        var result: [UInt32: Frame] = [:]
        guard !columns.isEmpty else { return result }

        let offsets = columnOffsets(viewportWidth: viewport.width, gap: gap)

        for (colIdx, col) in columns.enumerated() {
            let colX = offsets[colIdx] - ribbonOffset + viewport.x
            let colW = width(of: col, viewportWidth: viewport.width, gap: gap)
            let winCount = col.windowIds.count
            guard winCount > 0 else { continue }

            // Fullscreen: every window of the column gets the whole display;
            // the fullscreen one is raised over the rest.
            if isFullscreen(col) {
                let full = Frame(x: colX, y: viewport.y - gap, width: colW, height: viewport.height + 2 * gap)
                for winID in col.windowIds { result[winID] = full }
                continue
            }

            // Distribute vertical space in column
            let totalGaps = Double(winCount - 1) * gap
            let availableH = max(100.0, viewport.height - totalGaps)
            let winH = availableH / Double(winCount)

            var curY = viewport.y
            for winID in col.windowIds {
                result[winID] = Frame(x: colX, y: curY, width: colW, height: winH)
                curY += winH + gap
            }
        }

        return result
    }

    private mutating func syncFocusedWindow() {
        guard focusedColumnIndex >= 0 && focusedColumnIndex < columns.count else {
            focusedWindowId = nil
            return
        }
        let col = columns[focusedColumnIndex]
        focusedWindowId = col.windowIds.first
    }
}
