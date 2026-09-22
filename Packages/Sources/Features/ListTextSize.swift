import CoreGraphics

/// Message-list text size in points; every other list measurement scales from it.
public enum ListTextSize {
    public static let storageKey = "mail.listTextSize"
    public static let range: ClosedRange<Double> = 11...20
    public static let standard: Double = 13

    public static func clamped(_ size: Double) -> Double {
        min(max(size.rounded(), range.lowerBound), range.upperBound)
    }

    public static func step(_ size: Double, by points: Double) -> Double {
        clamped(size + points)
    }

    struct Metrics: Equatable {
        let rowHeight: CGFloat
        let headerHeight: CGFloat
        let textSize: CGFloat
        let headerSize: CGFloat
        /// Tags and inline symbols.
        let smallSize: CGFloat
        let avatarSize: CGFloat
        let spacing: CGFloat

        init(textSize size: Double) {
            let text = CGFloat(ListTextSize.clamped(size))
            let step = text - CGFloat(ListTextSize.standard)
            textSize = text
            rowHeight = (34 + step * 3.5).rounded()
            headerHeight = (28 + step * 2).rounded()
            headerSize = text - 2
            smallSize = text - 3
            avatarSize = (20 + step * 2).rounded()
            spacing = (10 + step * 0.5).rounded()
        }
    }
}
