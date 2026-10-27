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

    public init(columns: [Column] = [], focusedColumnIndex: Int = 0, focusedWindowId: UInt32? = nil) {
        self.columns = columns
        self.focusedColumnIndex = focusedColumnIndex
        self.focusedWindowId = focusedWindowId
    }

    /// Total layout width of the strip given viewport dimensions and gap sizes.
    public func totalWidth(viewportWidth: Double, gap: Double) -> Double {
        guard !columns.isEmpty else { return 0 }
        let colsWidth = columns.reduce(0.0) { $0 + $1.width.resolve(viewportWidth: viewportWidth) }
        let gapsWidth = Double(columns.count - 1) * gap
        return colsWidth + gapsWidth
    }

    /// Calculates column X positions along the ribbon.
    public func columnOffsets(viewportWidth: Double, gap: Double) -> [Double] {
        var offsets: [Double] = []
        var current: Double = 0.0
        for col in columns {
            offsets.append(current)
            current += col.width.resolve(viewportWidth: viewportWidth) + gap
        }
        return offsets
    }
}
