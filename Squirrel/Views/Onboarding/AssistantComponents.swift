import AppKit
import SwiftUI

// MARK: - Chrome

/// The three-step indicator across the top of the assistant.
///
/// Deliberately quiet: it tells you where you are and nothing else, and it is
/// one accessibility element rather than three decorative circles.
struct AssistantStepIndicator: View {
    let titles: [String]
    let current: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                if index > 0 { connector(after: index - 1) }
                step(index: index, title: title)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(titles.count): \(titles[current])")
    }

    private func step(index: Int, title: String) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(index <= current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 20, height: 20)
                if index < current {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(index == current ? Color.white : Color.secondary)
                }
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(index <= current ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .frame(width: 76)
    }

    private func connector(after index: Int) -> some View {
        Capsule()
            .fill(index < current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            .frame(height: 2)
            .frame(maxWidth: 48)
            .padding(.bottom, 18)
    }
}

/// Title and subtitle, as one heading for VoiceOver.
struct AssistantHeader: View {
    let title: String
    let subtitle: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Rows

/// The small tinted glyph that starts most rows.
struct AssistantSymbolTile: View {
    let symbol: String
    var tint: Color = .secondary
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The UPS drawing at row size, in place of a symbol tile once Squirrel
/// knows what the UPS is.
struct AssistantIllustrationTile: View {
    let kind: UPSIllustrationKind
    var height: CGFloat = 32

    var body: some View {
        UPSDeviceIllustration(kind: kind, cornerRadius: height * 0.28)
            .frame(width: height * 115 / 88, height: height)
    }
}

/// A radio-style choice. Native `Picker(.radioGroup)` cannot carry a detail
/// line or a nested list, which both of the choices here need.
struct AssistantChoiceRow<Accessory: View>: View {
    let title: String
    var detail: String?
    var symbol: String?
    /// Shown in place of the symbol once the UPS is known.
    var illustration: UPSIllustrationKind?
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)

                if let illustration {
                    AssistantIllustrationTile(kind: illustration)
                } else if let symbol {
                    AssistantSymbolTile(symbol: symbol, tint: isSelected ? .accentColor : .secondary)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium))
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                accessory()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension AssistantChoiceRow where Accessory == EmptyView {
    init(
        title: String,
        detail: String? = nil,
        symbol: String? = nil,
        illustration: UPSIllustrationKind? = nil,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            detail: detail,
            symbol: symbol,
            illustration: illustration,
            isSelected: isSelected,
            isEnabled: isEnabled,
            action: action,
            accessory: { EmptyView() }
        )
    }
}

/// A short status word in a tinted capsule — "On mains power", "On battery".
struct AssistantStatusBadge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// The quiet confirmation or warning panel at the foot of a screen.
struct AssistantNoticeBox: View {
    enum Kind {
        case positive, warning, negative

        var symbol: String {
            switch self {
            case .positive: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .negative: return "xmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .positive: return .green
            case .warning: return .orange
            case .negative: return .red
            }
        }
    }

    let kind: Kind
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The app icon, at whatever size it is given.
struct SquirrelAppIcon: View {
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

// MARK: - Styling

extension View {
    /// The bordered container every grouped list in the assistant sits in.
    /// Semantic colours only, so it follows the system appearance.
    func assistantGroup() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09))
            )
    }

    @ViewBuilder
    func assistantPrimaryButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).controlSize(.large)
        } else {
            buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    @ViewBuilder
    func assistantSecondaryButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).controlSize(.large)
        } else {
            buttonStyle(.bordered).controlSize(.large)
        }
    }
}

private let assistantSeparatorInset: CGFloat = 12

/// A hairline between rows in a grouped list, inset like a system list.
struct AssistantRowDivider: View {
    var body: some View {
        Divider().padding(.leading, assistantSeparatorInset)
    }
}
