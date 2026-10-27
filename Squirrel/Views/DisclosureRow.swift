import SwiftUI

/// A disclosure row for use inside a grouped `Form`.
///
/// Not `DisclosureGroup`: inside a `Section` of a grouped form, its
/// `isExpanded` binding is never written back, so the section is stuck at
/// whatever it started as — unreachable by mouse, keyboard or VoiceOver. This
/// draws the same row and drives it from a real button, which every input
/// method can actuate.
struct DisclosureRow<Content: View, Trailing: View>: View {
    private let title: String
    private let symbol: String?
    private let labelSpacing: CGFloat
    @Binding private var isExpanded: Bool
    @ViewBuilder private let content: () -> Content
    @ViewBuilder private let trailing: () -> Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `trailing` sits at the far end of the heading, for a quiet status such
    /// as when the contents were last updated.
    /// `symbol` sits between the chevron and the title, as on a card heading.
    init(
        _ title: String,
        symbol: String? = nil,
        isExpanded: Binding<Bool>,
        labelSpacing: CGFloat = 6,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.symbol = symbol
        self.labelSpacing = labelSpacing
        self._isExpanded = isExpanded
        self.content = content
        self.trailing = trailing
    }

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: labelSpacing) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                if let symbol {
                    Image(systemName: symbol)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                }
                Text(title)
                Spacer(minLength: 8)
                trailing()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides these details" : "Shows these details")

        if isExpanded {
            content()
        }
    }
}

extension DisclosureRow where Trailing == EmptyView {
    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, isExpanded: isExpanded, content: content) { EmptyView() }
    }
}
