import SwiftUI

/// Squirrel's text sizes, in one place. Every size is a system text style,
/// so the windows read at macOS's own sizes and stay in step with the
/// standard controls beside them. Symbol and glyph sizes stay with the
/// views that draw them.
enum SquirrelFont {
    /// Running text: dashboard rows, the UPS selector, schedule details.
    static let body = Font.body
    static let bodyEmphasised = Font.body.weight(.semibold)
    /// Quieter supporting text: freshness, tile subtitles, notices.
    static let caption = Font.callout
    /// The smallest text: notes under controls and secondary labels.
    static let footnote = Font.subheadline
    /// A sheet's one-line introduction under its title.
    static let intro = Font.title3
    /// Dashboard card headings: Power Protection, Power Management.
    static let cardHeading = Font.title3.weight(.semibold)
    /// Headings within sheets, schedule titles and times.
    static let sectionTitle = Font.headline
    static let deviceName = Font.title2.weight(.semibold)
    static let assistantTitle = Font.largeTitle.weight(.bold)
    static let sheetTitle = Font.title.weight(.bold)
}
