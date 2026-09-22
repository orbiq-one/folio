import CoreGraphics

struct MailColumnWidth: Equatable, Sendable {
    let minimum: CGFloat
    let ideal: CGFloat
    let maximum: CGFloat

    init(minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) {
        precondition(minimum <= ideal && ideal <= maximum)
        self.minimum = minimum
        self.ideal = ideal
        self.maximum = maximum
    }
}

enum MailColumnLayout {
    static let sidebar = MailColumnWidth(minimum: 190, ideal: 240, maximum: 360)
    static let listMinimum: CGFloat = 480
    static let windowMinimumWidth: CGFloat = sidebar.minimum + listMinimum

    static func clamped(_ width: CGFloat, to column: MailColumnWidth) -> CGFloat {
        min(max(width, column.minimum), column.maximum)
    }
}
