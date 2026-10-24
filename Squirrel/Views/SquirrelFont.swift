import SwiftUI

/// Squirrel's text sizes, in one place. The dashboard's reference layout is
/// set at 14 pt rather than macOS's 13 pt body, so these are fixed sizes
/// rather than system text styles. Symbol and glyph sizes stay with the
/// views that draw them.
enum SquirrelFont {
    /// Running text: dashboard rows, the UPS selector, schedule details.
    static let body = Font.system(size: 14)
    static let bodyEmphasised = Font.system(size: 14, weight: .semibold)
    /// Quieter supporting text: freshness, tile subtitles, notices.
    static let caption = Font.system(size: 13)
    /// The smallest text: notes under controls and secondary labels.
    static let footnote = Font.system(size: 12)
    /// A sheet's one-line introduction under its title.
    static let intro = Font.system(size: 16)
    /// A large, full-width action such as Add Schedule.
    static let prominentAction = Font.system(size: 16, weight: .medium)
    /// Dashboard card headings: macOS Connection, Power Management.
    static let cardHeading = Font.system(size: 16, weight: .semibold)
    /// Headings within sheets, schedule titles and times.
    static let sectionTitle = Font.system(size: 17, weight: .semibold)
    static let deviceName = Font.system(size: 20, weight: .semibold)
    /// The large readings: battery, runtime and load.
    static let metric = Font.system(size: 24, weight: .semibold)
    static let assistantTitle = Font.system(size: 26, weight: .bold)
    static let sheetTitle = Font.system(size: 28, weight: .bold)
}
