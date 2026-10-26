import Foundation

struct DeckWindowLayout {
    static let tileHeight: CGFloat = 150
    static let gridSpacing: CGFloat = 12
    static let headerHeight: CGFloat = 28
    static let footerHeight: CGFloat = 28
    static let padding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16

    static func contentHeight(buttonCount: Int, columns: Int) -> CGFloat {
        let rows = max(1, (buttonCount + max(1, columns) - 1) / max(1, columns))
        return CGFloat(rows) * tileHeight + CGFloat(rows - 1) * gridSpacing +
            headerHeight + footerHeight + 2 * padding + 2 * sectionSpacing
    }
    var frame: CGRect
    var columns: Int

    /// Keep the usual three-column width and grow vertically first. Try wider
    /// layouts only when their measured content is taller than the usable screen.
    static func fit(in visibleFrame: CGRect, measure: (Int, CGFloat) -> CGFloat) -> Self {
        let area = visibleFrame.insetBy(dx: min(16, visibleFrame.width / 10), dy: min(16, visibleFrame.height / 10))
        let baseWidth = min(620, area.width)
        let baseColumns = min(3, max(1, Int((baseWidth - 40 + 12) / 182)))
        let maxColumns = max(baseColumns, Int((area.width - 40 + 12) / 182))
        var chosenWidth = baseWidth
        var chosenHeight: CGFloat = 0
        var chosenColumns = baseColumns
        for count in baseColumns...maxColumns {
            let width = count == baseColumns ? baseWidth : min(area.width, max(baseWidth, 40 + CGFloat(count) * 182 - 12))
            let measured = measure(count, width)
            chosenWidth = width
            chosenHeight = measured.isFinite ? max(220, measured) : 220
            chosenColumns = count
            if chosenHeight <= area.height { break }
        }
        let height = min(area.height, chosenHeight)
        return Self(frame: CGRect(x: area.midX - chosenWidth / 2, y: area.midY - height / 2, width: chosenWidth, height: height), columns: chosenColumns)
    }
}
