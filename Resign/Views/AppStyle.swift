import Foundation

// MARK: - Shared UI Metrics
// Centralized so sibling controls (cards, badges, buttons, empty states, form
// fields) stay visually consistent across all pages.
enum AppStyle {
    // Typography
    static let cardTitleSize: CGFloat = 13        // section / header card titles (semibold)
    static let listTitleSize: CGFloat = 12        // list item titles (semibold)
    static let listSubtitleSize: CGFloat = 10     // list item secondary lines
    static let fieldSize: CGFloat = 12            // form rows / labels
    static let captionSize: CGFloat = 11          // badges / hints
    static let microSize: CGFloat = 10            // smallest hints

    // Cards
    static let cardPadding: CGFloat = 14
    static let listSpacing: CGFloat = 10          // spacing between sibling cards

    // Badges / tags
    static let badgeHPadding: CGFloat = 8
    static let badgeVPadding: CGFloat = 3
    static let badgeCornerRadius: CGFloat = 5

    // Empty states
    static let emptyIconSize: CGFloat = 32
    static let emptyTitleSize: CGFloat = 13
    static let emptySubtitleSize: CGFloat = 11

    // Form fields
    static let formLabelWidth: CGFloat = 90
    static let formFieldMaxWidth: CGFloat = 220
}
